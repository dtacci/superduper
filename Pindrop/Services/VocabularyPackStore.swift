//
//  VocabularyPackStore.swift
//  Pindrop
//
//  Created on 2026-09-23.
//

import Foundation
import Observation

/// A term to recognize, plus spellings speech recognition tends to produce for it
/// ("Teensy" is often heard as "TNC").
struct VocabularyPackTerm: Codable, Equatable, Hashable, Sendable {
    var text: String
    var soundsLike: [String]

    init(_ text: String, soundsLike: [String] = []) {
        self.text = text
        self.soundsLike = soundsLike
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        soundsLike = try container.decodeIfPresent([String].self, forKey: .soundsLike) ?? []
    }
}

/// A named, portable glossary. Packs are enabled per Mac, so a work laptop can use
/// a company glossary that a personal laptop doesn't need.
struct VocabularyPack: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var summary: String
    var terms: [VocabularyPackTerm]

    init(id: String, name: String, summary: String = "", terms: [VocabularyPackTerm]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.terms = terms
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? VocabularyPack.slug(for: name)
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        terms = try container.decode([VocabularyPackTerm].self, forKey: .terms)
    }

    static func slug(for name: String) -> String {
        let slug = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? UUID().uuidString.lowercased() : slug
    }
}

enum VocabularyPackError: Error, LocalizedError, Equatable {
    case unreadable(String)
    case empty
    case cannotDeleteStarterPack

    var errorDescription: String? {
        switch self {
        case .unreadable(let detail):
            return "This file isn't a vocabulary pack: \(detail)"
        case .empty:
            return "This vocabulary pack has no terms."
        case .cannotDeleteStarterPack:
            return "Built-in packs can't be deleted; turn them off instead."
        }
    }
}

/// Built-in packs, user packs (JSON files in Application Support), and which ones
/// are enabled on this Mac.
@MainActor
@Observable
final class VocabularyPackStore {
    nonisolated static let enabledPackIDsDefaultsKey = "enabledVocabularyPackIDs"

    private(set) var packs: [VocabularyPack] = []
    private(set) var enabledPackIDs: Set<String>

    @ObservationIgnored private let directoryURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fileManager: FileManager

    init(
        directoryURL: URL = VocabularyPackStore.defaultDirectoryURL,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.defaults = defaults
        self.fileManager = fileManager
        self.enabledPackIDs = Set(defaults.stringArray(forKey: Self.enabledPackIDsDefaultsKey) ?? [])
        reload()
    }

    nonisolated static var defaultDirectoryURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("Superduper Dictation", isDirectory: true)
            .appendingPathComponent("VocabularyPacks", isDirectory: true)
    }

    var enabledPacks: [VocabularyPack] {
        packs.filter { enabledPackIDs.contains($0.id) }
    }

    /// Built-in packs that haven't been replaced by an imported pack with the same id.
    func isBuiltIn(_ pack: VocabularyPack) -> Bool {
        Self.starterPacks.contains { $0.id == pack.id } && !fileManager.fileExists(atPath: userPackURL(for: pack.id).path)
    }

    /// Built-in packs first; a user pack with the same id replaces the built-in one.
    func reload() {
        let userPacks = loadUserPacks()
        let userIDs = Set(userPacks.map(\.id))
        packs = Self.starterPacks.filter { !userIDs.contains($0.id) } + userPacks.sorted { $0.name < $1.name }
    }

    func setEnabled(_ enabled: Bool, packID: String) {
        if enabled {
            enabledPackIDs.insert(packID)
        } else {
            enabledPackIDs.remove(packID)
        }
        defaults.set(enabledPackIDs.sorted(), forKey: Self.enabledPackIDsDefaultsKey)
    }

    /// Imports a pack file (JSON, or the one-term-per-line text format) and enables it.
    @discardableResult
    func importPack(from fileURL: URL) throws -> VocabularyPack {
        let data = try Data(contentsOf: fileURL)
        let pack = try Self.decodePack(
            from: data,
            fallbackName: fileURL.deletingPathExtension().lastPathComponent
        )
        try save(pack)
        return pack
    }

    /// Downloads a pack from a URL (for example a raw file in a shared repo).
    @discardableResult
    func importPack(fromRemote url: URL, session: URLSession = .shared) async throws -> VocabularyPack {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw VocabularyPackError.unreadable("the server returned HTTP \(http.statusCode)")
        }
        let pack = try Self.decodePack(from: data, fallbackName: url.deletingPathExtension().lastPathComponent)
        try save(pack)
        return pack
    }

    func save(_ pack: VocabularyPack) throws {
        guard !pack.terms.isEmpty else { throw VocabularyPackError.empty }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pack).write(to: userPackURL(for: pack.id), options: .atomic)
        reload()
        setEnabled(true, packID: pack.id)
    }

    func export(_ pack: VocabularyPack, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pack).write(to: url, options: .atomic)
    }

    func delete(_ pack: VocabularyPack) throws {
        let url = userPackURL(for: pack.id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw VocabularyPackError.cannotDeleteStarterPack
        }
        try fileManager.removeItem(at: url)
        if !Self.starterPacks.contains(where: { $0.id == pack.id }) {
            setEnabled(false, packID: pack.id)
        }
        reload()
    }

    /// Terms and "sounds like" spellings from every enabled pack.
    func activeVocabulary() -> (terms: [String], soundsLike: [String: [String]]) {
        var terms: [String] = []
        var soundsLike: [String: [String]] = [:]
        var seen = Set<String>()
        for term in enabledPacks.flatMap(\.terms) {
            let text = term.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if seen.insert(text.lowercased()).inserted {
                terms.append(text)
            }
            if !term.soundsLike.isEmpty {
                soundsLike[text, default: []].append(contentsOf: term.soundsLike)
            }
        }
        return (terms, soundsLike)
    }

    // MARK: - Files

    private func userPackURL(for id: String) -> URL {
        directoryURL.appendingPathComponent("\(VocabularyPack.slug(for: id)).json")
    }

    private func loadUserPacks() -> [VocabularyPack] {
        guard let urls = try? fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            return []
        }
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                do {
                    return try JSONDecoder().decode(VocabularyPack.self, from: Data(contentsOf: url))
                } catch {
                    Log.app.warning("Skipping unreadable vocabulary pack \(url.lastPathComponent): \(error.localizedDescription)")
                    return nil
                }
            }
    }

    /// Accepts the JSON pack format, or plain text with one term per line:
    ///
    ///     # name: Hardware
    ///     # summary: Synth and microcontroller terms
    ///     Teensy | TNC, T N C
    ///     Arduino
    nonisolated static func decodePack(from data: Data, fallbackName: String) throws -> VocabularyPack {
        if let pack = try? JSONDecoder().decode(VocabularyPack.self, from: data) {
            guard !pack.terms.isEmpty else { throw VocabularyPackError.empty }
            return pack
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VocabularyPackError.unreadable("it isn't UTF-8 text")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") {
            throw VocabularyPackError.unreadable("the JSON is missing \"name\" or \"terms\"")
        }
        if trimmed.hasPrefix("<") {
            throw VocabularyPackError.unreadable("it's a web page, not a pack file")
        }

        var name = fallbackName
        var summary = ""
        var terms: [VocabularyPackTerm] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let header = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if header.lowercased().hasPrefix("name:") {
                    name = String(header.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                } else if header.lowercased().hasPrefix("summary:") {
                    summary = String(header.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            let parts = line.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let term = parts.first, !term.isEmpty else { continue }
            let soundsLike = parts.count > 1
                ? parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            terms.append(VocabularyPackTerm(term, soundsLike: soundsLike))
        }
        guard !terms.isEmpty else { throw VocabularyPackError.empty }
        return VocabularyPack(id: VocabularyPack.slug(for: name), name: name, summary: summary, terms: terms)
    }
}

// MARK: - Starter packs

extension VocabularyPackStore {
    nonisolated static let starterPacks: [VocabularyPack] = [voiceAIPack, liveKitPack, hardwarePack]

    nonisolated static let voiceAIPack = VocabularyPack(
        id: "voice-ai",
        name: "Voice AI",
        summary: "Speech and realtime AI concepts, protocols, and vendors",
        terms: [
            VocabularyPackTerm("STT"), VocabularyPackTerm("TTS"), VocabularyPackTerm("ASR"),
            VocabularyPackTerm("VAD"), VocabularyPackTerm("LLM"), VocabularyPackTerm("RAG"),
            VocabularyPackTerm("WebRTC", soundsLike: ["web RTC", "web rtc"]), VocabularyPackTerm("SIP"),
            VocabularyPackTerm("PSTN"), VocabularyPackTerm("DTMF"), VocabularyPackTerm("RTP"),
            VocabularyPackTerm("Opus"), VocabularyPackTerm("barge-in"), VocabularyPackTerm("endpointing"),
            VocabularyPackTerm("turn detection"), VocabularyPackTerm("diarization"),
            VocabularyPackTerm("TTFT"), VocabularyPackTerm("TTFB"),
            VocabularyPackTerm("speech-to-speech"), VocabularyPackTerm("function calling"),
            VocabularyPackTerm("tool calling"), VocabularyPackTerm("MCP"), VocabularyPackTerm("SSML"),
            VocabularyPackTerm("prosody"), VocabularyPackTerm("phoneme"), VocabularyPackTerm("voice cloning"),
            VocabularyPackTerm("echo cancellation"), VocabularyPackTerm("noise suppression"),
            VocabularyPackTerm("Deepgram", soundsLike: ["deep gram"]), VocabularyPackTerm("AssemblyAI", soundsLike: ["assembly AI"]),
            VocabularyPackTerm("Cartesia"), VocabularyPackTerm("ElevenLabs", soundsLike: ["11 Labs", "eleven labs"]),
            VocabularyPackTerm("Speechmatics"), VocabularyPackTerm("Gladia"), VocabularyPackTerm("LMNT"),
            VocabularyPackTerm("Inworld"), VocabularyPackTerm("Neuphonic"), VocabularyPackTerm("Silero"),
            VocabularyPackTerm("Parakeet"), VocabularyPackTerm("Twilio"), VocabularyPackTerm("Telnyx"),
            VocabularyPackTerm("OpenAI Realtime"), VocabularyPackTerm("Gemini Live"), VocabularyPackTerm("Nova Sonic"),
            VocabularyPackTerm("Cerebras"), VocabularyPackTerm("Ollama"),
        ]
    )

    nonisolated static let liveKitPack = VocabularyPack(
        id: "livekit",
        name: "LiveKit",
        summary: "LiveKit platform, Agents framework, and APIs",
        terms: [
            VocabularyPackTerm("LiveKit", soundsLike: ["live kit", "Live Kid"]),
            VocabularyPackTerm("LiveKit Cloud"), VocabularyPackTerm("LiveKit Agents"),
            VocabularyPackTerm("LiveKit Inference"), VocabularyPackTerm("LiveKit CLI"),
            VocabularyPackTerm("Agents framework"), VocabularyPackTerm("AgentSession", soundsLike: ["agent session"]),
            VocabularyPackTerm("Agent Builder"), VocabularyPackTerm("Agent Console"),
            VocabularyPackTerm("agent dispatch"), VocabularyPackTerm("JobContext", soundsLike: ["job context"]),
            VocabularyPackTerm("WorkerOptions", soundsLike: ["worker options"]),
            VocabularyPackTerm("RoomInputOptions", soundsLike: ["room input options"]),
            VocabularyPackTerm("ChatContext", soundsLike: ["chat context"]), VocabularyPackTerm("function tools"),
            VocabularyPackTerm("handoffs"), VocabularyPackTerm("turn detector"),
            VocabularyPackTerm("adaptive interruption"), VocabularyPackTerm("background audio"),
            VocabularyPackTerm("BVC", soundsLike: ["B V C"]), VocabularyPackTerm("noise cancellation"),
            VocabularyPackTerm("SFU", soundsLike: ["S F U"]), VocabularyPackTerm("Egress"),
            VocabularyPackTerm("Ingress"), VocabularyPackTerm("SIP trunk"), VocabularyPackTerm("dispatch rule"),
            VocabularyPackTerm("Simulcast"), VocabularyPackTerm("Dynacast", soundsLike: ["dyna cast"]),
            VocabularyPackTerm("data channel"), VocabularyPackTerm("RPC"), VocabularyPackTerm("track publication"),
            VocabularyPackTerm("LocalParticipant"), VocabularyPackTerm("RemoteParticipant"),
            VocabularyPackTerm("Agents UI"), VocabularyPackTerm("Agent Embed"), VocabularyPackTerm("Beyond Presence"),
            VocabularyPackTerm("bitHuman"), VocabularyPackTerm("Tavus"),
        ]
    )

    nonisolated static let hardwarePack = VocabularyPack(
        id: "hardware",
        name: "Hardware & synths",
        summary: "Microcontrollers, audio hardware, and synth terms",
        terms: [
            VocabularyPackTerm("Teensy", soundsLike: ["TNC", "T N C", "teensie", "tinsy"]),
            VocabularyPackTerm("Teensy Audio Library"), VocabularyPackTerm("Audio Shield"),
            VocabularyPackTerm("PJRC"), VocabularyPackTerm("Arduino"), VocabularyPackTerm("ESP32", soundsLike: ["ESP 32"]),
            VocabularyPackTerm("ESP-IDF"), VocabularyPackTerm("PlatformIO", soundsLike: ["platform IO"]),
            VocabularyPackTerm("Raspberry Pi"), VocabularyPackTerm("I2S", soundsLike: ["I squared S", "I 2 S"]),
            VocabularyPackTerm("I2C", soundsLike: ["I squared C", "I 2 C"]), VocabularyPackTerm("SPI"),
            VocabularyPackTerm("UART"), VocabularyPackTerm("GPIO"), VocabularyPackTerm("PWM"),
            VocabularyPackTerm("ADC"), VocabularyPackTerm("DAC"), VocabularyPackTerm("MIDI"),
            VocabularyPackTerm("USB MIDI"), VocabularyPackTerm("CV/Gate", soundsLike: ["CV gate"]),
            VocabularyPackTerm("Eurorack"), VocabularyPackTerm("ADSR"), VocabularyPackTerm("LFO"),
            VocabularyPackTerm("VCO"), VocabularyPackTerm("VCF"), VocabularyPackTerm("VCA"),
            VocabularyPackTerm("oscillator"), VocabularyPackTerm("wavetable"), VocabularyPackTerm("sample rate"),
            VocabularyPackTerm("SGTL5000"), VocabularyPackTerm("PAM8302"), VocabularyPackTerm("MAX98357A"),
            VocabularyPackTerm("INMP441"), VocabularyPackTerm("SSD1306"), VocabularyPackTerm("KiCad", soundsLike: ["key cad"]),
            VocabularyPackTerm("PCB"), VocabularyPackTerm("LiPo", soundsLike: ["lipo"]), VocabularyPackTerm("piezo"),
            VocabularyPackTerm("potentiometer"), VocabularyPackTerm("rotary encoder"),
        ]
    )
}
