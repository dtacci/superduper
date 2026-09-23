//
//  ParakeetEngine.swift
//  Pindrop
//
//  Created on 2026-01-30.
//

import Foundation
import FluidAudio

@MainActor
public final class ParakeetEngine: TimedTranscriptionEngine, CapabilityReporting {
    
    public static var capabilities: AudioEngineCapabilities {
        [.transcription, .streamingTranscription, .voiceActivityDetection, .speakerDiarization]
    }
    
    public enum EngineError: Error, LocalizedError {
        case modelNotLoaded
        case invalidAudioData
        case transcriptionFailed(String)
        case downloadFailed(String)
        case initializationFailed(String)
        
        public var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Model is not loaded"
            case .invalidAudioData:
                return "Invalid audio data"
            case .transcriptionFailed(let message):
                return "Transcription failed: \(message)"
            case .downloadFailed(let message):
                return "Model download failed: \(message)"
            case .initializationFailed(let message):
                return "Initialization failed: \(message)"
            }
        }
    }
    
    public private(set) var state: TranscriptionEngineState = .unloaded
    public private(set) var error: Error?
    
    private var asrManager: AsrManager?
    private var transcribingTask: Task<String, Error>?

    /// Vocabulary boosting (names, jargon): a small CTC model spots the listed terms in
    /// the audio and FluidAudio's rescorer swaps them into the transcript only where
    /// the acoustics favour them. Loaded lazily, and only when terms are provided.
    private var vocabularySpotter: CtcKeywordSpotter?
    private var vocabularyCache: (terms: [String], vocabulary: CustomVocabularyContext, rescorer: VocabularyRescorer)?
    
    public init() {}
    
    public func loadModel(path: String) async throws {
        guard state != .loading else { return }
        
        state = .loading
        error = nil
        
        do {
            throw EngineError.initializationFailed("Loading from path not supported for Parakeet. Use loadModel(name:downloadBase:) instead.")
        } catch {
            self.error = error
            state = .error
            throw error
        }
    }
    
    public func loadModel(name: String, downloadBase: URL? = nil) async throws {
        guard state != .loading else { return }
        
        state = .loading
        error = nil
        
        do {
            guard let version = Self.modelVersion(forModelName: name) else {
                throw EngineError.initializationFailed("Unknown Parakeet model: \(name)")
            }
            // Load from whichever folder already holds a complete model set so an
            // existing ~450MB download is never fetched again; download into the
            // app folder (where ModelManager looks) only when neither has it.
            let models: AsrModels
            if let existingDirectory = Self.resolveModelDirectory(version: version, downloadBase: downloadBase) {
                models = try await AsrModels.load(from: existingDirectory, version: version)
            } else {
                let targetDirectory = downloadBase.map { Self.appModelDirectory(downloadBase: $0, version: version) }
                    ?? AsrModels.defaultCacheDirectory(for: version)
                models = try await AsrModels.downloadAndLoad(to: targetDirectory, version: version)
            }

            // FluidAudio 0.15+: AsrManager takes models at init (or via loadModels),
            // replacing the retired `initialize(models:)` entry point.
            let manager = AsrManager(config: .default, models: models)
            try await manager.loadModels(models)

            // CoreML specializes ANE kernels lazily on the first prediction, not at
            // load — without this, that one-time cost lands on the user's first
            // dictation. Push 1.2s of silence through the full pipeline while still
            // `.loading`; a warm-up failure must never fail the load.
            let decoderLayers = await manager.decoderLayerCount
            if var warmupState = try? TdtDecoderState(decoderLayers: decoderLayers) {
                _ = try? await manager.transcribe(
                    [Float](repeating: 0, count: 19_200),
                    decoderState: &warmupState
                )
            }

            asrManager = manager
            state = .ready
        } catch {
            self.error = error
            state = .error
            throw EngineError.downloadFailed(error.localizedDescription)
        }
    }
    
    public func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String {
        guard !options.vocabularyBiasWords.isEmpty else {
            return try await recognize(audioData: audioData).text
        }
        return try await transcribeWords(audioData: audioData, options: options)
            .map(\.text)
            .joined(separator: " ")
    }

    /// One pass over the whole clip (FluidAudio chunks long audio internally) with
    /// per-word timing reconstructed from the TDT token timings.
    public func transcribeWords(audioData: Data, options: TranscriptionOptions) async throws -> [TimedWord] {
        let result = try await recognize(audioData: audioData)
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            return Self.evenlyTimedWords(text: result.text, duration: result.duration)
        }
        let words = Self.words(from: tokenTimings)
        guard !options.vocabularyBiasWords.isEmpty else { return words }
        return await boostVocabulary(
            words: words,
            tokenTimings: tokenTimings,
            audioData: audioData,
            terms: options.vocabularyBiasWords
        )
    }

    // MARK: - Vocabulary boosting

    /// Minimum spelling similarity for a transcript span to be treated as a possible
    /// mishearing of a vocabulary term (and for any replacement to be accepted).
    nonisolated static let vocabularyMinimumSimilarity = 0.6

    /// Two steps, both conservative:
    /// 1. Spans that already spell a term apart from spacing/case/punctuation
    ///    ("live kit", "russ") take the canonical spelling directly.
    /// 2. Spans that are near-misspellings ("Desa" for "D'Sa") are checked acoustically
    ///    with FluidAudio's CTC rescorer on a few seconds of audio around each, and
    ///    only replacements that still resemble the original spelling are accepted.
    /// Transcripts without near matches cost nothing; any failure leaves them unchanged.
    private func boostVocabulary(
        words: [TimedWord],
        tokenTimings: [TokenTiming],
        audioData: Data,
        terms: [String]
    ) async -> [TimedWord] {
        let started = CFAbsoluteTimeGetCurrent()
        let boostable = Self.boostableTerms(terms)
        guard !boostable.isEmpty else { return words }

        var result = Self.applyingExactTermSpellings(boostable, to: words)
        let candidates = Self.vocabularyCandidates(in: result, terms: boostable)
        guard !candidates.isEmpty else {
            Log.transcription.info("Vocabulary boosting: \(boostable.count) term(s), no near matches")
            return result
        }

        var acousticReplacements = 0
        do {
            guard let (spotter, vocabulary, rescorer) = try await preparedVocabularyBooster(terms: boostable) else {
                return result
            }
            let samples = audioData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let sampleRate = Double(ASRConstants.sampleRate)
            let tuning = ContextBiasingConstants.rescorerConfig(forVocabSize: vocabulary.terms.count)
            let windows = Self.candidateWindows(
                candidates,
                words: result,
                audioDuration: Double(samples.count) / sampleRate
            )

            // Process windows from the end so earlier word indices stay valid.
            for window in windows.reversed() {
                try Task.checkCancellation()
                let startSample = max(0, Int(window.start * sampleRate))
                let endSample = min(samples.count, Int(window.end * sampleRate))
                guard endSample - startSample >= ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate) else {
                    continue
                }
                let windowTokens = tokenTimings
                    .filter { $0.startTime >= window.start && $0.startTime < window.end }
                    .map {
                        TokenTiming(
                            token: $0.token,
                            tokenId: $0.tokenId,
                            startTime: $0.startTime - window.start,
                            endTime: $0.endTime - window.start,
                            confidence: $0.confidence
                        )
                    }
                guard !windowTokens.isEmpty else { continue }

                let spot = try await spotter.spotKeywordsWithLogProbs(
                    audioSamples: Array(samples[startSample..<endSample]),
                    customVocabulary: vocabulary,
                    minScore: nil
                )
                guard !spot.logProbs.isEmpty else { continue }

                let output = rescorer.ctcTokenRescore(
                    transcript: windowTokens.map(\.token).joined().trimmingCharacters(in: .whitespaces),
                    tokenTimings: windowTokens,
                    logProbs: spot.logProbs,
                    frameDuration: spot.frameDuration,
                    cbw: tuning.cbw,
                    marginSeconds: 0.5,
                    minSimilarity: max(tuning.minSimilarity, vocabulary.minSimilarity)
                )
                let accepted = output.replacements.compactMap { item -> VocabularyReplacement? in
                    guard item.shouldReplace, let replacement = item.replacementWord else { return nil }
                    let candidate = VocabularyReplacement(original: item.originalWord, replacement: replacement)
                    return Self.isPlausibleReplacement(candidate) ? candidate : nil
                }
                guard !accepted.isEmpty else { continue }

                let wordRange = window.wordRange
                let updated = Self.applying(accepted, to: Array(result[wordRange]))
                result.replaceSubrange(wordRange, with: updated)
                acousticReplacements += accepted.count
            }
        } catch {
            Log.transcription.warning("Vocabulary boosting skipped acoustic check: \(error.localizedDescription)")
        }

        Log.transcription.info(
            "Vocabulary boosting: \(boostable.count) term(s), \(candidates.count) near match(es), \(acousticReplacements) replacement(s) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - started))s"
        )
        return result
    }

    private func preparedVocabularyBooster(
        terms: [String]
    ) async throws -> (CtcKeywordSpotter, CustomVocabularyContext, VocabularyRescorer)? {
        guard !terms.isEmpty else { return nil }

        let spotter: CtcKeywordSpotter
        if let vocabularySpotter {
            spotter = vocabularySpotter
        } else {
            // ~100MB, downloaded once into FluidAudio's shared cache on first use.
            let models = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            spotter = CtcKeywordSpotter(models: models)
            vocabularySpotter = spotter
        }

        if let cache = vocabularyCache, cache.terms == terms {
            return (spotter, cache.vocabulary, cache.rescorer)
        }

        let tokenizer = try await CtcTokenizer.load(from: CtcModels.defaultCacheDirectory(for: .ctc110m))
        let vocabulary = CustomVocabularyContext(terms: terms.compactMap { term in
            let tokenIDs = tokenizer.encode(term)
            guard !tokenIDs.isEmpty else { return nil }
            return CustomVocabularyTerm(text: term, ctcTokenIds: tokenIDs)
        })
        guard !vocabulary.terms.isEmpty else { return nil }
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: vocabulary,
            ctcModelDirectory: CtcModels.defaultCacheDirectory(for: .ctc110m)
        )
        vocabularyCache = (terms, vocabulary, rescorer)
        return (spotter, vocabulary, rescorer)
    }

    struct VocabularyReplacement: Equatable {
        let original: String
        let replacement: String
    }

    struct VocabularyCandidate: Equatable {
        let wordRange: Range<Int>
        let term: String
    }

    /// Distinct, trimmed terms whose letters are long enough to match reliably.
    nonisolated static func boostableTerms(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { spellingKey($0).count >= 3 && seen.insert(spellingKey($0)).inserted }
    }

    /// Letters and digits only, lowercased: "D'Sa" → "dsa", "live kit" → "livekit".
    nonisolated static func spellingKey(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// 1 − normalized Levenshtein distance between the spelling keys.
    nonisolated static func spellingSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let a = Array(spellingKey(lhs))
        let b = Array(spellingKey(rhs))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }

    /// Rejects replacements that don't resemble what was transcribed. Short terms
    /// ("Russ") collide with many common words, so they also need the same first
    /// letter and a closer spelling ("Desa" → "D'Sa" yes, "guess" → "Russ" no).
    nonisolated static func isPlausibleReplacement(_ replacement: VocabularyReplacement) -> Bool {
        let originalKey = spellingKey(replacement.original)
        let termKey = spellingKey(replacement.replacement)
        guard !originalKey.isEmpty, originalKey != termKey else { return false }
        // "and LiveKit" → "LiveKit" would only delete a real word.
        guard !replacement.original.split(separator: " ").contains(where: { spellingKey(String($0)) == termKey }) else {
            return false
        }
        let similarity = spellingSimilarity(originalKey, termKey)
        if termKey.count <= 4 {
            return originalKey.first == termKey.first && similarity >= 0.75
        }
        return similarity >= vocabularyMinimumSimilarity
    }

    /// Word spans that spell a term exactly apart from spacing, case, and punctuation
    /// take the term's canonical spelling ("live kit" → "LiveKit", "russ" → "Russ").
    nonisolated static func applyingExactTermSpellings(_ terms: [String], to words: [TimedWord]) -> [TimedWord] {
        let keyed = terms.map { (term: $0, key: spellingKey($0), span: max(1, $0.split(separator: " ").count + 1)) }
        var result: [TimedWord] = []
        var index = 0
        outer: while index < words.count {
            for (term, key, maxSpan) in keyed {
                for length in stride(from: min(maxSpan, words.count - index), through: 1, by: -1) {
                    let span = words[index..<(index + length)]
                    guard span.map({ spellingKey($0.text) }).joined() == key else { continue }
                    let original = span.map(\.text).joined(separator: " ")
                    let trailing = trailingPunctuation(of: span.last?.text ?? "")
                    let canonical = term + trailing
                    result.append(original == canonical ? span.first! : TimedWord(
                        text: canonical,
                        startTime: span.first!.startTime,
                        endTime: span.last!.endTime,
                        confidence: span.map(\.confidence).max() ?? 0
                    ))
                    if length > 1, original == canonical {
                        result.append(contentsOf: span.dropFirst())
                    }
                    index += length
                    continue outer
                }
            }
            result.append(words[index])
            index += 1
        }
        return result
    }

    /// Spans (up to one word longer than the term) whose spelling is close to a term
    /// but not already an exact spelling of it.
    nonisolated static func vocabularyCandidates(
        in words: [TimedWord],
        terms: [String],
        minimumSimilarity: Double = vocabularyMinimumSimilarity
    ) -> [VocabularyCandidate] {
        var candidates: [VocabularyCandidate] = []
        let keys = words.map { spellingKey($0.text) }
        for term in terms {
            let termKey = spellingKey(term)
            let maxSpan = term.split(separator: " ").count + 1
            for start in words.indices {
                for length in 1...maxSpan where start + length <= words.count {
                    let spanKeys = keys[start..<(start + length)]
                    let spanKey = spanKeys.joined()
                    guard spanKey != termKey,
                          !spanKeys.contains(termKey),
                          abs(spanKey.count - termKey.count) <= max(2, termKey.count / 2),
                          spellingSimilarity(spanKey, termKey) >= minimumSimilarity else {
                        continue
                    }
                    candidates.append(VocabularyCandidate(wordRange: start..<(start + length), term: term))
                }
            }
        }
        return candidates
    }

    /// Short audio windows (±2s) around candidate spans, merged when they overlap,
    /// with the word index range each window covers.
    nonisolated static func candidateWindows(
        _ candidates: [VocabularyCandidate],
        words: [TimedWord],
        audioDuration: TimeInterval,
        padding: TimeInterval = 2
    ) -> [(start: TimeInterval, end: TimeInterval, wordRange: Range<Int>)] {
        let spans = candidates.map { candidate -> (start: TimeInterval, end: TimeInterval) in
            (words[candidate.wordRange.lowerBound].startTime, words[candidate.wordRange.upperBound - 1].endTime)
        }.sorted { $0.start < $1.start }

        var merged: [(start: TimeInterval, end: TimeInterval)] = []
        for span in spans {
            let padded = (start: max(0, span.start - padding), end: min(audioDuration, span.end + padding))
            if let last = merged.last, padded.start <= last.end {
                merged[merged.count - 1].end = max(last.end, padded.end)
            } else {
                merged.append(padded)
            }
        }

        return merged.compactMap { window in
            let indices = words.indices.filter { words[$0].startTime >= window.start && words[$0].startTime < window.end }
            guard let first = indices.first, let last = indices.last else { return nil }
            return (window.start, window.end, first..<(last + 1))
        }
    }

    nonisolated static func trailingPunctuation(of text: String) -> String {
        String(text.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
    }

    /// Applies rescorer replacements (each an original word or multi-word span) to the
    /// words in order. The replacement keeps the span's timing and any trailing
    /// punctuation of its last word.
    nonisolated static func applying(_ replacements: [VocabularyReplacement], to words: [TimedWord]) -> [TimedWord] {
        var result = words
        var cursor = 0
        for replacement in replacements {
            let target = spellingKey(replacement.original)
            guard !target.isEmpty, cursor < result.count else { continue }
            let spanLimit = max(1, replacement.original.split(separator: " ").count)
            var matched: (index: Int, length: Int)?
            search: for index in cursor..<result.count {
                for length in 1...spanLimit where index + length <= result.count {
                    if result[index..<(index + length)].map({ spellingKey($0.text) }).joined() == target {
                        matched = (index, length)
                        break search
                    }
                }
            }
            guard let matched else { continue }

            let span = result[matched.index..<(matched.index + matched.length)]
            let merged = TimedWord(
                text: replacement.replacement + trailingPunctuation(of: span.last?.text ?? ""),
                startTime: span.first?.startTime ?? 0,
                endTime: span.last?.endTime ?? 0,
                confidence: span.map(\.confidence).max() ?? 0
            )
            result.replaceSubrange(matched.index..<(matched.index + matched.length), with: [merged])
            cursor = matched.index + 1
        }
        return result
    }

    private func recognize(audioData: Data) async throws -> ASRResult {
        guard state == .ready else {
            throw EngineError.modelNotLoaded
        }
        
        guard !audioData.isEmpty else {
            throw EngineError.invalidAudioData
        }
        
        guard transcribingTask == nil else {
            throw EngineError.transcriptionFailed("Transcription already in progress")
        }
        
        guard let asrManager = asrManager else {
            throw EngineError.modelNotLoaded
        }
        
        state = .transcribing
        
        do {
            let samples = Self.paddedForMinimumDuration(
                audioData.withUnsafeBytes { bytes in
                    Array(bytes.bindMemory(to: Float.self))
                }
            )

            // FluidAudio 0.15+: batch transcribe requires an explicit TDT decoder state.
            let decoderLayers = await asrManager.decoderLayerCount
            var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
            let result = try await asrManager.transcribe(samples, decoderState: &decoderState)

            state = .ready
            return result
        } catch {
            state = .ready
            self.error = error
            throw EngineError.transcriptionFailed(error.localizedDescription)
        }
    }

    /// Joins SentencePiece tokens into words. A token that starts with a space opens
    /// a new word; punctuation and word-piece continuations attach to the current one.
    nonisolated static func words(from tokens: [TokenTiming]) -> [TimedWord] {
        var words: [TimedWord] = []
        var text = ""
        var startTime: TimeInterval = 0
        var endTime: TimeInterval = 0
        var confidences: [Float] = []

        func flush() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let confidence = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)
                words.append(TimedWord(text: trimmed, startTime: startTime, endTime: endTime, confidence: confidence))
            }
            text = ""
            confidences = []
        }

        for token in tokens.sorted(by: { $0.startTime < $1.startTime }) {
            if token.token.hasPrefix(" "), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                startTime = token.startTime
            }
            text += token.token
            endTime = max(endTime, token.endTime)
            confidences.append(token.confidence)
        }
        flush()
        return words
    }

    /// Fallback when an ASR result carries no token timings: spread the words evenly.
    nonisolated static func evenlyTimedWords(text: String, duration: TimeInterval) -> [TimedWord] {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return [] }
        let step = max(duration, 0.01) / Double(parts.count)
        return parts.enumerated().map { index, part in
            TimedWord(
                text: part,
                startTime: Double(index) * step,
                endTime: Double(index + 1) * step,
                confidence: 0
            )
        }
    }
    
    public func unloadModel() async {
        transcribingTask?.cancel()
        transcribingTask = nil
        
        asrManager = nil
        error = nil
        state = .unloaded
    }
    
    public func loadModel(modelName: String) async throws {
        try await loadModel(name: modelName, downloadBase: nil)
    }
    
    public func loadModel(modelPath: String) async throws {
        try await loadModel(path: modelPath)
    }

    /// FluidAudio rejects clips under 0.3s as invalid audio. Pad a quick hotkey tap
    /// with trailing silence so it surfaces as "no speech" instead of an error.
    nonisolated static func paddedForMinimumDuration(_ samples: [Float]) -> [Float] {
        let minimumSamples = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        guard samples.count < minimumSamples else { return samples }
        return samples + [Float](repeating: 0, count: minimumSamples - samples.count)
    }

    // MARK: - Model Location

    /// Maps a catalog name to its FluidAudio model version; nil for Parakeet
    /// catalog entries this engine can't load (e.g. the coming-soon 1.1B).
    nonisolated static func modelVersion(forModelName name: String) -> AsrModelVersion? {
        if name.contains("v3") { return .v3 }
        if name.contains("v2") { return .v2 }
        return nil
    }

    /// Where ModelManager downloads Parakeet. FluidAudio stores a repo under
    /// `<parent>/<repo folderName>`, so this mirrors the path its download writes.
    nonisolated static func appModelDirectory(downloadBase: URL, version: AsrModelVersion) -> URL {
        let repo: Repo = version == .v3 ? .parakeetV3 : .parakeetV2
        return downloadBase
            .appendingPathComponent("FluidInference", isDirectory: true)
            .appendingPathComponent("parakeet-coreml", isDirectory: true)
            .appendingPathComponent(repo.folderName, isDirectory: true)
    }

    /// Resolves a complete on-disk Parakeet model set, preferring the app's download
    /// folder and falling back to FluidAudio's shared default cache. Returns nil when
    /// neither location holds every required file.
    nonisolated static func resolveModelDirectory(
        version: AsrModelVersion,
        downloadBase: URL?,
        fluidAudioCacheDirectory: URL? = nil,
        modelsExist: (URL, AsrModelVersion) -> Bool = { AsrModels.modelsExist(at: $0, version: $1) }
    ) -> URL? {
        var candidates: [URL] = []
        if let downloadBase {
            candidates.append(appModelDirectory(downloadBase: downloadBase, version: version))
        }
        candidates.append(fluidAudioCacheDirectory ?? AsrModels.defaultCacheDirectory(for: version))
        return candidates.first { modelsExist($0, version) }
    }
}
