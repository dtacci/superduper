//
//  LocalMeetingModelService.swift
//  Pindrop
//
//  Created on 2026-08-25.
//

import Foundation
import Hub
import MLXLLM
import MLXLMCommon

enum LocalMeetingModelReadiness: Equatable, Sendable {
    case unsupportedArchitecture
    case missing
    case incomplete(String)
    case ready(URL)
}

enum LocalMeetingModelError: Error, LocalizedError {
    case unsupportedArchitecture
    case insufficientDisk(requiredBytes: Int64, availableBytes: Int64)
    case insufficientMemory(requiredBytes: UInt64, availableBytes: UInt64)
    case missingWeights
    case invalidWeights(String)
    case invalidModelOutput(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "On-device meeting insights require an Apple Silicon Mac."
        case .insufficientDisk(let required, let available):
            return "The meeting-notes model needs \(required / 1_000_000_000) GB free; \(available / 1_000_000_000) GB is available."
        case .insufficientMemory(let required, let available):
            return "On-device meeting insights need at least \(required / 1_000_000_000) GB RAM; this Mac has \(available / 1_000_000_000) GB."
        case .missingWeights:
            return "Download the on-device meeting-notes model first."
        case .invalidWeights(let detail):
            return "The on-device meeting-notes model is incomplete: \(detail)"
        case .invalidModelOutput(let detail):
            return "The on-device model returned invalid meeting notes: \(detail)"
        }
    }
}

protocol LocalMeetingModelInferencing: Sendable {
    func generate(prompt: String) async throws -> String
}

/// Owns the only model download and inference route used for meeting insights.
/// Inference loads a local directory, so transcript generation cannot silently
/// fall through to any configured HTTP AI provider.
actor LocalMeetingModelService: LocalMeetingModelInferencing {
    static let repositoryID = "Qwen/Qwen3-4B-MLX-4bit"
    static let pinnedRevision = "52a5ab34fa604bc8af6d3ce0cac0cab10b7eb495"
    static let approximateDownloadBytes: Int64 = 2_150_000_000
    static let requiredAvailableDiskBytes: Int64 = 3_500_000_000
    static let requiredPhysicalMemoryBytes: UInt64 = 8_000_000_000

    private let rootURL: URL
    private let fileManager: FileManager
    private let diskSpaceProvider: any MeetingDiskSpaceProviding
    private var container: MLXLMCommon.ModelContainer?

    init(
        rootURL: URL = ModelManager.meetingNotesModelRootURL,
        fileManager: FileManager = .default,
        diskSpaceProvider: any MeetingDiskSpaceProviding = SystemMeetingDiskSpaceProvider()
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
        self.diskSpaceProvider = diskSpaceProvider
    }

    nonisolated static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    func readiness() -> LocalMeetingModelReadiness {
        guard Self.isAppleSilicon else { return .unsupportedArchitecture }
        guard let directory = resolvedModelDirectory() else { return .missing }
        do {
            try validateModelDirectory(directory)
            return .ready(directory)
        } catch {
            return .incomplete(error.localizedDescription)
        }
    }

    @discardableResult
    func download(onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        guard Self.isAppleSilicon else { throw LocalMeetingModelError.unsupportedArchitecture }
        if case .ready(let directory) = readiness() {
            onProgress(1)
            return directory
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let available = try diskSpaceProvider.availableBytes(at: rootURL)
        guard available >= Self.requiredAvailableDiskBytes else {
            throw LocalMeetingModelError.insufficientDisk(
                requiredBytes: Self.requiredAvailableDiskBytes,
                availableBytes: available
            )
        }
        let memory = ProcessInfo.processInfo.physicalMemory
        guard memory >= Self.requiredPhysicalMemoryBytes else {
            throw LocalMeetingModelError.insufficientMemory(
                requiredBytes: Self.requiredPhysicalMemoryBytes,
                availableBytes: memory
            )
        }

        let hub = HubApi(downloadBase: rootURL)
        let configuration = MLXLMCommon.ModelConfiguration(
            id: Self.repositoryID,
            revision: Self.pinnedRevision
        )
        let directory = try await downloadModel(
            hub: hub,
            configuration: configuration,
            progressHandler: { progress in onProgress(progress.fractionCompleted) }
        )
        try Task.checkCancellation()
        try validateModelDirectory(directory)
        try directory.path.write(
            to: markerURL,
            atomically: true,
            encoding: .utf8
        )
        onProgress(1)
        return directory
    }

    func removeWeightsForRepair() throws {
        container = nil
        guard fileManager.fileExists(atPath: rootURL.path) else { return }
        try fileManager.removeItem(at: rootURL)
    }

    func generate(prompt: String) async throws -> String {
        guard Self.isAppleSilicon else { throw LocalMeetingModelError.unsupportedArchitecture }
        let modelContainer: MLXLMCommon.ModelContainer
        if let container {
            modelContainer = container
        } else {
            guard case .ready(let directory) = readiness() else {
                throw LocalMeetingModelError.missingWeights
            }
            // Importing MLXLLM registers Qwen3's model factory. Loading from an
            // explicit local directory prevents network access during inference.
            modelContainer = try await MLXLMCommon.loadModelContainer(directory: directory)
            container = modelContainer
        }
        let session = ChatSession(
            modelContainer,
            instructions: "Return only strict JSON. Do not invent facts that are not present in the transcript.",
            generateParameters: GenerateParameters(
                maxTokens: 2_048,
                temperature: 0.1,
                topP: 0.9
            )
        )
        return try await session.respond(to: prompt)
    }

    private var markerURL: URL {
        rootURL.appendingPathComponent("resolved-model-path.txt")
    }

    private func resolvedModelDirectory() -> URL? {
        guard let path = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let rootPath = rootURL.standardizedFileURL.path + "/"
        guard directory.path.hasPrefix(rootPath) else { return nil }
        return directory
    }

    private func validateModelDirectory(_ directory: URL) throws {
        let required = ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"]
        let missing = required.filter {
            !fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        guard missing.isEmpty else {
            throw LocalMeetingModelError.invalidWeights("missing \(missing.joined(separator: ", "))")
        }
        let weightsURL = directory.appendingPathComponent("model.safetensors")
        let size = (try? weightsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size >= 2_000_000_000 else {
            throw LocalMeetingModelError.invalidWeights("model.safetensors is truncated")
        }
    }
}

// MARK: - Structured map/reduce insights

actor MeetingInsightGenerator {
    private struct WireInsights: Codable {
        struct WireActionItem: Codable {
            let text: String
            let owner: String?
            let dueDate: String?

            enum CodingKeys: String, CodingKey {
                case text
                case owner
                case dueDate = "due_date"
            }
        }

        let summary: String
        let decisions: [String]
        let actionItems: [WireActionItem]

        enum CodingKeys: String, CodingKey {
            case summary
            case decisions
            case actionItems = "action_items"
        }
    }

    private let inference: any LocalMeetingModelInferencing
    private let maximumChunkCharacters: Int

    init(
        inference: any LocalMeetingModelInferencing,
        maximumChunkCharacters: Int = 12_000
    ) {
        self.inference = inference
        self.maximumChunkCharacters = max(1_000, maximumChunkCharacters)
    }

    func generate(from transcript: String) async throws -> MeetingInsights {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalMeetingModelError.invalidModelOutput("the transcript is empty")
        }
        let chunks = Self.chunks(normalized, limit: maximumChunkCharacters)
        var mapped: [WireInsights] = []
        mapped.reserveCapacity(chunks.count)
        for (index, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            let prompt = """
            Extract grounded notes from transcript chunk \(index + 1) of \(chunks.count).
            Return exactly this JSON shape:
            {"summary":"...","decisions":["..."],"action_items":[{"text":"...","owner":null,"due_date":null}]}
            Include an owner or due_date only when explicitly stated. Do not infer them.

            TRANSCRIPT:
            \(chunk)
            """
            mapped.append(try await generateValidated(prompt: prompt))
        }

        let wire: WireInsights
        if mapped.count == 1 {
            wire = mapped[0]
        } else {
            let mappedJSON = try mapped.map {
                String(data: try JSONEncoder().encode($0), encoding: .utf8) ?? "{}"
            }.joined(separator: "\n")
            let prompt = """
            Merge these grounded chunk notes into one non-repetitive result.
            Return exactly this JSON shape:
            {"summary":"...","decisions":["..."],"action_items":[{"text":"...","owner":null,"due_date":null}]}
            Preserve only facts present in the chunk notes. Do not invent owners or due dates.

            CHUNK NOTES:
            \(mappedJSON)
            """
            wire = try await generateValidated(prompt: prompt)
        }

        let actions = wire.actionItems.compactMap { action -> MeetingActionItem? in
            let text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let owner = Self.explicitlyGrounded(action.owner, in: normalized)
            let dueDate = Self.explicitlyGrounded(action.dueDate, in: normalized)
            return MeetingActionItem(text: text, owner: owner, dueDate: dueDate)
        }
        return MeetingInsights(
            summaryMarkdown: wire.summary.trimmingCharacters(in: .whitespacesAndNewlines),
            decisions: wire.decisions.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            actionItems: actions
        )
    }

    private func generateValidated(prompt: String) async throws -> WireInsights {
        var lastError: Error?
        for attempt in 0..<2 {
            let request = attempt == 0
                ? prompt
                : prompt + "\nYour prior answer was invalid. Return only one valid JSON object with every required field."
            let response = try await inference.generate(prompt: request)
            do {
                return try Self.decode(response)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LocalMeetingModelError.invalidModelOutput("unknown schema error")
    }

    private static func decode(_ response: String) throws -> WireInsights {
        guard let first = response.firstIndex(of: "{"),
              let last = response.lastIndex(of: "}"),
              first <= last,
              let data = String(response[first...last]).data(using: .utf8) else {
            throw LocalMeetingModelError.invalidModelOutput("no JSON object")
        }
        do {
            return try JSONDecoder().decode(WireInsights.self, from: data)
        } catch {
            throw LocalMeetingModelError.invalidModelOutput(error.localizedDescription)
        }
    }

    private static func explicitlyGrounded(_ value: String?, in transcript: String) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              transcript.localizedCaseInsensitiveContains(value) else {
            return nil
        }
        return value
    }

    static func chunks(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let proposedEnd = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            var end = proposedEnd
            if proposedEnd < text.endIndex,
               let boundary = text[start..<proposedEnd].lastIndex(where: { $0 == "\n" || $0 == "." }) {
                end = text.index(after: boundary)
            }
            result.append(String(text[start..<end]))
            start = end
        }
        return result
    }
}
