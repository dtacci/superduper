//
//  MeetingsView.swift
//  Pindrop
//
//  Created on 2026-08-25.
//

import AVFoundation
import SwiftData
import SwiftUI

struct MeetingsView: View {
    @Environment(\.locale) private var locale
    @Query(sort: \MeetingOccurrence.scheduledStart, order: .reverse)
    private var occurrences: [MeetingOccurrence]

    let meetingsState: MeetingsFeatureState
    let onConnect: () -> Void
    let onEnableLaunchAtLogin: () -> Void
    let onDisconnect: () -> Void
    let onRefresh: () -> Void
    let onRecordMeeting: () -> Void
    let onArm: (MeetingOccurrenceSnapshot) -> Void
    let onDisarm: (String) -> Void
    let onRetryProcessing: (UUID) -> Void
    let onRegenerateInsights: (UUID) -> Void

    @State private var selectedOccurrenceID: UUID?
    @State private var showingGoogleCalendarSetup = false

    var body: some View {
        @Bindable var state = meetingsState
        VStack(spacing: 0) {
            PageHeader(
                title: localized("Meetings", locale: locale),
                meta: localized("Calendar schedules and private local workspaces", locale: locale)
            ) {
                HStack(spacing: 10) {
                    if state.isGoogleConnected {
                        SecondaryButton(
                            title: localized("Refresh", locale: locale),
                            systemImage: "arrow.clockwise",
                            action: onRefresh
                        )
                        .disabled(state.isRefreshing)
                    }
                    PrimaryButton(
                        title: localized("Record meeting", locale: locale),
                        systemImage: "record.circle",
                        action: onRecordMeeting
                    )
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 18)

            if let error = state.errorMessage {
                meetingBanner(
                    localized(error, locale: locale),
                    systemImage: "exclamationmark.triangle",
                    color: AppColors.warning
                )
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)
            }

            HSplitView {
                meetingList(state: state)
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 390)

                if let selected = selectedOccurrence {
                    MeetingWorkspaceDetail(
                        occurrence: selected,
                        onRetryProcessing: { onRetryProcessing(selected.id) },
                        onRegenerateInsights: { onRegenerateInsights(selected.id) }
                    )
                } else {
                    ContentUnavailableView(
                        localized("Select a meeting", locale: locale),
                        systemImage: "person.2.wave.2",
                        description: Text(localized("Choose a workspace to review its audio, transcript, and notes.", locale: locale))
                    )
                }
            }
        }
        .background(AppColors.contentBackground)
        .accessibilityIdentifier("meetings.page")
        .onAppear {
            if selectedOccurrenceID == nil { selectedOccurrenceID = occurrences.first?.id }
            if meetingsState.isGoogleConnected { onRefresh() }
        }
        .onChange(of: occurrences.map(\.id)) { _, ids in
            if let selectedOccurrenceID, ids.contains(selectedOccurrenceID) { return }
            self.selectedOccurrenceID = ids.first
        }
        .sheet(isPresented: $showingGoogleCalendarSetup) {
            GoogleCalendarSetupWizard(
                meetingsState: meetingsState,
                onConnect: onConnect,
                onEnableLaunchAtLogin: onEnableLaunchAtLogin
            )
        }
    }

    private var selectedOccurrence: MeetingOccurrence? {
        occurrences.first { $0.id == selectedOccurrenceID }
    }

    private func meetingList(state: MeetingsFeatureState) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                calendarSection(state: state)
                workspaceSection
            }
            .padding(20)
        }
        .background(AppColors.windowBackground)
    }

    private func calendarSection(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: localized("Google Calendar", locale: locale), isFirst: true)

            if !state.isGoogleConfigured {
                Text(localized("Google Calendar is not configured in this build.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            } else if !state.isGoogleConnected {
                SecondaryButton(
                    title: localized("Set Up Google Calendar", locale: locale),
                    systemImage: "calendar.badge.plus",
                    action: { showingGoogleCalendarSetup = true }
                )
            } else {
                HStack {
                    Label(localized("Connected", locale: locale), systemImage: "checkmark.circle.fill")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.success)
                    Spacer()
                    Button(localized("Disconnect", locale: locale), action: onDisconnect)
                        .buttonStyle(.plain)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }

                if state.calendarEvents.isEmpty {
                    Text(state.isRefreshing
                         ? localized("Refreshing events…", locale: locale)
                         : localized("No events in the next 30 days.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    ForEach(state.calendarEvents, id: \.persistentIdentity) { event in
                        calendarEventRow(event, state: state)
                    }
                }
            }
        }
    }

    private func calendarEventRow(
        _ event: MeetingOccurrenceSnapshot,
        state: MeetingsFeatureState
    ) -> some View {
        let armed = state.armedOccurrenceIDsByIdentity[event.persistentIdentity] != nil
        return VStack(alignment: .leading, spacing: 7) {
            Text(event.title)
                .font(AppTypography.labelStrong)
                .foregroundStyle(AppColors.textPrimary)
                .lineLimit(2)
            Text(event.start.formatted(date: .abbreviated, time: .shortened))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
            HStack {
                if event.joinURL == nil {
                    Label(localized("No supported join link", locale: locale), systemImage: "link.badge.plus")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textTertiary)
                }
                Spacer()
                Button(armed ? localized("Disarm", locale: locale) : localized("Arm", locale: locale)) {
                    armed ? onDisarm(event.persistentIdentity) : onArm(event)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(event.joinURL == nil || event.start <= Date())
                .accessibilityIdentifier("meeting.calendar.\(armed ? "disarm" : "arm")")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.border, lineWidth: 1))
    }

    private var workspaceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: localized("Workspaces", locale: locale), isFirst: occurrences.isEmpty)
            if occurrences.isEmpty {
                Text(localized("Recorded and armed meetings appear here.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            } else {
                ForEach(occurrences) { occurrence in
                    Button {
                        selectedOccurrenceID = occurrence.id
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(statusColor(occurrence.state))
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(occurrence.series?.displayName ?? occurrence.calendarTitle ?? localized("Meeting", locale: locale))
                                    .font(AppTypography.labelStrong)
                                    .foregroundStyle(AppColors.textPrimary)
                                    .lineLimit(1)
                                Text("\(occurrence.scheduledStart.formatted(date: .abbreviated, time: .shortened)) · \(localized(occurrence.state.rawValue.capitalized, locale: locale))")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedOccurrenceID == occurrence.id ? AppColors.contentBackground : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func meetingBanner(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(color)
            Text(text).font(AppTypography.caption).foregroundStyle(AppColors.textPrimary)
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.windowBackground))
    }

    private func statusColor(_ state: MeetingRecordingState) -> Color {
        switch state {
        case .ready: return AppColors.success
        case .failed, .missed: return AppColors.warning
        case .recording: return AppColors.error
        case .preparing, .processing: return AppColors.accent
        case .scheduled: return AppColors.textSecondary
        case .canceled: return AppColors.textTertiary
        }
    }
}

struct GoogleCalendarSetupWizard: View {
    private enum Step: Int, CaseIterable {
        case privacy
        case account
        case readiness
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let meetingsState: MeetingsFeatureState
    let onConnect: () -> Void
    let onEnableLaunchAtLogin: () -> Void

    @State private var step: Step = .privacy

    var body: some View {
        @Bindable var state = meetingsState

        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(localized("Google Calendar setup", locale: locale))
                        .font(AppTypography.labelStrongSelected)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(
                        String(
                            format: localized("Step %d of 3", locale: locale),
                            step.rawValue + 1
                        )
                    )
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
                .accessibilityLabel(localized("Close", locale: locale))
            }
            .padding(24)

            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? AppColors.accent : AppColors.border)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 24)

            Group {
                switch step {
                case .privacy:
                    privacyStep
                case .account:
                    accountStep(state: state)
                case .readiness:
                    readinessStep(state: state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(24)

            Divider().overlay(AppColors.border)
            footer(state: state)
                .padding(20)
        }
        .frame(width: 520)
        .frame(minHeight: 470)
        .background(AppColors.windowBackground)
        .onChange(of: state.isGoogleConnected) { _, connected in
            guard connected, step == .account else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                step = .readiness
            }
        }
        .accessibilityIdentifier("googleCalendar.setupWizard")
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            wizardTitle(
                localized("Connect Google Calendar", locale: locale),
                subtitle: localized(
                    "Pindrop uses read-only access to show upcoming meetings you can choose to arm.",
                    locale: locale
                )
            )
            wizardDetail(
                icon: "eye",
                title: localized("Your calendar stays read-only", locale: locale),
                detail: localized(
                    "Pindrop asks Google only for permission to view your calendar list and event details.",
                    locale: locale
                )
            )
            wizardDetail(
                icon: "hand.tap",
                title: localized("Only meetings you arm are recorded", locale: locale),
                detail: localized(
                    "Connecting an account never arms or records an event automatically.",
                    locale: locale
                )
            )
            wizardDetail(
                icon: "lock.macwindow",
                title: localized("Audio and notes stay on this Mac", locale: locale),
                detail: localized(
                    "Meeting audio, transcripts, notes, and insights are never sent to Google.",
                    locale: locale
                )
            )
        }
    }

    private func accountStep(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            wizardTitle(
                localized("Sign in with Google", locale: locale),
                subtitle: localized(
                    "Your browser will open for Google sign-in and consent, then return you to Pindrop.",
                    locale: locale
                )
            )

            if !state.isGoogleConfigured {
                wizardStatus(
                    icon: "wrench.and.screwdriver",
                    color: AppColors.warning,
                    title: localized("Setup required", locale: locale),
                    detail: localized(
                        "This build does not include Pindrop's Google OAuth client ID. Official builds include it automatically.",
                        locale: locale
                    )
                )
            } else if state.isGoogleConnected {
                wizardStatus(
                    icon: "checkmark.circle.fill",
                    color: AppColors.success,
                    title: localized("Google Calendar is connected.", locale: locale),
                    detail: localized("Pindrop can now load your upcoming events.", locale: locale)
                )
            } else if state.isRefreshing {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(localized("Waiting for Google…", locale: locale))
                        .font(AppTypography.label)
                        .foregroundStyle(AppColors.textPrimary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))
            }

            if let error = state.errorMessage, !error.isEmpty {
                wizardStatus(
                    icon: "exclamationmark.triangle.fill",
                    color: AppColors.warning,
                    title: localized("Google sign-in did not finish", locale: locale),
                    detail: localized(error, locale: locale)
                )
            }
        }
    }

    private func readinessStep(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            wizardTitle(
                localized("Ready for scheduled meetings", locale: locale),
                subtitle: localized(
                    "One final setting keeps Pindrop available when an armed meeting begins.",
                    locale: locale
                )
            )
            wizardStatus(
                icon: state.isGoogleConnected ? "checkmark.circle.fill" : "xmark.circle.fill",
                color: state.isGoogleConnected ? AppColors.success : AppColors.warning,
                title: localized("Connected to Google", locale: locale),
                detail: localized("One Google account can be connected at a time.", locale: locale)
            )
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: state.isLaunchAtLoginEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(state.isLaunchAtLoginEnabled ? AppColors.success : AppColors.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Launch at Login", locale: locale))
                        .font(AppTypography.labelStrong)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(localized("Required so Pindrop is running when an armed meeting starts.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                if !state.isLaunchAtLoginEnabled {
                    Button(localized("Enable", locale: locale), action: onEnableLaunchAtLogin)
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("googleCalendar.setup.enableLaunchAtLogin")
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))

            wizardDetail(
                icon: "checklist",
                title: localized("Recording readiness", locale: locale),
                detail: localized(
                    "Microphone access, system audio access, transcription and diarization models, and free disk space are checked before an event can be armed.",
                    locale: locale
                )
            )
        }
    }

    @ViewBuilder
    private func footer(state: MeetingsFeatureState) -> some View {
        HStack {
            if step != .privacy {
                Button(localized("Back", locale: locale)) {
                    step = Step(rawValue: step.rawValue - 1) ?? .privacy
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppColors.textSecondary)
            }
            Spacer()
            switch step {
            case .privacy:
                Button(localized("Continue", locale: locale)) {
                    step = .account
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.isGoogleConfigured)
            case .account:
                if state.isGoogleConnected {
                    Button(localized("Continue", locale: locale)) {
                        step = .readiness
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button(localized("Continue in Browser", locale: locale), action: onConnect)
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.isGoogleConfigured || state.isRefreshing)
                        .accessibilityIdentifier("googleCalendar.setup.connect")
                }
            case .readiness:
                Button(localized("Finish setup", locale: locale)) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!state.isGoogleConnected || !state.isLaunchAtLoginEnabled)
                .accessibilityIdentifier("googleCalendar.setup.finish")
            }
        }
    }

    private func wizardTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(AppTypography.title)
                .foregroundStyle(AppColors.textPrimary)
            Text(subtitle)
                .font(AppTypography.body)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func wizardDetail(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColors.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTypography.labelStrong).foregroundStyle(AppColors.textPrimary)
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func wizardStatus(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(AppTypography.labelStrong).foregroundStyle(AppColors.textPrimary)
                Text(detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))
    }
}

private struct MeetingWorkspaceDetail: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.locale) private var locale
    @Bindable var occurrence: MeetingOccurrence
    let onRetryProcessing: () -> Void
    let onRegenerateInsights: () -> Void

    @StateObject private var audioPlayer = MeetingAudioPlayer()
    @State private var seriesName = ""
    @State private var notes = ""
    @State private var summary = ""
    @State private var decisions = ""
    @State private var actions: [MeetingActionItem] = []
    @State private var speakerLabels: [String: String] = [:]
    @State private var saveError: String?

    private var meetingStore: MeetingStore { MeetingStore(modelContext: modelContext) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                workspaceHeader
                if let warning = occurrence.sourceHealthWarning {
                    Label(localized(warning, locale: locale), systemImage: "waveform.badge.exclamationmark")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.warning)
                }
                audioSection
                transcriptSection
                notesSection
                insightsSection
                if let saveError {
                    Text(saveError).font(AppTypography.caption).foregroundStyle(AppColors.error)
                }
            }
            .padding(32)
            .frame(maxWidth: 820, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppColors.contentBackground)
        .onAppear(perform: loadDrafts)
        .onChange(of: occurrence.id) { _, _ in loadDrafts() }
    }

    private var workspaceHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(localized("Meeting name", locale: locale), text: $seriesName)
                .textFieldStyle(.plain)
                .font(AppTypography.pageTitle)
                .onSubmit { saveSeriesName() }
            HStack(spacing: 12) {
                Text(occurrence.scheduledStart.formatted(date: .long, time: .shortened))
                Text(localized(occurrence.state.rawValue.capitalized, locale: locale))
                if occurrence.isArmed { Label(localized("Armed", locale: locale), systemImage: "alarm") }
            }
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textSecondary)

            if let failure = occurrence.failureMessage {
                Text(localized(failure, locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.warning)
            }
            if occurrence.canRetryProcessing {
                SecondaryButton(
                    title: localized("Retry processing", locale: locale),
                    systemImage: "arrow.clockwise",
                    action: onRetryProcessing
                )
                .accessibilityIdentifier("meeting.retryProcessing")
            }
        }
    }

    private var audioSection: some View {
        workspaceSection(localized("Audio", locale: locale)) {
            if let audioURL = occurrence.managedAudioURL ?? occurrence.recoveryAudioURLs.first {
                HStack(spacing: 12) {
                    Button {
                        audioPlayer.toggle(url: audioURL)
                    } label: {
                        Label(
                            audioPlayer.isPlaying ? localized("Pause", locale: locale) : localized("Play", locale: locale),
                            systemImage: audioPlayer.isPlaying ? "pause.fill" : "play.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    Text(audioURL.lastPathComponent)
                        .font(AppTypography.monoSmall)
                        .foregroundStyle(AppColors.textSecondary)
                        .lineLimit(1)
                }
            } else {
                Text(localized("No audio has been captured yet.", locale: locale))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private var transcriptSection: some View {
        workspaceSection(localized("Transcript", locale: locale)) {
            if let transcript = occurrence.transcript {
                let segments = transcript.diarizedSegments
                if segments.isEmpty {
                    Text(transcript.text).textSelection(.enabled)
                } else {
                    ForEach(uniqueSpeakerIDs(in: segments), id: \.self) { speakerID in
                        HStack {
                            Text(speakerID).font(AppTypography.monoSmall).foregroundStyle(AppColors.textTertiary)
                            TextField(
                                localized("Speaker name", locale: locale),
                                text: Binding(
                                    get: { speakerLabels[speakerID] ?? defaultSpeakerLabel(speakerID, segments: segments) },
                                    set: { speakerLabels[speakerID] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                        }
                    }
                    Button(localized("Save speaker labels", locale: locale), action: saveSpeakerLabels)
                        .buttonStyle(.bordered)
                    Divider()
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(speakerLabels[segment.speakerId] ?? segment.speakerLabel)
                                .font(AppTypography.labelStrong)
                                .foregroundStyle(AppColors.accent)
                            Text(segment.text).textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text(localized("The transcript will appear after processing.", locale: locale))
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private var notesSection: some View {
        workspaceSection(localized("Notes", locale: locale)) {
            TextEditor(text: $notes)
                .font(AppTypography.body)
                .frame(minHeight: 150)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.windowBackground))
            Button(localized("Save notes", locale: locale), action: saveNotes)
                .buttonStyle(.bordered)
        }
    }

    private var insightsSection: some View {
        workspaceSection(localized("On-device insights", locale: locale)) {
            TextEditor(text: $summary)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.windowBackground))
            Text(localized("Decisions (one per line)", locale: locale))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
            TextEditor(text: $decisions)
                .frame(minHeight: 80)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(AppColors.windowBackground))
            ForEach($actions) { $action in
                HStack {
                    Toggle("", isOn: $action.isComplete).labelsHidden()
                    TextField(localized("Action item", locale: locale), text: $action.text)
                    TextField(localized("Owner", locale: locale), text: optionalBinding($action.owner))
                        .frame(width: 110)
                    TextField(localized("Due date", locale: locale), text: optionalBinding($action.dueDate))
                        .frame(width: 110)
                }
            }
            HStack {
                Button(localized("Add action item", locale: locale)) {
                    actions.append(MeetingActionItem(text: ""))
                }
                Button(localized("Save insights", locale: locale), action: saveInsights)
                Spacer()
                SecondaryButton(
                    title: localized("Regenerate locally", locale: locale),
                    systemImage: "brain.head.profile",
                    action: onRegenerateInsights
                )
            }
            .buttonStyle(.bordered)
        }
    }

    private func workspaceSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: title)
            content()
        }
    }

    private func loadDrafts() {
        seriesName = occurrence.series?.displayName ?? occurrence.calendarTitle ?? localized("Meeting", locale: locale)
        notes = occurrence.notesMarkdown
        summary = occurrence.summaryMarkdown ?? ""
        decisions = occurrence.decisions.joined(separator: "\n")
        actions = occurrence.actionItems
        speakerLabels = occurrence.speakerLabels
        saveError = nil
        audioPlayer.stop()
    }

    private func saveSeriesName() { performSave { try meetingStore.renameSeries(id: occurrence.id, displayName: seriesName) } }
    private func saveNotes() { performSave { try meetingStore.saveNotes(id: occurrence.id, markdown: notes) } }
    private func saveSpeakerLabels() { performSave { try meetingStore.saveSpeakerLabels(id: occurrence.id, labels: speakerLabels) } }
    private func saveInsights() {
        performSave {
            try meetingStore.saveInsights(
                id: occurrence.id,
                insights: MeetingInsights(
                    summaryMarkdown: summary,
                    decisions: decisions.split(separator: "\n").map(String.init),
                    actionItems: actions.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                )
            )
        }
    }

    private func performSave(_ operation: () throws -> Void) {
        do { try operation(); saveError = nil } catch { saveError = error.localizedDescription }
    }

    private func uniqueSpeakerIDs(in segments: [DiarizedTranscriptSegment]) -> [String] {
        var seen = Set<String>()
        return segments.compactMap { seen.insert($0.speakerId).inserted ? $0.speakerId : nil }
    }

    private func defaultSpeakerLabel(_ id: String, segments: [DiarizedTranscriptSegment]) -> String {
        segments.first { $0.speakerId == id }?.speakerLabel ?? id
    }

    private func optionalBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

@MainActor
private final class MeetingAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    private var player: AVAudioPlayer?
    private var loadedURL: URL?

    func toggle(url: URL) {
        do {
            if loadedURL != url {
                player = try AVAudioPlayer(contentsOf: url)
                player?.delegate = self
                player?.prepareToPlay()
                loadedURL = url
            }
            if player?.isPlaying == true {
                player?.pause()
                isPlaying = false
            } else {
                player?.play()
                isPlaying = true
            }
        } catch {
            isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in self?.isPlaying = false }
    }
}
