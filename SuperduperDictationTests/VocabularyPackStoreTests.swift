//
//  VocabularyPackStoreTests.swift
//  SuperduperDictationTests
//
//  Created on 2026-09-23.
//

import Foundation
import Testing
@testable import SuperduperDictation

@MainActor
@Suite
struct VocabularyPackStoreTests {
    private func makeStore() throws -> (sut: VocabularyPackStore, directory: URL, defaults: UserDefaults) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VocabularyPackStoreTests-\(UUID().uuidString)", isDirectory: true)
        let suiteName = "VocabularyPackStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (VocabularyPackStore(directoryURL: directory, defaults: defaults), directory, defaults)
    }

    private func makePack(id: String = "team", terms: [VocabularyPackTerm]) -> VocabularyPack {
        VocabularyPack(id: id, name: "Team", summary: "Team words", terms: terms)
    }

    @Test func decodesJSONPacksWithOptionalFields() throws {
        let json = #"{"name": "Work Stuff", "terms": [{"text": "Teensy", "soundsLike": ["TNC"]}, {"text": "LiveKit"}]}"#

        let pack = try VocabularyPackStore.decodePack(from: Data(json.utf8), fallbackName: "file")

        #expect(pack.id == "work-stuff")
        #expect(pack.name == "Work Stuff")
        #expect(pack.terms == [VocabularyPackTerm("Teensy", soundsLike: ["TNC"]), VocabularyPackTerm("LiveKit")])
    }

    @Test func decodesTheOneTermPerLineTextFormat() throws {
        let text = """
        # name: Hardware
        # summary: Synth terms
        Teensy | TNC, T N C

        Arduino
        """

        let pack = try VocabularyPackStore.decodePack(from: Data(text.utf8), fallbackName: "hardware-terms")

        #expect(pack.id == "hardware")
        #expect(pack.summary == "Synth terms")
        #expect(pack.terms == [VocabularyPackTerm("Teensy", soundsLike: ["TNC", "T N C"]), VocabularyPackTerm("Arduino")])
    }

    @Test func rejectsEmptyPacksAndWebPages() {
        #expect(throws: VocabularyPackError.empty) {
            try VocabularyPackStore.decodePack(from: Data("# name: Nothing\n".utf8), fallbackName: "x")
        }
        #expect(throws: VocabularyPackError.self) {
            try VocabularyPackStore.decodePack(from: Data("<!DOCTYPE html><html></html>".utf8), fallbackName: "x")
        }
    }

    @Test func starterPacksAreAvailableButOffUntilEnabledOnThisMac() throws {
        let (sut, directory, defaults) = try makeStore()

        #expect(sut.packs.map(\.id) == ["voice-ai", "livekit", "hardware"])
        #expect(sut.enabledPacks.isEmpty)
        #expect(sut.activeVocabulary().terms.isEmpty)

        sut.setEnabled(true, packID: "hardware")

        #expect(defaults.stringArray(forKey: VocabularyPackStore.enabledPackIDsDefaultsKey) == ["hardware"])
        let reloaded = VocabularyPackStore(directoryURL: directory, defaults: defaults)
        #expect(reloaded.enabledPacks.map(\.id) == ["hardware"])
        #expect(reloaded.activeVocabulary().soundsLike["Teensy"]?.contains("TNC") == true)
    }

    @Test func importedPacksAreSavedEnabledAndDeletable() throws {
        let (sut, directory, _) = try makeStore()
        let file = directory.deletingLastPathComponent().appendingPathComponent("team-\(UUID().uuidString).txt")
        try "# name: Team\nRuss D'Sa | Russ Desa\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }

        let pack = try sut.importPack(from: file)

        #expect(sut.packs.contains { $0.id == "team" })
        #expect(!sut.isBuiltIn(pack))
        #expect(sut.activeVocabulary().terms == ["Russ D'Sa"])
        #expect(sut.activeVocabulary().soundsLike == ["Russ D'Sa": ["Russ Desa"]])

        try sut.delete(pack)

        #expect(!sut.packs.contains { $0.id == "team" })
        #expect(sut.enabledPackIDs.isEmpty)
        #expect(throws: VocabularyPackError.cannotDeleteStarterPack) {
            try sut.delete(VocabularyPackStore.hardwarePack)
        }
    }

    @Test func aSavedPackWithAStarterIDReplacesTheStarterPack() throws {
        let (sut, _, _) = try makeStore()
        let custom = makePack(id: "hardware", terms: [VocabularyPackTerm("Daisy Seed")])

        try sut.save(custom)

        #expect(sut.packs.filter { $0.id == "hardware" } == [custom])
        #expect(!sut.isBuiltIn(custom))
        #expect(sut.activeVocabulary().terms == ["Daisy Seed"])
    }

    @Test func activeVocabularyMergesPacksWithoutDuplicates() throws {
        let (sut, _, _) = try makeStore()
        try sut.save(makePack(id: "one", terms: [VocabularyPackTerm("LiveKit", soundsLike: ["live kid"])]))
        try sut.save(makePack(id: "two", terms: [VocabularyPackTerm("livekit"), VocabularyPackTerm("Teensy")]))

        let vocabulary = sut.activeVocabulary()

        #expect(vocabulary.terms == ["LiveKit", "Teensy"])
        #expect(vocabulary.soundsLike == ["LiveKit": ["live kid"]])
    }

    @Test func exportedPacksImportBackUnchanged() throws {
        let (sut, directory, _) = try makeStore()
        let pack = makePack(terms: [VocabularyPackTerm("Teensy", soundsLike: ["TNC"])])
        let file = directory.deletingLastPathComponent().appendingPathComponent("export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        try sut.export(pack, to: file)

        #expect(try VocabularyPackStore.decodePack(from: Data(contentsOf: file), fallbackName: "x") == pack)
    }

    // MARK: - Building packs from docs

    private let docs = """
    # LiveKit docs

    > LiveKit is an open-source platform built on WebRTC. Run the SFU yourself or on LiveKit Cloud.

    - [Agents](https://docs.livekit.io/agents/llms.txt): Build agents with AgentSession and the Cartesia or Deepgram plugins.
    - [Hardware](https://docs.livekit.io/hardware/llms.txt): ESP32 support. Cartesia and Deepgram again.
    - Use `session.say()` or call useChatToggle once. See https://example.com/deepgram_docs.
    The API and SDK and JSON are everywhere. AgentControlBarButton appears once. Frobnicate appears once.
    """

    private let everyday: Set<String> = [
        "is", "an", "open-source", "platform", "built", "on", "run", "the", "yourself", "or", "cloud",
        "build", "agents", "with", "and", "plugins", "hardware", "support", "again", "use", "call",
        "once", "see", "are", "everywhere", "appears", "docs",
    ]

    @Test func docsYieldNamesAcronymsAndRepeatedNonWords() {
        let candidates = VocabularyPackExtractor.candidates(in: docs, isWord: { everyday.contains($0.lowercased()) })
        let terms = candidates.map(\.term)

        #expect(terms.first == "LiveKit")
        #expect(Set(["WebRTC", "SFU", "AgentSession", "ESP32", "Cartesia", "Deepgram"]).isSubset(of: Set(terms)))
        // Common acronyms, code, URLs, one-off long identifiers, and one-off non-words are skipped.
        #expect(terms.allSatisfy { !["API", "SDK", "JSON", "say", "useChatToggle", "AgentControlBarButton", "Frobnicate"].contains($0) })
        #expect(!terms.contains { $0.contains("_") || $0.contains("docs") })
    }

    @Test func docsTitleAndLinkedIndexesAreFound() throws {
        let base = try #require(URL(string: "https://docs.livekit.io/llms.txt"))

        #expect(VocabularyPackExtractor.title(in: docs) == "LiveKit docs")
        #expect(VocabularyPackExtractor.linkedIndexURLs(in: docs, base: base).map(\.absoluteString) == [
            "https://docs.livekit.io/agents/llms.txt",
            "https://docs.livekit.io/hardware/llms.txt",
        ])
    }
}
