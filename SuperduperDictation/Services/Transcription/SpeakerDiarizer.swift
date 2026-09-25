//
//  SpeakerDiarizer.swift
//  SuperduperDictation
//
//  Created on 2026-01-30.
//

import Foundation

public struct Speaker: Identifiable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let embedding: [Float]?

    public init(id: String, label: String, embedding: [Float]? = nil) {
        self.id = id
        self.label = label
        self.embedding = embedding
    }
}

public struct SpeakerSegment: Sendable, Equatable {
    public let speaker: Speaker
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    public init(speaker: Speaker, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    public var duration: TimeInterval {
        endTime - startTime
    }
}

public struct DiarizationResult: Sendable, Equatable {
    public let segments: [SpeakerSegment]
    public let speakers: [Speaker]
    public let audioDuration: TimeInterval

    public init(segments: [SpeakerSegment], speakers: [Speaker], audioDuration: TimeInterval) {
        self.segments = segments
        self.speakers = speakers
        self.audioDuration = audioDuration
    }

    public var speakerCount: Int {
        speakers.count
    }
}

public struct DiarizedTranscriptSegment: Codable, Sendable, Equatable {
    public let speakerId: String
    public let speakerLabel: String
    public let speakerProfileID: UUID?
    public let speakerEmbedding: [Float]?
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float
    public let text: String

    public init(
        speakerId: String,
        speakerLabel: String,
        speakerProfileID: UUID? = nil,
        speakerEmbedding: [Float]? = nil,
        startTime: TimeInterval,
        endTime: TimeInterval,
        confidence: Float,
        text: String
    ) {
        self.speakerId = speakerId
        self.speakerLabel = speakerLabel
        self.speakerProfileID = speakerProfileID
        self.speakerEmbedding = speakerEmbedding
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
        self.text = text
    }
}

public struct TranscriptionOutput: Sendable, Equatable {
    public let text: String
    public let diarizedSegments: [DiarizedTranscriptSegment]?

    public init(text: String, diarizedSegments: [DiarizedTranscriptSegment]? = nil) {
        self.text = text
        self.diarizedSegments = diarizedSegments
    }
}

public enum SpeakerDiarizerState: Equatable, Sendable {
    case unloaded
    case loading
    case ready
    case processing
    case error
}

public enum DiarizationMode: Sendable {
    case offline
    case online
}

/// Per-call options for anonymous offline speaker clustering.
public struct DiarizationOptions: Sendable, Equatable {
    /// Exact speaker count constraint. `nil` selects automatic detection.
    public let expectedSpeakerCount: Int?

    public init(expectedSpeakerCount: Int? = nil) {
        self.expectedSpeakerCount = expectedSpeakerCount
    }
}

@MainActor
public protocol SpeakerDiarizer: AnyObject {
    var state: SpeakerDiarizerState { get }
    var mode: DiarizationMode { get }

    func loadModels() async throws
    func unloadModels() async

    func diarize(audioData: Data) async throws -> DiarizationResult
    func diarize(samples: [Float], sampleRate: Int, options: DiarizationOptions) async throws -> DiarizationResult
}

extension SpeakerDiarizer {
    public func diarize(samples: [Float], sampleRate: Int) async throws -> DiarizationResult {
        try await diarize(samples: samples, sampleRate: sampleRate, options: .init())
    }

    public func diarize(audioData: Data) async throws -> DiarizationResult {
        let samples = audioData.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
        return try await diarize(samples: samples, sampleRate: 16000, options: .init())
    }
}

/// Builds speaker-attributed transcript turns from word timings. Meetings run ASR
/// once per audio track and use this to attribute each word, instead of cutting the
/// audio into diarized turns and transcribing every turn separately (slow, and it
/// dropped any speech the diarizer didn't cover).
enum MeetingTranscriptAssembler {
    struct Turn: Equatable {
        let speakerKey: String
        let startTime: TimeInterval
        let endTime: TimeInterval
        let text: String
    }

    /// Diarized speaker for each word: the turn containing the word's midpoint, else
    /// the nearest turn within `maximumDistance`, else nil.
    static func assignSpeakers(
        to words: [TimedWord],
        segments: [SpeakerSegment],
        maximumDistance: TimeInterval = 2.0
    ) -> [String?] {
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        return words.map { word in
            let midpoint = word.midpoint
            var best: (distance: TimeInterval, speakerID: String)?
            for segment in sorted {
                let distance: TimeInterval
                if midpoint < segment.startTime {
                    distance = segment.startTime - midpoint
                } else if midpoint > segment.endTime {
                    distance = midpoint - segment.endTime
                } else {
                    return segment.speaker.id
                }
                if distance <= maximumDistance, distance < (best?.distance ?? .infinity) {
                    best = (distance, segment.speaker.id)
                }
            }
            return best?.speakerID
        }
    }

    /// Drops microphone utterances that are really the far end playing out of the
    /// speakers: most of their words also appear in the system track at nearly the
    /// same moment. Genuine speech (including on headphones) is kept.
    static func removeEchoes(
        from microphoneWords: [TimedWord],
        matching systemWords: [TimedWord],
        window: TimeInterval = 0.8,
        utteranceGap: TimeInterval = 0.8,
        minimumEchoRatio: Double = 0.5
    ) -> [TimedWord] {
        guard !microphoneWords.isEmpty, !systemWords.isEmpty else { return microphoneWords }
        let system = systemWords
            .map { (midpoint: $0.midpoint, text: normalizedToken($0.text)) }
            .sorted { $0.midpoint < $1.midpoint }

        func isEcho(_ word: TimedWord) -> Bool {
            let token = normalizedToken(word.text)
            guard !token.isEmpty else { return false }
            var low = 0
            var high = system.count
            while low < high {
                let mid = (low + high) / 2
                if system[mid].midpoint < word.midpoint - window { low = mid + 1 } else { high = mid }
            }
            var index = low
            while index < system.count, system[index].midpoint <= word.midpoint + window {
                if system[index].text == token { return true }
                index += 1
            }
            return false
        }

        var kept: [TimedWord] = []
        var utterance: [TimedWord] = []
        func flush() {
            guard !utterance.isEmpty else { return }
            let echoes = utterance.filter(isEcho).count
            if Double(echoes) / Double(utterance.count) < minimumEchoRatio {
                kept.append(contentsOf: utterance)
            }
            utterance.removeAll()
        }
        for word in microphoneWords.sorted(by: { $0.startTime < $1.startTime }) {
            if let last = utterance.last, word.startTime - last.endTime > utteranceGap {
                flush()
            }
            utterance.append(word)
        }
        flush()
        return kept
    }

    /// Groups consecutive words from one speaker into turns, breaking on pauses.
    static func turns(
        words: [TimedWord],
        speakerKeys: [String],
        maximumGap: TimeInterval = 1.5
    ) -> [Turn] {
        precondition(words.count == speakerKeys.count)
        var turns: [Turn] = []
        var currentKey: String?
        var currentWords: [TimedWord] = []

        func flush() {
            guard let currentKey, let first = currentWords.first, let last = currentWords.last else { return }
            turns.append(Turn(
                speakerKey: currentKey,
                startTime: first.startTime,
                endTime: last.endTime,
                text: currentWords.map(\.text).joined(separator: " ")
            ))
            currentWords.removeAll()
        }

        for (word, key) in zip(words, speakerKeys) {
            if key != currentKey || (currentWords.last.map { word.startTime - $0.endTime > maximumGap } ?? false) {
                flush()
                currentKey = key
            }
            currentWords.append(word)
        }
        flush()
        return turns
    }

    /// Interleaves turns from separate tracks into one conversation by start time.
    static func merged(_ turnGroups: [[Turn]]) -> [Turn] {
        turnGroups.flatMap { $0 }.sorted {
            $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
        }
    }

    static func normalizedToken(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
