import Foundation
import SwiftData

typealias TranscriptionRecord = TranscriptionRecordSchemaV13.TranscriptionRecord
typealias MediaFolder = TranscriptionRecordSchemaV13.MediaFolder
typealias ParticipantProfile = TranscriptionRecordSchemaV13.ParticipantProfile
typealias ParticipantTrainingEvidence = TranscriptionRecordSchemaV13.ParticipantTrainingEvidence
typealias MeetingSeries = TranscriptionRecordSchemaV13.MeetingSeries
typealias MeetingOccurrence = TranscriptionRecordSchemaV13.MeetingOccurrence

enum MeetingRecordingState: String, CaseIterable, Codable, Sendable {
    case scheduled
    case preparing
    case recording
    case processing
    case ready
    case failed
    case missed
    case canceled
}

enum MeetingAudioSourceHealth: String, Codable, Sendable {
    case notRequested
    case healthy
    case silent
    case failed
}

extension MeetingOccurrence {
    var state: MeetingRecordingState {
        get { MeetingRecordingState(rawValue: stateRawValue) ?? .failed }
        set { stateRawValue = newValue.rawValue }
    }

    var joinURL: URL? {
        guard let joinURLString else { return nil }
        return URL(string: joinURLString)
    }

    var workspaceURL: URL { URL(fileURLWithPath: workspacePath, isDirectory: true) }

    var managedAudioURL: URL? {
        guard let managedAudioPath else { return nil }
        return URL(fileURLWithPath: managedAudioPath)
    }

    var canRetryProcessing: Bool {
        state == .failed && (managedAudioURL != nil || !recoveryAudioURLs.isEmpty)
    }

    var recoveryAudioURLs: [URL] {
        guard let recoveryAudioPathsJSON,
              let data = recoveryAudioPathsJSON.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return paths.map { URL(fileURLWithPath: $0) }
    }

    var decisions: [String] {
        guard let decisionsJSON,
              let data = decisionsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    var actionItems: [MeetingActionItem] {
        guard let actionItemsJSON,
              let data = actionItemsJSON.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([MeetingActionItem].self, from: data)) ?? []
    }

    var speakerLabels: [String: String] {
        guard let speakerLabelsJSON,
              let data = speakerLabelsJSON.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

enum TranscriptionTitleOrigin: String {
    case sourceMetadata
    case fallback
}

extension TranscriptionRecord {
    var sourceTitleOrigin: TranscriptionTitleOrigin? {
        guard let sourceTitleOriginRawValue else { return nil }
        return TranscriptionTitleOrigin(rawValue: sourceTitleOriginRawValue)
    }

    var hasSourceMetadataTitle: Bool {
        sourceTitleOrigin == .sourceMetadata
    }

    var preferredTitle: String? {
        let trimmedSourceDisplayName = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGeneratedTitle = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasSourceMetadataTitle, let trimmedSourceDisplayName, !trimmedSourceDisplayName.isEmpty {
            return trimmedSourceDisplayName
        }
        if let trimmedGeneratedTitle, !trimmedGeneratedTitle.isEmpty {
            return trimmedGeneratedTitle
        }
        if let trimmedSourceDisplayName, !trimmedSourceDisplayName.isEmpty {
            return trimmedSourceDisplayName
        }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? nil : trimmedText
    }

    var resolvedSourceKind: MediaSourceKind {
        guard let sourceKindRawValue else { return .voiceRecording }
        return MediaSourceKind(rawValue: sourceKindRawValue) ?? .voiceRecording
    }

    var isVoiceTranscription: Bool {
        resolvedSourceKind == .voiceRecording
    }

    var isMediaTranscription: Bool {
        resolvedSourceKind.isMediaBacked
    }

    var managedMediaURL: URL? {
        guard let managedMediaPath, !managedMediaPath.isEmpty else { return nil }
        return URL(fileURLWithPath: managedMediaPath)
    }

    var thumbnailURL: URL? {
        guard let thumbnailPath, !thumbnailPath.isEmpty else { return nil }
        return URL(fileURLWithPath: thumbnailPath)
    }

    /// Decoded pipeline latency breakdown, when this record was produced by an
    /// instrumented dictation path.
    var pipelineMetrics: PipelineMetrics? {
        guard let pipelineMetricsJSON else { return nil }
        return PipelineMetrics(jsonString: pipelineMetricsJSON)
    }

    var diarizedSegments: [DiarizedTranscriptSegment] {
        guard let diarizationSegmentsJSON,
              let data = diarizationSegmentsJSON.data(using: .utf8),
              let segments = try? JSONDecoder().decode([DiarizedTranscriptSegment].self, from: data) else {
            return []
        }
        return segments
    }

    var mediaLibrarySortName: String {
        preferredTitle ?? text
    }

    func matchesMediaLibrarySearch(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return true }

        let searchableFields = [
            preferredTitle,
            text,
            originalText,
            sourceDisplayName,
            generatedTitle,
            aiSummary,
            originalSourceURL
        ]

        return searchableFields.contains { value in
            guard let value, !value.isEmpty else { return false }
            return value.localizedStandardContains(trimmedQuery)
        }
    }

    /// Cached word count when present; otherwise derived from `text`.
    var effectiveWordCount: Int {
        wordCount ?? text.wordCount
    }

    // MARK: - Meeting metadata helpers

    /// Distinct speaker count from diarized segments (by speakerId, falling back to label).
    var speakerCount: Int {
        let segments = diarizedSegments
        guard !segments.isEmpty else { return 0 }
        var seen = Set<String>()
        for segment in segments {
            let key = segment.speakerId.isEmpty ? segment.speakerLabel : segment.speakerId
            if !key.isEmpty {
                seen.insert(key)
            }
        }
        return seen.count
    }

    /// Whether diarization payload is present on the record.
    var isDiarized: Bool {
        diarizationSegmentsJSON != nil
    }

    /// Whether a non-empty AI summary is available.
    var hasSummary: Bool {
        guard let aiSummary else { return false }
        return !aiSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Formatted meeting metadata line, e.g. `"3 speakers · diarized · summary ready"`.
    /// Builds from localized parts; returns an empty string when nothing applies.
    func meetingMetadataString(locale: Locale) -> String {
        var parts: [String] = []

        let count = speakerCount
        if count > 0 {
            if count == 1 {
                parts.append(localized("1 speaker", locale: locale))
            } else {
                parts.append(
                    String(format: localized("%d speakers", locale: locale), count)
                )
            }
        }

        if isDiarized {
            parts.append(localized("diarized", locale: locale))
        }

        if hasSummary {
            parts.append(localized("summary ready", locale: locale))
        }

        return parts.joined(separator: " · ")
    }
}

extension MediaFolder {
    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
