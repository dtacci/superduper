//
//  ParakeetEngine.swift
//  Pindrop
//
//  Created on 2026-01-30.
//

import Foundation
import FluidAudio

@MainActor
public final class ParakeetEngine: TranscriptionEngine, CapabilityReporting {
    
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
            return result.text
        } catch {
            state = .ready
            self.error = error
            throw EngineError.transcriptionFailed(error.localizedDescription)
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
