//
//  MeetingsView.swift
//  SuperduperDictation
//
//  Created on 2026-08-25.
//

import AppKit
import AVFoundation
import SwiftData
import SwiftUI

struct MeetingsView: View {
    @Environment(\.locale) private var locale
    @Query(sort: \MeetingOccurrence.scheduledStart, order: .reverse)
    private var occurrences: [MeetingOccurrence]

    let meetingsState: MeetingsFeatureState
    let googleCalendarActions: GoogleCalendarSetupActions
    let onRefresh: () -> Void
    let onReviewWeek: () -> Void
    let onApplyWeeklySelection: (Set<String>) -> Void
    let onRecordMeeting: () -> Void
    let onArm: (MeetingOccurrenceSnapshot) -> Void
    let onDisarm: (String) -> Void
    let onRetryProcessing: (UUID) -> Void
    let onRegenerateInsights: (UUID) -> Void

    @State private var selectedOccurrenceID: UUID?

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
                        isGeneratingInsights: state.generatingInsightsOccurrenceIDs.contains(selected.id),
                        isDownloadingNotesModel: state.isDownloadingMeetingNotesModel,
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
            if let requested = meetingsState.requestedOccurrenceID {
                selectedOccurrenceID = requested
                meetingsState.requestedOccurrenceID = nil
            }
            if selectedOccurrenceID == nil { selectedOccurrenceID = occurrences.first?.id }
            if meetingsState.isGoogleConnected { onRefresh() }
        }
        .onChange(of: meetingsState.requestedOccurrenceID) { _, requested in
            guard let requested else { return }
            selectedOccurrenceID = requested
            meetingsState.requestedOccurrenceID = nil
        }
        .onChange(of: occurrences.map(\.id)) { _, ids in
            if let selectedOccurrenceID, ids.contains(selectedOccurrenceID) { return }
            self.selectedOccurrenceID = ids.first
        }
        .sheet(
            isPresented: Binding(
                get: { meetingsState.isGoogleSetupPresented },
                set: { meetingsState.isGoogleSetupPresented = $0 }
            )
        ) {
            GoogleCalendarSetupWizard(
                meetingsState: meetingsState,
                actions: googleCalendarActions
            )
        }
        .sheet(
            isPresented: Binding(
                get: { meetingsState.isWeeklyReviewPresented },
                set: { meetingsState.isWeeklyReviewPresented = $0 }
            )
        ) {
            WeeklyMeetingReviewSheet(
                events: meetingsState.calendarEvents,
                armedOccurrenceIDsByIdentity: meetingsState.armedOccurrenceIDsByIdentity,
                isApplying: meetingsState.isApplyingWeeklySelection,
                errorMessage: meetingsState.weeklyReviewErrorMessage,
                onRefresh: onRefresh,
                onApply: onApplyWeeklySelection
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

    private func connectionSummary(state: MeetingsFeatureState) -> String {
        guard let email = state.googleAccountEmail else {
            return localized("Connected", locale: locale)
        }
        return String(format: localized("Connected as %@", locale: locale), email)
    }

    static func relativeSyncTime(_ date: Date, now: Date, locale: Locale) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        // Anything under a minute reads as "now" rather than "30 seconds ago".
        let elapsed = max(0, now.timeIntervalSince(date))
        return formatter.localizedString(fromTimeInterval: elapsed < 60 ? 0 : -elapsed)
    }

    private func calendarSection(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: localized("Google Calendar", locale: locale), isFirst: true)

            if !state.isGoogleConnected {
                SecondaryButton(
                    title: localized("Set Up Google Calendar", locale: locale),
                    systemImage: "calendar.badge.plus",
                    action: { meetingsState.isGoogleSetupPresented = true }
                )
            } else {
                if state.googleNeedsReconnect {
                    HStack(spacing: 10) {
                        Label(
                            localized("Google Calendar sign-in expired.", locale: locale),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.warning)
                        Spacer()
                        Button(localized("Reconnect", locale: locale)) {
                            meetingsState.isGoogleSetupPresented = true
                            googleCalendarActions.connect()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(state.isConnectingGoogle)
                        .accessibilityIdentifier("meetings.reconnectGoogle")
                    }
                } else {
                    HStack {
                        Label(connectionSummary(state: state), systemImage: "checkmark.circle.fill")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.success)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button(localized("Disconnect", locale: locale), action: googleCalendarActions.disconnect)
                            .buttonStyle(.plain)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                    }
                    if let lastSync = state.lastGoogleSyncAt {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(String(
                                format: localized("Synced %@", locale: locale),
                                Self.relativeSyncTime(lastSync, now: context.date, locale: locale)
                            ))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textTertiary)
                        }
                    }
                }

                SecondaryButton(
                    title: localized("Check Weekly Meetings", locale: locale),
                    systemImage: "calendar.badge.clock",
                    action: onReviewWeek
                )
                .accessibilityIdentifier("meetings.reviewWeek")

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

struct WeeklyMeetingReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let events: [MeetingOccurrenceSnapshot]
    let armedOccurrenceIDsByIdentity: [String: UUID]
    let isApplying: Bool
    let errorMessage: String?
    let onRefresh: () -> Void
    let onApply: (Set<String>) -> Void

    @State private var reviewStartedAt = Date()
    @State private var selectedIdentities = Set<String>()
    @State private var didLoadInitialSelection = false
    @State private var otherItemsExpanded = false

    private var weeklyEvents: [MeetingOccurrenceSnapshot] {
        WeeklyMeetingReview.upcomingEvents(from: events, now: reviewStartedAt)
    }

    private var recommendedEvents: [MeetingOccurrenceSnapshot] {
        weeklyEvents.filter {
            WeeklyMeetingReview.assessment(for: $0).bucket == .recommended
        }
    }

    private var otherEvents: [MeetingOccurrenceSnapshot] {
        weeklyEvents.filter {
            WeeklyMeetingReview.assessment(for: $0).bucket == .other
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(AppColors.border)

            if weeklyEvents.isEmpty {
                ContentUnavailableView(
                    localized("No upcoming calendar events this week", locale: locale),
                    systemImage: "calendar",
                    description: Text(localized("Refresh Google Calendar or check again later.", locale: locale))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        recommendedSection
                        otherSection
                    }
                    .padding(24)
                }
            }

            if let errorMessage, !errorMessage.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(AppColors.warning)
                    Text(localized(errorMessage, locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(AppColors.windowBackground)
            }

            Divider().overlay(AppColors.border)
            footer
        }
        .frame(width: 680, height: 640)
        .background(AppColors.contentBackground)
        .onAppear {
            guard !didLoadInitialSelection else { return }
            reviewStartedAt = Date()
            selectedIdentities = WeeklyMeetingReview.initiallySelectedIdentities(
                events: weeklyEvents,
                armedIdentities: Set(armedOccurrenceIDsByIdentity.keys)
            )
            didLoadInitialSelection = true
        }
        .accessibilityIdentifier("meetings.weeklyReview")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized("Plan this week's meeting recordings", locale: locale))
                    .font(AppTypography.title)
                    .foregroundStyle(AppColors.textPrimary)
                Text(localized(
                    "Recommended calls have other participants and a supported join link. Nothing records unless you check it and save.",
                    locale: locale
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .disabled(isApplying)
            .accessibilityLabel(localized("Refresh", locale: locale))

            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppColors.textSecondary)
            .disabled(isApplying)
            .accessibilityLabel(localized("Close", locale: locale))
        }
        .padding(24)
    }

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Recommended to record", locale: locale))
                        .font(AppTypography.labelStrongSelected)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(localized("Calls with another person, especially someone outside your organization.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                Spacer()
                Text("\(recommendedEvents.count)")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }

            if recommendedEvents.isEmpty {
                Text(localized("No recommended calls in the next seven days.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(recommendedEvents, id: \.persistentIdentity) { event in
                    meetingRow(event)
                }
            }
        }
    }

    private var otherSection: some View {
        DisclosureGroup(isExpanded: $otherItemsExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                if otherEvents.isEmpty {
                    Text(localized("No other calendar items this week.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                } else {
                    ForEach(otherEvents, id: \.persistentIdentity) { event in
                        meetingRow(event)
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(localized("Other calls and calendar items", locale: locale))
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.textPrimary)
                Text(localized("Solo, all-day, or missing a supported join link.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
        }
        .tint(AppColors.textSecondary)
    }

    private func meetingRow(_ event: MeetingOccurrenceSnapshot) -> some View {
        let assessment = WeeklyMeetingReview.assessment(for: event)
        let isSelected = selectedIdentities.contains(event.persistentIdentity)
        return Toggle(
            isOn: Binding(
                get: { selectedIdentities.contains(event.persistentIdentity) },
                set: { selected in
                    if selected {
                        guard assessment.canScheduleAutomatically else { return }
                        selectedIdentities.insert(event.persistentIdentity)
                    } else {
                        selectedIdentities.remove(event.persistentIdentity)
                    }
                }
            )
        ) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.title)
                        .font(AppTypography.labelStrong)
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(2)
                    Text(eventTimeText(event))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Label(reasonText(assessment.reason), systemImage: reasonIcon(assessment.reason))
                        .font(AppTypography.caption)
                        .foregroundStyle(reasonColor(assessment.reason))
                }
                Spacer(minLength: 8)
                if armedOccurrenceIDsByIdentity[event.persistentIdentity] != nil {
                    Text(localized("Armed", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.success)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.windowBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppColors.border, lineWidth: 1))
        }
        .toggleStyle(.checkbox)
        .disabled(isApplying || (!assessment.canScheduleAutomatically && !isSelected))
        .accessibilityIdentifier("meetings.weeklyReview.\(event.persistentIdentity)")
    }

    private var footer: some View {
        HStack {
            Text(String(
                format: localized("%d meeting recordings selected", locale: locale),
                locale: locale,
                selectedIdentities.count
            ))
            .font(AppTypography.caption)
            .foregroundStyle(AppColors.textSecondary)

            Spacer()

            Button(localized("Cancel", locale: locale)) { dismiss() }
                .buttonStyle(.plain)
                .disabled(isApplying)

            Button {
                onApply(selectedIdentities)
            } label: {
                if isApplying {
                    ProgressView().controlSize(.small)
                } else {
                    Text(localized("Save weekly schedule", locale: locale))
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isApplying)
            .accessibilityIdentifier("meetings.weeklyReview.save")
        }
        .padding(20)
    }

    private func eventTimeText(_ event: MeetingOccurrenceSnapshot) -> String {
        let start = event.start.formatted(date: .abbreviated, time: .shortened)
        guard let end = event.end else { return start }
        return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    private func reasonText(_ reason: WeeklyMeetingReviewReason) -> String {
        switch reason {
        case .externalParticipants:
            return localized("Includes an external participant", locale: locale)
        case .multipleParticipants:
            return localized("Includes other participants", locale: locale)
        case .noJoinLink:
            return localized("No supported join link", locale: locale)
        case .allDay:
            return localized("All-day calendar item", locale: locale)
        case .attendeeDataUnavailable:
            return localized("Attendee list unavailable", locale: locale)
        case .solo:
            return localized("Only you are invited", locale: locale)
        }
    }

    private func reasonIcon(_ reason: WeeklyMeetingReviewReason) -> String {
        switch reason {
        case .externalParticipants: return "person.crop.circle.badge.checkmark"
        case .multipleParticipants: return "person.2.fill"
        case .noJoinLink: return "link.badge.plus"
        case .allDay: return "calendar"
        case .attendeeDataUnavailable: return "questionmark.circle"
        case .solo: return "person.fill"
        }
    }

    private func reasonColor(_ reason: WeeklyMeetingReviewReason) -> Color {
        switch reason {
        case .externalParticipants: return AppColors.accent
        case .multipleParticipants: return AppColors.success
        case .noJoinLink, .attendeeDataUnavailable: return AppColors.warning
        case .allDay, .solo: return AppColors.textTertiary
        }
    }
}

/// Step-by-step Google Cloud setup for the Desktop OAuth client the setup wizard asks for.
struct GoogleCalendarSetupGuide: View {
    @Environment(\.locale) private var locale

    private struct GuideStep: Identifiable {
        let id: Int
        let text: String
        var linkTitle: String?
        var link: URL?
    }

    private var steps: [GuideStep] {
        [
            GuideStep(
                id: 1,
                text: localized(
                    "Create or pick a project. For a work account, create it inside your company's organization (ask IT if you can't).",
                    locale: locale
                )
            ),
            GuideStep(
                id: 2,
                text: localized("Enable the Google Calendar API.", locale: locale),
                linkTitle: localized("Open the Calendar API", locale: locale),
                link: URL(string: "https://console.cloud.google.com/apis/library/calendar-json.googleapis.com")
            ),
            GuideStep(
                id: 3,
                text: localized(
                    "Set up the consent screen. Work (Google Workspace) accounts: choose Internal. Personal Gmail: choose External, add yourself as a test user, and publish the app so sign-in doesn't expire after 7 days.",
                    locale: locale
                ),
                linkTitle: localized("Open the consent screen", locale: locale),
                link: URL(string: "https://console.cloud.google.com/auth/overview")
            ),
            GuideStep(
                id: 4,
                text: localized("Under Clients, create an OAuth client with the application type Desktop app.", locale: locale),
                linkTitle: localized("Open OAuth clients", locale: locale),
                link: URL(string: "https://console.cloud.google.com/auth/clients")
            ),
            GuideStep(
                id: 5,
                text: localized(
                    "Copy the client ID and client secret, paste both here, and choose Save client ID.",
                    locale: locale
                )
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(localized("Get a Google client ID and secret", locale: locale))
                    .font(AppTypography.labelStrong)
                    .foregroundStyle(AppColors.textPrimary)
                Text(localized(
                    "Do this once in Google Cloud Console, signed in with the Google account whose calendar you want to use.",
                    locale: locale
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(step.id).")
                        .font(AppTypography.labelStrong)
                        .foregroundStyle(AppColors.textSecondary)
                        .frame(width: 16, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(step.text)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let linkTitle = step.linkTitle, let link = step.link {
                            Link(linkTitle, destination: link)
                                .font(AppTypography.caption)
                        }
                    }
                }
            }

            Divider().overlay(AppColors.border)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(AppColors.warning)
                Text(localized(
                    "If Google says access is blocked, ask your Workspace admin to trust this client ID in the Admin console under Security → API controls.",
                    locale: locale
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .frame(width: 400)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("googleCalendar.setupGuide")
    }
}

/// Google Calendar account actions shared by the Meetings page and Settings.
struct GoogleCalendarSetupActions {
    var connect: () -> Void = {}
    var cancelConnect: () -> Void = {}
    var saveCustomClient: (_ clientID: String, _ clientSecret: String) -> Void = { _, _ in }
    var useBuiltInClient: () -> Void = {}
    var disconnect: () -> Void = {}
    var enableLaunchAtLogin: () -> Void = {}
}

/// One-screen Google Calendar sign-in. With a built-in OAuth client this is a
/// single browser round-trip; pasting a client is tucked under a disclosure.
struct GoogleCalendarSetupWizard: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    let meetingsState: MeetingsFeatureState
    let actions: GoogleCalendarSetupActions

    @State private var isShowingSetupGuide = false
    @State private var isShowingCustomClient = false

    private var isHealthyConnection: Bool {
        meetingsState.isGoogleConnected && !meetingsState.googleNeedsReconnect
    }

    var body: some View {
        let state = meetingsState

        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text(localized("Google Calendar setup", locale: locale))
                    .font(AppTypography.labelStrongSelected)
                    .foregroundStyle(AppColors.textPrimary)
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
            .padding(.horizontal, 24)
            .padding(.top, 20)

            Group {
                if isHealthyConnection {
                    connectedBody(state: state)
                } else {
                    signInBody(state: state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(24)

            Divider().overlay(AppColors.border)
            footer(state: state)
                .padding(20)
        }
        .frame(width: 520)
        .background(AppColors.windowBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("googleCalendar.setupWizard")
    }

    private func signInBody(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardTitle(
                localized("Connect Google Calendar", locale: locale),
                subtitle: localized(
                    "Superduper Dictation uses read-only access to show upcoming meetings you can choose to arm.",
                    locale: locale
                )
            )
            wizardDetail(
                icon: "eye",
                title: localized("Your calendar stays read-only", locale: locale),
                detail: localized(
                    "Superduper Dictation asks Google only for permission to view your calendar list and event details.",
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

            if state.googleNeedsReconnect && !state.isConnectingGoogle {
                wizardStatus(
                    icon: "exclamationmark.arrow.triangle.2.circlepath",
                    color: AppColors.warning,
                    title: localized("Google Calendar sign-in expired.", locale: locale),
                    detail: localized(
                        "Sign in again to keep upcoming meetings and attendee names up to date.",
                        locale: locale
                    )
                )
            }

            if state.isConnectingGoogle {
                waitingForGoogle(state: state)
            }

            if let error = state.errorMessage, !error.isEmpty, !state.isConnectingGoogle {
                wizardStatus(
                    icon: "exclamationmark.triangle.fill",
                    color: AppColors.warning,
                    title: localized("Google sign-in did not finish", locale: locale),
                    detail: localized(error, locale: locale)
                )
            }

            if state.isGoogleConfigured {
                DisclosureGroup(isExpanded: $isShowingCustomClient) {
                    customClientForm(state: state)
                        .padding(.top, 10)
                } label: {
                    Text(localized("Use my own OAuth client", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                }
                .accessibilityIdentifier("googleCalendar.setup.customClientDisclosure")
            } else {
                wizardStatus(
                    icon: "wrench.and.screwdriver",
                    color: AppColors.warning,
                    title: localized("Setup required", locale: locale),
                    detail: localized(
                        "Paste a Google Desktop OAuth client ID and secret once, then the normal browser sign-in flow handles your account.",
                        locale: locale
                    )
                )
                customClientForm(state: state)
            }
        }
    }

    private func waitingForGoogle(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Waiting for Google…", locale: locale))
                        .font(AppTypography.labelStrong)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(localized(
                        "Your browser will open for Google sign-in and consent, then return you to Superduper Dictation.",
                        locale: locale
                    ))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let clientID = state.activeGoogleClientID {
                Divider().overlay(AppColors.border)
                Text(localized(
                    "Work account says access is blocked? Ask your Google Workspace admin to trust this client ID in the Admin console under Security → API controls.",
                    locale: locale
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(clientID)
                        .font(AppTypography.caption.monospaced())
                        .foregroundStyle(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer()
                    Button(localized("Copy", locale: locale)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(clientID, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(AppTypography.caption)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))
        .accessibilityIdentifier("googleCalendar.setup.waiting")
    }

    private func customClientForm(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.googleClientSource == .custom {
                HStack(spacing: 10) {
                    Text(localized("This Mac uses your own OAuth client.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer()
                    if state.hasBuiltInGoogleClient {
                        Button(localized("Use built-in client", locale: locale), action: actions.useBuiltInClient)
                            .buttonStyle(.link)
                            .font(AppTypography.caption)
                            .accessibilityIdentifier("googleCalendar.setup.useBuiltInClient")
                    }
                }
            }

            Text(localized("Google Desktop OAuth client ID", locale: locale))
                .font(AppTypography.labelStrong)
                .foregroundStyle(AppColors.textPrimary)
            TextField(
                localized("Client ID ending in .apps.googleusercontent.com", locale: locale),
                text: Binding(
                    get: { state.googleClientIDDraft },
                    set: { state.googleClientIDDraft = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("googleCalendar.setup.clientID")

            Text(localized("Client secret", locale: locale))
                .font(AppTypography.labelStrong)
                .foregroundStyle(AppColors.textPrimary)
            SecureField(
                localized("Required for Desktop app clients (starts with GOCSPX-)", locale: locale),
                text: Binding(
                    get: { state.googleClientSecretDraft },
                    set: { state.googleClientSecretDraft = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("googleCalendar.setup.clientSecret")

            HStack(spacing: 14) {
                Button {
                    isShowingSetupGuide = true
                } label: {
                    Label(localized("How do I get these?", locale: locale), systemImage: "questionmark.circle")
                }
                .buttonStyle(.link)
                .font(AppTypography.caption)
                .popover(isPresented: $isShowingSetupGuide, arrowEdge: .bottom) {
                    GoogleCalendarSetupGuide()
                }
                .accessibilityIdentifier("googleCalendar.setup.guide")
                Link(
                    localized("Open Google OAuth setup", locale: locale),
                    destination: URL(string: "https://console.cloud.google.com/auth/clients")!
                )
                .font(AppTypography.caption)
                Spacer()
                Button(localized("Save client ID", locale: locale)) {
                    actions.saveCustomClient(state.googleClientIDDraft, state.googleClientSecretDraft)
                }
                .buttonStyle(.bordered)
                .disabled(!isValidClientID(state.googleClientIDDraft) || state.isConnectingGoogle)
                .accessibilityIdentifier("googleCalendar.setup.saveClientID")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))
    }

    private func connectedBody(state: MeetingsFeatureState) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            wizardStatus(
                icon: "checkmark.circle.fill",
                color: AppColors.success,
                title: localized("Google Calendar is connected.", locale: locale),
                detail: state.googleAccountEmail.map {
                    String(format: localized("Signed in as %@.", locale: locale), $0)
                } ?? localized("Superduper Dictation can now load your upcoming events.", locale: locale)
            )
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: state.isLaunchAtLoginEnabled ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(state.isLaunchAtLoginEnabled ? AppColors.success : AppColors.textTertiary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(localized("Launch at Login", locale: locale))
                        .font(AppTypography.labelStrong)
                        .foregroundStyle(AppColors.textPrimary)
                    Text(localized("Required so Superduper Dictation is running when an armed meeting starts.", locale: locale))
                        .font(AppTypography.caption)
                        .foregroundStyle(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !state.isLaunchAtLoginEnabled {
                    Button(localized("Enable", locale: locale), action: actions.enableLaunchAtLogin)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("googleCalendar.setup.enableLaunchAtLogin")
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 10).fill(AppColors.contentBackground))
        }
    }

    @ViewBuilder
    private func footer(state: MeetingsFeatureState) -> some View {
        HStack {
            Spacer()
            if isHealthyConnection {
                Button(localized("Done", locale: locale)) {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("googleCalendar.setup.finish")
            } else if state.isConnectingGoogle {
                Button(localized("Cancel", locale: locale), action: actions.cancelConnect)
                    .accessibilityIdentifier("googleCalendar.setup.cancel")
            } else {
                Button(
                    state.googleNeedsReconnect
                        ? localized("Reconnect", locale: locale)
                        : localized("Sign in with Google", locale: locale),
                    action: actions.connect
                )
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!state.isGoogleConfigured)
                .accessibilityIdentifier("googleCalendar.setup.connect")
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

    private func isValidClientID(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(".apps.googleusercontent.com")
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
    let isGeneratingInsights: Bool
    let isDownloadingNotesModel: Bool
    let onRetryProcessing: () -> Void
    let onRegenerateInsights: () -> Void

    @AppStorage("onDeviceMeetingAIAllowed") private var meetingNotesEnabled = false

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
        // Notes are generated in the background after the page opens.
        .onChange(of: occurrence.summaryMarkdown) { _, _ in loadInsightDrafts() }
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
            if isDownloadingNotesModel {
                insightsStatus(localized("Downloading the on-device notes model…", locale: locale))
            } else if isGeneratingInsights {
                insightsStatus(localized("Writing notes on this Mac…", locale: locale))
            } else if !meetingNotesEnabled, (occurrence.summaryMarkdown ?? "").isEmpty {
                Text(localized("Get a summary, decisions, and action items written on this Mac. Turning this on downloads a 2.2 GB model once.", locale: locale))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
            }
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
                    title: meetingNotesEnabled
                        ? localized("Regenerate locally", locale: locale)
                        : localized("Turn on notes", locale: locale),
                    systemImage: "brain.head.profile",
                    action: onRegenerateInsights
                )
                .disabled(isGeneratingInsights || isDownloadingNotesModel || occurrence.transcript == nil)
            }
            .buttonStyle(.bordered)
        }
    }

    private func insightsStatus(_ message: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(message)
                .font(AppTypography.caption)
                .foregroundStyle(AppColors.textSecondary)
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
        loadInsightDrafts()
        speakerLabels = occurrence.speakerLabels
        saveError = nil
        audioPlayer.stop()
    }

    private func loadInsightDrafts() {
        summary = occurrence.summaryMarkdown ?? ""
        decisions = occurrence.decisions.joined(separator: "\n")
        actions = occurrence.actionItems
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
