//
//  LocalMeetingModelServiceTests.swift
//  PindropTests
//
//  Created on 2026-08-25.
//

import Foundation
import Testing
@testable import Pindrop

@Suite
struct LocalMeetingModelServiceTests {
    @Test func generatorRetriesInvalidJSONAndGroundsOwnerAndDueDate() async throws {
        let inference = MeetingInferenceMock(outputs: [
            "not json",
            #"{"summary":"A summary","decisions":["Ship Friday"],"action_items":[{"text":"Send draft","owner":"Alice","due_date":"Friday"},{"text":"Invented","owner":"Bob","due_date":"Tuesday"}]}"#
        ])
        let sut = MeetingInsightGenerator(inference: inference)
        let result = try await sut.generate(
            from: "Alice will Send draft by Friday. The team decided: Ship Friday."
        )

        #expect(inference.prompts.count == 2)
        #expect(inference.prompts[0].contains("Do not infer"))
        #expect(result.summaryMarkdown == "A summary")
        #expect(result.actionItems[0].owner == "Alice")
        #expect(result.actionItems[0].dueDate == "Friday")
        #expect(result.actionItems[1].owner == nil)
        #expect(result.actionItems[1].dueDate == nil)
    }

    @Test func longTranscriptUsesChunkedMapReduce() async throws {
        let valid = #"{"summary":"Grounded","decisions":[],"action_items":[]}"#
        let inference = MeetingInferenceMock(outputs: Array(repeating: valid, count: 8))
        let sut = MeetingInsightGenerator(inference: inference, maximumChunkCharacters: 1_000)
        let transcript = Array(repeating: "A concrete meeting sentence.", count: 120).joined(separator: " ")

        _ = try await sut.generate(from: transcript)

        #expect(inference.prompts.count > 2)
        #expect(inference.prompts.last?.contains("CHUNK NOTES:") == true)
    }

    @Test func pinnedModelIdentityAndLicenseSizedDownloadAreStable() {
        #expect(LocalMeetingModelService.repositoryID == "Qwen/Qwen3-4B-MLX-4bit")
        #expect(LocalMeetingModelService.pinnedRevision == "52a5ab34fa604bc8af6d3ce0cac0cab10b7eb495")
        #expect(LocalMeetingModelService.approximateDownloadBytes == 2_150_000_000)
    }

    @Test func missingMarkerIsDiagnosedWithoutStartingNetworkWork() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-model-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sut = LocalMeetingModelService(
            rootURL: root,
            diskSpaceProvider: FixedMeetingDiskSpaceProvider(bytes: Int64.max)
        )

        #expect(await sut.readiness() == .missing)
    }

    @Test func insufficientDiskFailsBeforeTheDownloaderIsCreated() async throws {
        guard LocalMeetingModelService.isAppleSilicon else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-model-disk-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sut = LocalMeetingModelService(
            rootURL: root,
            diskSpaceProvider: FixedMeetingDiskSpaceProvider(bytes: 100)
        )

        do {
            _ = try await sut.download()
            Issue.record("Expected insufficient disk-space failure")
        } catch LocalMeetingModelError.insufficientDisk(let required, let available) {
            #expect(required == LocalMeetingModelService.requiredAvailableDiskBytes)
            #expect(available == 100)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private struct FixedMeetingDiskSpaceProvider: MeetingDiskSpaceProviding {
    let bytes: Int64
    func availableBytes(at url: URL) throws -> Int64 { bytes }
}

private final class MeetingInferenceMock: LocalMeetingModelInferencing, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [String]
    private(set) var prompts: [String] = []

    init(outputs: [String]) { self.outputs = outputs }

    func generate(prompt: String) async throws -> String {
        lock.withLock {
            prompts.append(prompt)
            return outputs.isEmpty
                ? #"{"summary":"Grounded","decisions":[],"action_items":[]}"#
                : outputs.removeFirst()
        }
    }
}
