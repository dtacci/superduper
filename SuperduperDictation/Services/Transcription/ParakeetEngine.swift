//
//  ParakeetEngine.swift
//  SuperduperDictation
//
//  Created on 2026-01-30.
//

import AppKit
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
        guard !options.allBoostTerms.isEmpty else {
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
        guard !options.allBoostTerms.isEmpty else { return words }
        return await boostVocabulary(
            words: words,
            tokenTimings: tokenTimings,
            audioData: audioData,
            terms: options.allBoostTerms,
            nearMatchTerms: options.vocabularyBiasWords,
            soundsLike: options.vocabularySoundsLike
        )
    }

    // MARK: - Vocabulary boosting

    /// Minimum spelling similarity for a transcript span to be treated as a possible
    /// mishearing of a vocabulary term (and for any replacement to be accepted).
    nonisolated static let vocabularyMinimumSimilarity = 0.6

    /// Conservative, in order:
    /// 1. Spans that already spell a term, or one of its "sounds like" spellings, apart
    ///    from spacing/case/punctuation take the canonical term ("live kit" → "LiveKit",
    ///    "TNC" → "Teensy" when listed). No audio needed.
    /// 2. Near-misspellings of `nearMatchTerms` (names and dictionary words, e.g. "Desa"
    ///    for "D'Sa") are verified with FluidAudio's CTC rescorer on a few seconds of
    ///    audio around each, and the replacement must still resemble the original.
    /// 3. Spelled-out letters or made-up spellings that sound like any term ("T N C",
    ///    "Tinsi" ≈ "Teensy") are accepted only when the CTC keyword spotter detects the
    ///    term at that spot. Glossary terms never replace real words by spelling alone;
    ///    with hundreds of terms that misfires ("kind" → "KiCad").
    /// Transcripts without candidates cost nothing; any failure leaves them unchanged.
    private func boostVocabulary(
        words: [TimedWord],
        tokenTimings: [TokenTiming],
        audioData: Data,
        terms: [String],
        nearMatchTerms: [String],
        soundsLike: [String: [String]]
    ) async -> [TimedWord] {
        let started = CFAbsoluteTimeGetCurrent()
        let boostable = Self.boostableTerms(terms)
        guard !boostable.isEmpty else { return words }

        var result = Self.applyingExactTermSpellings(boostable, soundsLike: soundsLike, to: words)
        let nearMatchable = Self.boostableTerms(nearMatchTerms)
        let nearMatchKeys = Set(nearMatchable.map(Self.spellingKey))
        let glossaryTerms = Set(boostable.filter { !nearMatchKeys.contains(Self.spellingKey($0)) })
        let spellingCandidates = Self.vocabularyCandidates(in: result, terms: nearMatchable)
        let soundAlikes = Self.soundAlikeCandidates(in: result, terms: boostable, isWord: Self.isEverydayWord)
        let candidates = spellingCandidates + soundAlikes
        guard !candidates.isEmpty else {
            Log.transcription.info(
                "Vocabulary boosting: \(boostable.count) term(s), no near matches in \(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - started))s"
            )
            return result
        }

        var acousticReplacements = 0
        do {
            // Only terms that could apply here go to the spotter; it scales with vocabulary size.
            var acousticTerms = nearMatchable
            for term in Set(soundAlikes.map(\.term)).sorted() where !acousticTerms.contains(term) {
                acousticTerms.append(term)
            }
            guard let (spotter, vocabulary, rescorer) = try await preparedVocabularyBooster(terms: acousticTerms) else {
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

                // Sound-alike matches: replace by position when the spotter heard the term there.
                var wordRange = window.wordRange
                let confirmedSoundAlikes = soundAlikes
                    .filter { wordRange.contains($0.wordRange.lowerBound) }
                    .filter { candidate in
                        let spanStart = result[candidate.wordRange.lowerBound].startTime - window.start
                        let spanEnd = result[candidate.wordRange.upperBound - 1].endTime - window.start
                        return spot.detections.contains { detection in
                            detection.term.text.caseInsensitiveCompare(candidate.term) == .orderedSame
                                && detection.score >= ContextBiasingConstants.defaultMinVocabCtcScore
                                && detection.startTime < spanEnd + 0.3
                                && detection.endTime > spanStart - 0.3
                        }
                    }
                    .sorted { $0.wordRange.lowerBound > $1.wordRange.lowerBound }
                var replacedSoundAlikeStart = Int.max
                for candidate in confirmedSoundAlikes where candidate.wordRange.upperBound <= replacedSoundAlikeStart {
                    let span = result[candidate.wordRange]
                    result.replaceSubrange(candidate.wordRange, with: [TimedWord(
                        text: candidate.term + Self.trailingPunctuation(of: span.last?.text ?? ""),
                        startTime: span.first?.startTime ?? 0,
                        endTime: span.last?.endTime ?? 0,
                        confidence: span.map(\.confidence).max() ?? 0
                    )])
                    wordRange = wordRange.lowerBound..<(wordRange.upperBound - (candidate.wordRange.count - 1))
                    replacedSoundAlikeStart = candidate.wordRange.lowerBound
                    acousticReplacements += 1
                }

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
                    guard Self.isPlausibleReplacement(candidate) else { return nil }
                    if glossaryTerms.contains(replacement),
                       candidate.original.split(separator: " ").contains(where: { Self.isEverydayWord(String($0)) }) {
                        return nil
                    }
                    return candidate
                }
                guard !accepted.isEmpty, !wordRange.isEmpty else { continue }

                let updated = Self.applying(accepted, to: Array(result[wordRange]))
                result.replaceSubrange(wordRange, with: updated)
                acousticReplacements += accepted.count
            }
        } catch {
            Log.transcription.warning("Vocabulary boosting skipped acoustic check: \(error.localizedDescription)")
        }

        Log.transcription.info(
            "Vocabulary boosting: \(boostable.count) term(s), \(candidates.count) candidate(s), \(acousticReplacements) replacement(s) in \(String(format: "%.2f", CFAbsoluteTimeGetCurrent() - started))s"
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

    /// Word spans that spell a term, or one of its "sounds like" spellings, exactly
    /// apart from spacing, case, and punctuation take the term's canonical spelling
    /// ("live kit" → "LiveKit", "russ" → "Russ", "TNC" → "Teensy" when listed).
    /// All-caps terms only match capitals: "sip" isn't "SIP", "a DC motor" isn't "ADC".
    nonisolated static func applyingExactTermSpellings(
        _ terms: [String],
        soundsLike: [String: [String]] = [:],
        to words: [TimedWord]
    ) -> [TimedWord] {
        var canonicalByKey: [String: (term: String, isAlias: Bool)] = [:]
        var maxSpan = 1
        func register(_ spelling: String, as term: String, isAlias: Bool) {
            let key = spellingKey(spelling)
            guard key.count >= 2 else { return }
            // Acronyms may come out letter by letter ("B V C").
            maxSpan = max(maxSpan, spelling.split(separator: " ").count + 1, isAcronym(spelling) ? key.count : 0)
            if canonicalByKey[key] == nil {
                canonicalByKey[key] = (term, isAlias)
            }
        }
        terms.forEach { register($0, as: $0, isAlias: false) }
        for term in soundsLike.keys.sorted() {
            soundsLike[term]?.forEach { register($0, as: term, isAlias: true) }
        }
        guard !canonicalByKey.isEmpty else { return words }

        let keys = words.map { spellingKey($0.text) }
        var result: [TimedWord] = []
        var index = 0
        while index < words.count {
            var matched = false
            for length in stride(from: min(maxSpan, words.count - index), through: 1, by: -1) {
                guard let (term, isAlias) = canonicalByKey[keys[index..<(index + length)].joined()] else { continue }
                let span = words[index..<(index + length)]
                if !isAlias, isAcronym(term), !span.allSatisfy({ isWrittenInCapitals($0.text) }) {
                    continue
                }
                let canonical = term + trailingPunctuation(of: span.last?.text ?? "")
                if span.map(\.text).joined(separator: " ") == canonical {
                    result.append(contentsOf: span)
                } else {
                    result.append(TimedWord(
                        text: canonical,
                        startTime: span.first!.startTime,
                        endTime: span.last!.endTime,
                        confidence: span.map(\.confidence).max() ?? 0
                    ))
                }
                index += length
                matched = true
                break
            }
            if !matched {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    /// Spans (up to one word longer than the term) whose spelling is close to a term
    /// but not already an exact spelling of it. Only terms that start with the same
    /// sound are compared ("Kristin"/"Christine"), which keeps large glossaries cheap.
    nonisolated static func vocabularyCandidates(
        in words: [TimedWord],
        terms: [String],
        minimumSimilarity: Double = vocabularyMinimumSimilarity
    ) -> [VocabularyCandidate] {
        var termsByInitial: [Character: [(term: String, key: String, maxSpan: Int)]] = [:]
        for term in terms {
            let key = spellingKey(term)
            guard let initial = initialSound(of: key) else { continue }
            termsByInitial[initial, default: []].append((term, key, term.split(separator: " ").count + 1))
        }
        let overallMaxSpan = termsByInitial.values.flatMap { $0 }.map(\.maxSpan).max() ?? 1
        let keys = words.map { spellingKey($0.text) }

        var candidates: [VocabularyCandidate] = []
        for start in words.indices {
            guard let initial = initialSound(of: keys[start]), let group = termsByInitial[initial] else { continue }
            for length in 1...overallMaxSpan where start + length <= words.count {
                let spanKeys = keys[start..<(start + length)]
                let spanKey = spanKeys.joined()
                for entry in group where length <= entry.maxSpan {
                    guard spanKey != entry.key,
                          !spanKeys.contains(entry.key),
                          abs(spanKey.count - entry.key.count) <= max(2, entry.key.count / 2),
                          spellingSimilarity(spanKey, entry.key) >= minimumSimilarity else {
                        continue
                    }
                    candidates.append(VocabularyCandidate(wordRange: start..<(start + length), term: entry.term))
                }
            }
        }
        return candidates
    }

    /// First letter, with the hard "c"/"k"/"q" sound grouped together.
    private nonisolated static func initialSound(of key: String) -> Character? {
        guard let first = key.first else { return nil }
        return first == "c" || first == "q" ? "k" : first
    }

    /// Spans that sound like a word term by consonant skeleton: spelled-out capitals
    /// ("TNC", "T N C" ≈ "Teensy") or a made-up spelling ("Tinsi"). Real words never
    /// qualify, letters that already spell a term are left alone, and acronym terms
    /// aren't targets. The keyword spotter must confirm each one.
    nonisolated static func soundAlikeCandidates(
        in words: [TimedWord],
        terms: [String],
        isWord: (String) -> Bool
    ) -> [VocabularyCandidate] {
        var termsBySkeleton: [String: [String]] = [:]
        for term in terms where !isAcronym(term) {
            let skeleton = phoneticSkeleton(term)
            guard skeleton.count >= 3 else { continue }
            termsBySkeleton[skeleton, default: []].append(term)
        }
        guard !termsBySkeleton.isEmpty else { return [] }
        let termKeys = Set(terms.map(spellingKey))

        func letters(_ word: TimedWord) -> String? {
            let stripped = word.text.filter { $0 != "." && $0 != "," && $0 != "?" && $0 != "!" }
            guard (1...4).contains(stripped.count), stripped.allSatisfy({ $0.isASCII && $0.isUppercase }) else {
                return nil
            }
            return stripped
        }

        var candidates: [VocabularyCandidate] = []
        for start in words.indices {
            let key = spellingKey(words[start].text)
            if letters(words[start]) == nil, !termKeys.contains(key), let group = termsBySkeleton[phoneticSkeleton(key)] {
                let matches = group.filter { initialSound(of: spellingKey($0)) == initialSound(of: key) }
                if !matches.isEmpty, !isWord(words[start].text) {
                    candidates += matches.map { VocabularyCandidate(wordRange: start..<(start + 1), term: $0) }
                }
                continue
            }

            var spelled = ""
            for end in start..<min(words.count, start + 6) {
                guard let next = letters(words[end]) else { break }
                spelled += next
                // Spans start and end on a consonant sound, so "I" or "A" next to the
                // letters isn't swallowed.
                guard (2...6).contains(spelled.count),
                      !termKeys.contains(spelled.lowercased()),
                      let first = spelled.first, let last = spelled.last,
                      !phoneticSkeleton(spokenLetterNames(String(first))).isEmpty,
                      !phoneticSkeleton(spokenLetterNames(String(last))).isEmpty else {
                    continue
                }
                for term in termsBySkeleton[phoneticSkeleton(spokenLetterNames(spelled))] ?? [] {
                    candidates.append(VocabularyCandidate(wordRange: start..<(end + 1), term: term))
                }
            }
        }
        return candidates
    }

    private nonisolated static let letterNames: [Character: String] = [
        "a": "ay", "b": "bee", "c": "see", "d": "dee", "e": "ee", "f": "ef", "g": "jee",
        "h": "aych", "i": "eye", "j": "jay", "k": "kay", "l": "el", "m": "em", "n": "en",
        "o": "oh", "p": "pee", "q": "cue", "r": "ar", "s": "es", "t": "tee", "u": "you",
        "v": "vee", "w": "doubleyou", "x": "ex", "y": "why", "z": "zee",
    ]

    /// "TNC" → "teeensee": how a string of letters is pronounced.
    nonisolated static func spokenLetterNames(_ letters: String) -> String {
        letters.lowercased().compactMap { letterNames[$0] }.joined()
    }

    /// Dictionary words (and numbers and single letters), which glossary terms never
    /// replace: "kind" isn't a mishearing of "KiCad", but "Tinsi" is one of "Teensy".
    static func isEverydayWord(_ word: String) -> Bool {
        let trimmed = word.trimmingCharacters(in: .punctuationCharacters)
        guard trimmed.filter(\.isLetter).count > 1 else { return true }
        let misspelled = NSSpellChecker.shared.checkSpelling(
            of: trimmed,
            startingAt: 0,
            language: "en",
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return misspelled.location == NSNotFound
    }

    /// Words written as capitals ("DC", "i2S", "B", "32"), unlike everyday words
    /// ("sip", "Sip", "a", "A", "I").
    nonisolated static func isWrittenInCapitals(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        if letters.count == 1 {
            return letters.allSatisfy(\.isUppercase) && letters != "A" && letters != "I"
        }
        return letters.isEmpty || letters.dropFirst().contains(where: \.isUppercase)
    }

    /// "STT", "I2S", "SGTL5000": capitals and digits only.
    nonisolated static func isAcronym(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        return !letters.isEmpty && letters.allSatisfy(\.isUppercase) && !term.contains(" ")
    }

    /// A rough consonant skeleton for comparing pronunciations: vowels dropped, soft
    /// "c" as "s", hard "c"/"q" as "k", "ph" as "f", repeats collapsed.
    /// "Teensy" and "teeensee" both become "tns".
    nonisolated static func phoneticSkeleton(_ text: String) -> String {
        let letters = Array(text.lowercased().filter { $0.isASCII && $0.isLetter })
        var skeleton: [Character] = []
        var index = 0
        while index < letters.count {
            let letter = letters[index]
            let next: Character? = index + 1 < letters.count ? letters[index + 1] : nil
            var sounds: [Character] = []
            switch letter {
            case "a", "e", "i", "o", "u", "y", "h":
                break
            case "p" where next == "h":
                sounds = ["f"]
                index += 1
            case "c" where next == "k":
                sounds = ["k"]
                index += 1
            case "c":
                sounds = [next == "e" || next == "i" || next == "y" ? "s" : "k"]
            case "q":
                sounds = ["k"]
            case "z":
                sounds = ["s"]
            case "x":
                sounds = ["k", "s"]
            case "g" where next == "e" || next == "i":
                sounds = ["j"]
            default:
                sounds = [letter]
            }
            for sound in sounds where skeleton.last != sound {
                skeleton.append(sound)
            }
            index += 1
        }
        return String(skeleton)
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
