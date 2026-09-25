//
//  TranscriptionEngine.swift
//  SuperduperDictation
//
//  Created on 2026-01-30.
//

import Foundation

public struct TranscriptionOptions: Sendable, Equatable {
    public let language: AppLanguage
    /// Terms to favor: WhisperKit uses them as initial-prompt biasing, Parakeet as
    /// vocabulary boosting, including acoustic checks of near-misspellings. Empty = no bias.
    public let vocabularyBiasWords: [String]
    /// Glossary terms (vocabulary packs) that Parakeet only corrects deterministically:
    /// spacing/case, "sounds like" spellings, and spelled-out letters. Large glossaries
    /// full of near-common words ("KiCad", "Inworld") make fuzzy matching misfire.
    public let vocabularyBoostTerms: [String]
    /// Spellings speech recognition produces for a term ("TNC" for "Teensy"), keyed by
    /// the term. Parakeet replaces them with the term.
    public let vocabularySoundsLike: [String: [String]]

    public init(
        language: AppLanguage = .automatic,
        vocabularyBiasWords: [String] = [],
        vocabularyBoostTerms: [String] = [],
        vocabularySoundsLike: [String: [String]] = [:]
    ) {
        self.language = language
        self.vocabularyBiasWords = vocabularyBiasWords
        self.vocabularyBoostTerms = vocabularyBoostTerms
        self.vocabularySoundsLike = vocabularySoundsLike
    }

    /// Every term Parakeet should boost.
    var allBoostTerms: [String] {
        vocabularyBiasWords + vocabularyBoostTerms + vocabularySoundsLike.keys.sorted()
    }
}

/// Represents the current state of a transcription engine
public enum TranscriptionEngineState: Equatable {
    case unloaded
    case loading
    case ready
    case transcribing
    case error
}

public struct TranscriptionProgressUpdate: Equatable, Sendable {
    public let fractionCompleted: Double
    public let elapsed: TimeInterval
    public let estimatedRemaining: TimeInterval?

    public init(
        fractionCompleted: Double,
        elapsed: TimeInterval,
        estimatedRemaining: TimeInterval?
    ) {
        self.fractionCompleted = min(1, max(0, fractionCompleted))
        self.elapsed = max(0, elapsed)
        self.estimatedRemaining = estimatedRemaining.map { max(0, $0) }
    }
}

public typealias TranscriptionProgressHandler = (TranscriptionProgressUpdate) -> Void

/// Protocol abstraction for speech-to-text engines
/// Allows TranscriptionService to work with multiple backends (WhisperKit, Parakeet, etc.)
@MainActor
public protocol TranscriptionEngine: AnyObject {
    /// Current state of the engine
    var state: TranscriptionEngineState { get }
    
    /// Load a model from a local file path
    /// - Parameter path: Absolute path to the model directory
    func loadModel(path: String) async throws
    
    /// Load a model by name, optionally downloading if not present locally
    /// - Parameters:
    ///   - name: Model identifier (e.g., "tiny", "base", "small")
    ///   - downloadBase: Optional URL for downloading models if not cached locally
    func loadModel(name: String, downloadBase: URL?) async throws
    
    /// Transcribe audio data to text
    /// - Parameter audioData: Raw audio data (expected format: 16kHz mono PCM Float32)
    /// - Returns: Transcribed text
    func transcribe(audioData: Data, options: TranscriptionOptions) async throws -> String

    /// Transcribe while reporting best-effort progress. Engines without native
    /// callbacks use the default implementation and still report start/finish.
    func transcribe(
        audioData: Data,
        options: TranscriptionOptions,
        progressHandler: TranscriptionProgressHandler?
    ) async throws -> String

    /// Detect the spoken language in raw samples, when supported.
    /// - Parameters:
    ///   - samples: Raw audio samples (expected format: 16kHz mono PCM Float32)
    ///   - sampleRate: Sample rate for the provided samples
    /// - Returns: A concrete app language, or nil when detection is unavailable.
    func detectLanguage(samples: [Float], sampleRate: Int) async throws -> AppLanguage?
    
    /// Unload the model and free resources
    func unloadModel() async
}

public extension TranscriptionEngine {
    func transcribe(audioData: Data) async throws -> String {
        try await transcribe(audioData: audioData, options: TranscriptionOptions())
    }

    func detectLanguage(samples: [Float], sampleRate: Int) async throws -> AppLanguage? {
        nil
    }

    func transcribe(
        audioData: Data,
        options: TranscriptionOptions,
        progressHandler: TranscriptionProgressHandler?
    ) async throws -> String {
        let startedAt = Date()
        progressHandler?(TranscriptionProgressUpdate(fractionCompleted: 0, elapsed: 0, estimatedRemaining: nil))
        let text = try await transcribe(audioData: audioData, options: options)
        progressHandler?(
            TranscriptionProgressUpdate(
                fractionCompleted: 1,
                elapsed: Date().timeIntervalSince(startedAt),
                estimatedRemaining: 0
            )
        )
        return text
    }
}

/// A recognized word and where it sits in the source audio.
public struct TimedWord: Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let confidence: Float

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval, confidence: Float) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }

    public var midpoint: TimeInterval { (startTime + endTime) / 2 }
}

/// Engines that can transcribe long audio in one pass and report per-word timing.
/// Meetings use this to attribute words to speakers after a single ASR pass instead
/// of re-transcribing every diarized turn separately.
@MainActor
public protocol TimedTranscriptionEngine: TranscriptionEngine {
    func transcribeWords(audioData: Data, options: TranscriptionOptions) async throws -> [TimedWord]
}
