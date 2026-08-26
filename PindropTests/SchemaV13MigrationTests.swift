//
//  SchemaV13MigrationTests.swift
//  PindropTests
//
//  Created on 2026-08-25.
//

import Foundation
import SwiftData
import Testing
@testable import Pindrop

@MainActor
@Suite(.serialized)
struct SchemaV13MigrationTests {
    @Test func v12StoreMigratesAndMeetingTablesAreWritable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-v13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storeURL = root.appendingPathComponent("migration.store")

        do {
            let schema = Schema(versionedSchema: TranscriptionRecordSchemaV12.self)
            let container = try ModelContainer(
                for: schema,
                configurations: ModelConfiguration(schema: schema, url: storeURL)
            )
            let context = ModelContext(container)
            context.insert(
                TranscriptionRecordSchemaV12.TranscriptionRecord(
                    text: "Before meetings",
                    duration: 1,
                    modelUsed: "test"
                )
            )
            try context.save()
        }

        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            migrationPlan: TranscriptionRecordMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: storeURL)
        )
        let context = ModelContext(container)
        #expect(try context.fetch(FetchDescriptor<TranscriptionRecord>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<MeetingOccurrence>()).isEmpty)

        let media = TestMeetingMediaLibrary(root: root.appendingPathComponent("media", isDirectory: true))
        let store = MeetingStore(modelContext: context, mediaLibrary: media)
        let occurrence = try store.createManualOccurrence(title: "Design review", expectedSpeakerCount: 3)
        #expect(occurrence.series?.displayName == "Design review")
        #expect(occurrence.series?.occurrences.map(\.id) == [occurrence.id])
        #expect(occurrence.workspaceURL.lastPathComponent == occurrence.id.uuidString)
    }

    @Test func interruptedRecordingBecomesRetryableAndRetainsAudio() throws {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pindrop-recovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingStore(
            modelContext: context,
            mediaLibrary: TestMeetingMediaLibrary(root: root)
        )
        let occurrence = try store.createManualOccurrence(title: "Recovery")
        try store.transition(id: occurrence.id, to: .recording)
        let spool = occurrence.workspaceURL.appendingPathComponent("capture-mixed.pcm")
        try Data([1, 2, 3, 4]).write(to: spool)

        let recovered = try store.recoverInterruptedOccurrences()
        let recoveredOccurrence = try store.occurrence(id: occurrence.id)
        let fetched = try #require(recoveredOccurrence)

        #expect(recovered.map(\.id) == [occurrence.id])
        #expect(fetched.state == .failed)
        #expect(fetched.canRetryProcessing)
        #expect(
            fetched.recoveryAudioURLs.map { $0.resolvingSymlinksInPath() }
                == [spool.resolvingSymlinksInPath()]
        )
        #expect(FileManager.default.fileExists(atPath: spool.path))
    }
}

private final class TestMeetingMediaLibrary: MediaLibraryManaging {
    private let root: URL
    init(root: URL) { self.root = root }

    func makeJobDirectory(for jobID: UUID) throws -> URL {
        let url = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset {
        fatalError("Unused by MeetingStore tests")
    }
    func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset { fatalError("Unused by MeetingStore tests") }
    func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset { fatalError("Unused by MeetingStore tests") }
}
