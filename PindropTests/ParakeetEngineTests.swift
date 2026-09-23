//
//  ParakeetEngineTests.swift
//  PindropTests
//
//  Created on 2026-01-30.
//

import FluidAudio
import Foundation
import Testing
@testable import Pindrop

@MainActor
@Suite
struct ParakeetEngineTests {
    private func makeEngine() -> ParakeetEngine {
        ParakeetEngine()
    }

    private func makeInt16AudioData(sampleCount: Int = 16_000) -> Data {
        var audioData = Data()
        for _ in 0..<sampleCount {
            var sample: Int16 = 0
            audioData.append(Data(bytes: &sample, count: MemoryLayout<Int16>.size))
        }
        return audioData
    }

    @Test func initialStateIsUnloaded() {
        let engine = makeEngine()
        #expect(engine.state == .unloaded, "Initial state should be unloaded")
        #expect(engine.error == nil, "Initial error should be nil")
    }

    @Test func loadModelSetsStateToReady() async throws {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        do {
            try await engine.loadModel(modelName: "parakeet-tdt-0.6b-v2")
        } catch {
        }

        #expect(engine.state != .unloaded, "State should change from unloaded when loading starts")
    }

    @Test func loadModelTransitionsThroughLoadingState() async throws {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        Task {
            do {
                try await engine.loadModel(modelName: "parakeet-tdt-0.6b-v2")
            } catch {
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(engine.state != .unloaded, "State should transition from unloaded when loading starts")
    }

    @Test func loadModelWithPathNotSupported() async throws {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        do {
            try await engine.loadModel(modelPath: "/some/path/to/model")
            Issue.record("Should throw error for path-based loading")
        } catch ParakeetEngine.EngineError.initializationFailed {
            #expect(engine.state == .error, "State should be error after failed load")
            #expect(engine.error != nil, "Error should be set after failed load")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func transcribeRequiresLoadedModel() async throws {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        do {
            _ = try await engine.transcribe(audioData: makeInt16AudioData())
            Issue.record("Should throw error when model not loaded")
        } catch ParakeetEngine.EngineError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func transcribeWithEmptyAudioDataThrowsError() async throws {
        let engine = makeEngine()

        do {
            try await engine.loadModel(modelName: "parakeet-tdt-0.6b-v2")
        } catch {
        }

        do {
            _ = try await engine.transcribe(audioData: Data())
            Issue.record("Should throw error for empty audio data")
        } catch ParakeetEngine.EngineError.invalidAudioData {
        } catch ParakeetEngine.EngineError.modelNotLoaded {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func unloadModelSetsStateToUnloaded() async throws {
        let engine = makeEngine()

        do {
            try await engine.loadModel(modelName: "parakeet-tdt-0.6b-v2")
        } catch {
        }

        await engine.unloadModel()

        #expect(engine.state == .unloaded, "State should be unloaded after unloadModel")
        #expect(engine.error == nil, "Error should be nil after unloadModel")
    }

    @Test func unloadModelClearsError() async throws {
        let engine = makeEngine()

        do {
            try await engine.loadModel(modelPath: "/invalid/path")
        } catch {
        }

        #expect(engine.error != nil, "Error should be set after failed load")

        await engine.unloadModel()

        #expect(engine.error == nil, "Error should be cleared after unloadModel")
    }

    @Test func unloadModelFromUnloadedStateIsSafe() async {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        await engine.unloadModel()

        #expect(engine.state == .unloaded, "State should remain unloaded")
        #expect(engine.error == nil, "Error should remain nil")
    }

    @Test func stateTransitions() async throws {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        Task {
            do {
                try await engine.loadModel(modelName: "parakeet-tdt-0.6b-v2")
            } catch {
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let stateAfterLoadAttempt = engine.state
        #expect(stateAfterLoadAttempt != .unloaded)

        await engine.unloadModel()
        #expect(engine.state == .unloaded)
    }

    @Test func concurrentTranscriptionPrevention() async throws {
        let engine = makeEngine()
        let audioData = makeInt16AudioData()

        async let result1 = engine.transcribe(audioData: audioData)
        async let result2 = engine.transcribe(audioData: audioData)

        do {
            _ = try await result1
            _ = try await result2
        } catch {
        }
    }

    @Test func errorDescriptionForModelNotLoaded() {
        let error = ParakeetEngine.EngineError.modelNotLoaded
        #expect(error.errorDescription != nil, "Error should have description")
        #expect(error.errorDescription?.contains("not loaded") ?? false,
                "Error description should mention model not loaded")
    }

    @Test func errorDescriptionForInvalidAudioData() {
        let error = ParakeetEngine.EngineError.invalidAudioData
        #expect(error.errorDescription != nil, "Error should have description")
        #expect(error.errorDescription?.contains("Invalid") ?? false,
                "Error description should mention invalid audio data")
    }

    @Test func errorDescriptionForTranscriptionFailed() {
        let message = "Test error message"
        let error = ParakeetEngine.EngineError.transcriptionFailed(message)
        #expect(error.errorDescription != nil, "Error should have description")
        #expect(error.errorDescription?.contains(message) ?? false,
                "Error description should contain the failure message")
    }

    @Test func errorDescriptionForDownloadFailed() {
        let message = "Download error"
        let error = ParakeetEngine.EngineError.downloadFailed(message)
        #expect(error.errorDescription != nil, "Error should have description")
        #expect(error.errorDescription?.contains(message) ?? false,
                "Error description should contain the failure message")
    }

    @Test func errorDescriptionForInitializationFailed() {
        let message = "Init error"
        let error = ParakeetEngine.EngineError.initializationFailed(message)
        #expect(error.errorDescription != nil, "Error should have description")
        #expect(error.errorDescription?.contains(message) ?? false,
                "Error description should contain the failure message")
    }

    @Test func v3ModelVersionSelection() async throws {
        let engine = makeEngine()
        #expect(engine.state == .unloaded)

        Task {
            do {
                try await engine.loadModel(modelName: "parakeet-tdt-0.6b-v3")
            } catch {
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(engine.state != .unloaded, "State should transition when loading v3 model")
    }

    // MARK: - Short clip padding

    @Test func shortClipsArePaddedToFluidAudioMinimum() {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: ASRConstants.sampleRate)
        let tap = [Float](repeating: 0.5, count: 1_000)

        let padded = ParakeetEngine.paddedForMinimumDuration(tap)

        #expect(padded.count == minimum)
        #expect(Array(padded.prefix(1_000)) == tap)
        #expect(padded.dropFirst(1_000).allSatisfy { $0 == 0 })
    }

    @Test func clipsAtOrAboveMinimumAreUnchanged() {
        let samples = [Float](repeating: 0.25, count: 16_000)
        #expect(ParakeetEngine.paddedForMinimumDuration(samples) == samples)
    }

    // MARK: - Model location

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-parakeet-unit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeCompleteV2ModelSet(at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for fileName in ModelNames.ASR.requiredModels {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent(fileName, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("{}".utf8).write(to: directory.appendingPathComponent(ModelNames.ASR.vocabularyFile))
    }

    @Test func appModelDirectoryMatchesFluidAudioRepoLayout() {
        let base = URL(fileURLWithPath: "/tmp/pindrop-base", isDirectory: true)

        let directory = ParakeetEngine.appModelDirectory(downloadBase: base, version: .v2)

        #expect(directory.lastPathComponent == AsrModels.defaultCacheDirectory(for: .v2).lastPathComponent)
        #expect(directory.deletingLastPathComponent().path == base.path + "/FluidInference/parakeet-coreml")
    }

    @Test func resolverPrefersAppDownloadFolder() {
        let base = URL(fileURLWithPath: "/tmp/pindrop-base", isDirectory: true)
        let cache = URL(fileURLWithPath: "/tmp/fluid-cache/parakeet-tdt-0.6b-v2", isDirectory: true)

        let resolved = ParakeetEngine.resolveModelDirectory(
            version: .v2,
            downloadBase: base,
            fluidAudioCacheDirectory: cache,
            modelsExist: { _, _ in true }
        )

        #expect(resolved == ParakeetEngine.appModelDirectory(downloadBase: base, version: .v2))
    }

    @Test func resolverFallsBackToFluidAudioCache() {
        let base = URL(fileURLWithPath: "/tmp/pindrop-base", isDirectory: true)
        let cache = URL(fileURLWithPath: "/tmp/fluid-cache/parakeet-tdt-0.6b-v2", isDirectory: true)

        let resolved = ParakeetEngine.resolveModelDirectory(
            version: .v2,
            downloadBase: base,
            fluidAudioCacheDirectory: cache,
            modelsExist: { url, _ in url == cache }
        )

        #expect(resolved == cache)
    }

    @Test func resolverReturnsNilWithoutCompleteModels() {
        let resolved = ParakeetEngine.resolveModelDirectory(
            version: .v2,
            downloadBase: URL(fileURLWithPath: "/tmp/pindrop-base", isDirectory: true),
            fluidAudioCacheDirectory: URL(fileURLWithPath: "/tmp/fluid-cache/parakeet-tdt-0.6b-v2"),
            modelsExist: { _, _ in false }
        )

        #expect(resolved == nil)
    }

    // Exercises FluidAudio's real completeness check against the folder shapes the
    // app downloads into, so a path-layout mismatch can't silently regress.
    @Test func resolverFindsCompleteModelsOnDiskAndRejectsPartialOnes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("app", isDirectory: true)
        let cache = root.appendingPathComponent("fluid/parakeet-tdt-0.6b-v2", isDirectory: true)

        #expect(ParakeetEngine.resolveModelDirectory(version: .v2, downloadBase: base, fluidAudioCacheDirectory: cache) == nil)

        // A partial cache (no vocabulary) is not a usable model set.
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent(ModelNames.ASR.encoderFile, isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(ParakeetEngine.resolveModelDirectory(version: .v2, downloadBase: base, fluidAudioCacheDirectory: cache) == nil)

        try writeCompleteV2ModelSet(at: cache)
        #expect(ParakeetEngine.resolveModelDirectory(version: .v2, downloadBase: base, fluidAudioCacheDirectory: cache) == cache)

        let appDirectory = ParakeetEngine.appModelDirectory(downloadBase: base, version: .v2)
        try writeCompleteV2ModelSet(at: appDirectory)
        #expect(ParakeetEngine.resolveModelDirectory(version: .v2, downloadBase: base, fluidAudioCacheDirectory: cache) == appDirectory)
    }

    @Test func modelVersionIsParsedFromCatalogName() {
        #expect(ParakeetEngine.modelVersion(forModelName: "parakeet-tdt-0.6b-v2") == .v2)
        #expect(ParakeetEngine.modelVersion(forModelName: "parakeet-tdt-0.6b-v3") == .v3)
        #expect(ParakeetEngine.modelVersion(forModelName: "parakeet-tdt-1.1b") == nil)
    }

    // MARK: - Word timings

    @Test func tokensJoinIntoTimedWords() {
        let tokens = [
            TokenTiming(token: " Hel", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 0.9),
            TokenTiming(token: "lo", tokenId: 2, startTime: 0.2, endTime: 0.4, confidence: 0.7),
            TokenTiming(token: ",", tokenId: 3, startTime: 0.4, endTime: 0.5, confidence: 0.8),
            TokenTiming(token: " world", tokenId: 4, startTime: 0.9, endTime: 1.3, confidence: 1.0),
        ]

        let words = ParakeetEngine.words(from: tokens)

        #expect(words.map(\.text) == ["Hello,", "world"])
        #expect(words[0].startTime == 0.0)
        #expect(words[0].endTime == 0.5)
        #expect(words[1].startTime == 0.9)
        #expect(words[1].endTime == 1.3)
        #expect(abs(words[0].confidence - 0.8) < 0.0001)
    }

    @Test func missingTokenTimingsSpreadWordsEvenly() {
        let words = ParakeetEngine.evenlyTimedWords(text: "one two", duration: 2)
        #expect(words.map(\.text) == ["one", "two"])
        #expect(words[1].startTime == 1)
        #expect(words[1].endTime == 2)
    }
}
