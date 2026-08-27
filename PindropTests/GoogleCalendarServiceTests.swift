//
//  GoogleCalendarServiceTests.swift
//  PindropTests
//
//  Created on 2026-08-25.
//

import Foundation
import SwiftData
import Testing
@testable import Pindrop

@MainActor
@Suite
struct GoogleCalendarServiceTests {
    @Test func oauthUsesPKCEStateLoopbackAndNarrowReadOnlyScopes() async throws {
        let credentials = OAuthCredentialMemoryStore()
        let transport = OAuthTransportMock()
        let callback = OAuthCallbackMock()
        let sut = GoogleOAuthService(
            configuration: .desktop(clientID: "desktop-client"),
            credentialStore: credentials,
            transport: transport,
            callbackReceiver: callback
        )

        try await sut.connect()

        let authorizationURL = try #require(callback.authorizationURL)
        let query = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { query.first { $0.name == key }?.value }
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge")?.isEmpty == false)
        #expect(value("state")?.isEmpty == false)
        #expect(value("redirect_uri")?.hasPrefix("http://127.0.0.1:") == true)
        #expect(Set(value("scope")?.split(separator: " ").map(String.init) ?? []) == Set(GoogleOAuthService.scopes))
        #expect(GoogleOAuthService.scopes == [
            "https://www.googleapis.com/auth/calendar.events.readonly",
            "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
        ])
        #expect(transport.exchangeVerifier?.isEmpty == false)
        #expect(try credentials.loadRefreshToken() == "refresh")
        #expect(sut.isConnected)
    }

    @Test func oauthRejectsMismatchedCSRFStateBeforeTokenExchange() async {
        let transport = OAuthTransportMock()
        let callback = OAuthCallbackMock(returnMismatchedState: true)
        let sut = GoogleOAuthService(
            configuration: .desktop(clientID: "desktop-client"),
            credentialStore: OAuthCredentialMemoryStore(),
            transport: transport,
            callbackReceiver: callback
        )

        await #expect(throws: GoogleOAuthError.self) { try await sut.connect() }
        #expect(transport.exchangeVerifier == nil)
    }

    @Test func joinURLResolutionUsesDocumentedPriorityAndRecognizedProviders() throws {
        let event = makeEvent(
            hangoutLink: "https://meet.google.com/abc-defg-hij",
            conferenceURL: "https://zoom.us/j/123",
            location: "Fallback https://teams.microsoft.com/l/meetup-join/456"
        )
        #expect(MeetingJoinURLResolver.resolve(from: event)?.host == "meet.google.com")

        let conferenceOnly = makeEvent(
            hangoutLink: nil,
            conferenceURL: "https://acme.zoom.us/j/123",
            location: "https://teams.microsoft.com/l/meetup-join/456"
        )
        #expect(MeetingJoinURLResolver.resolve(from: conferenceOnly)?.host == "acme.zoom.us")

        let embedded = makeEvent(
            hangoutLink: nil,
            conferenceURL: nil,
            location: "Join at https://teams.microsoft.com/l/meetup-join/456"
        )
        #expect(MeetingJoinURLResolver.resolve(from: embedded)?.host == "teams.microsoft.com")
    }

    @Test func snapshotKeepsOneOccurrenceIdentityForRecurringEvent() throws {
        let event = makeEvent(recurringEventID: "series-1")
        let snapshot = try #require(MeetingJoinURLResolver.snapshot(event: event, calendarID: "primary"))
        #expect(snapshot.persistentIdentity == "google:primary:event-1")
        #expect(snapshot.recurringEventID == "series-1")
        #expect(snapshot.title == "Planning")
    }

    @Test func calendarAndEventPaginationCarryPageTokensAndReturnSyncToken() async throws {
        let transport = CalendarAPITransportMock(results: [
            .success(Data(#"{"items":[{"id":"one","summary":"One","primary":true}],"nextPageToken":"cal-next"}"#.utf8)),
            .success(Data(#"{"items":[{"id":"two","summary":"Two","selected":true}]}"#.utf8)),
            .success(Data(#"{"items":[],"nextPageToken":"event-next"}"#.utf8)),
            .success(Data(#"{"items":[],"nextSyncToken":"sync-2"}"#.utf8))
        ])
        let sut = makeCalendarClient(transport: transport)

        let calendars = try await sut.calendars()
        let result = try await sut.events(
            calendarID: "primary/calendar",
            from: Date(timeIntervalSince1970: 100),
            through: Date(timeIntervalSince1970: 200)
        )

        #expect(calendars.map(\.id) == ["one", "two"])
        #expect(result.nextSyncToken == "sync-2")
        #expect(transport.calls.count == 4)
        #expect(transport.calls[1].queryValue("pageToken") == "cal-next")
        #expect(transport.calls[3].queryValue("pageToken") == "event-next")
        #expect(transport.calls[2].queryValue("timeMin") != nil)
        #expect(transport.calls[2].queryValue("orderBy") == "startTime")
        #expect(transport.calls[2].path.contains("primary%2Fcalendar"))
    }

    @Test func expiredSyncTokenRetriesAsAFullWindowedSync() async throws {
        let transport = CalendarAPITransportMock(results: [
            .failure(GoogleCalendarAPIError.http(status: 410, detail: "Gone")),
            .success(Data(#"{"items":[],"nextSyncToken":"fresh"}"#.utf8))
        ])
        let sut = makeCalendarClient(transport: transport)

        let result = try await sut.eventsRecoveringInvalidSyncToken(
            calendarID: "primary",
            from: Date(timeIntervalSince1970: 100),
            through: Date(timeIntervalSince1970: 200),
            syncToken: "expired"
        )

        #expect(result.nextSyncToken == "fresh")
        #expect(transport.calls[0].queryValue("syncToken") == "expired")
        #expect(transport.calls[0].queryValue("timeMin") == nil)
        #expect(transport.calls[1].queryValue("syncToken") == nil)
        #expect(transport.calls[1].queryValue("timeMin") != nil)
    }

    @Test func restoreMarksStartsMissedWhilePindropWasClosedAndNotifies() async throws {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let now = Date(timeIntervalSince1970: 10_000)
        let media = CalendarTestMediaLibrary(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("calendar-scheduler-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: media.root) }
        let store = MeetingStore(modelContext: ModelContext(container), mediaLibrary: media)
        let occurrence = try store.arm(MeetingOccurrenceSnapshot(
            id: "past",
            provider: "google",
            calendarID: "primary",
            eventID: "past",
            recurringEventID: nil,
            title: "Past meeting",
            start: now.addingTimeInterval(-120),
            end: now.addingTimeInterval(600),
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            rawSnapshotJSON: nil
        ))
        let notifier = MeetingNotifierSpy()
        let sut = CalendarMeetingScheduler(
            meetingStore: store,
            clock: StaticMeetingClock(now: now),
            notifier: notifier,
            launchAtLoginEnabled: { true },
            readiness: { MeetingPreflightReport(issues: []) },
            isBusy: { false },
            startCapture: { _ in },
            stopCapture: { _ in }
        )

        try await sut.restoreArmedSchedules()

        let fetched = try store.occurrence(id: occurrence.id)
        let restored = try #require(fetched)
        #expect(restored.state == .missed)
        #expect(!restored.isArmed)
        #expect(await notifier.titles == ["Meeting missed"])
    }

    @Test func schedulerAdoptsActiveCaptureAndStopsAtCalendarEndWithoutRestarting() async throws {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let now = Date(timeIntervalSince1970: 20_000)
        let media = CalendarTestMediaLibrary(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("calendar-adoption-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: media.root) }
        let store = MeetingStore(modelContext: ModelContext(container), mediaLibrary: media)
        let occurrence = try store.arm(MeetingOccurrenceSnapshot(
            id: "active",
            provider: "google",
            calendarID: "primary",
            eventID: "active",
            recurringEventID: nil,
            title: "Active call",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(600),
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            rawSnapshotJSON: nil
        ))
        let calls = MeetingCaptureCallSpy()
        let sut = CalendarMeetingScheduler(
            meetingStore: store,
            clock: StaticMeetingClock(now: now),
            launchAtLoginEnabled: { true },
            readiness: { MeetingPreflightReport(issues: []) },
            isBusy: { false },
            startCapture: { id in await calls.started(id) },
            stopCapture: { id in await calls.stopped(id) }
        )

        sut.adoptActiveCapture(id: occurrence.id, scheduledEnd: now.addingTimeInterval(600))

        for _ in 0..<20 {
            if !(await calls.stoppedIDs).isEmpty { break }
            await Task.yield()
        }
        #expect(await calls.startedIDs.isEmpty)
        #expect(await calls.stoppedIDs == [occurrence.id])
    }

    @Test func calendarRefreshMovesActiveCaptureStopDeadlineWithoutRestarting() async throws {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let now = Date(timeIntervalSince1970: 30_000)
        let media = CalendarTestMediaLibrary(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("calendar-active-refresh-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: media.root) }
        let store = MeetingStore(modelContext: ModelContext(container), mediaLibrary: media)
        let original = MeetingOccurrenceSnapshot(
            id: "active-refresh",
            provider: "google",
            calendarID: "primary",
            eventID: "active-refresh",
            recurringEventID: nil,
            title: "Active refreshed call",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(600),
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            rawSnapshotJSON: nil
        )
        let occurrence = try store.arm(original)
        try store.transition(id: occurrence.id, to: .preparing)
        try store.transition(id: occurrence.id, to: .recording)
        let clock = ControllableMeetingClock(now: now)
        let calls = MeetingCaptureCallSpy()
        let sut = CalendarMeetingScheduler(
            meetingStore: store,
            clock: clock,
            launchAtLoginEnabled: { true },
            readiness: { MeetingPreflightReport(issues: []) },
            isBusy: { false },
            startCapture: { id in await calls.started(id) },
            stopCapture: { id in await calls.stopped(id) }
        )
        sut.adoptActiveCapture(id: occurrence.id, scheduledEnd: original.end)

        let updatedEnd = now.addingTimeInterval(1_200)
        let updated = MeetingOccurrenceSnapshot(
            id: original.id,
            provider: original.provider,
            calendarID: original.calendarID,
            eventID: original.eventID,
            recurringEventID: original.recurringEventID,
            title: original.title,
            start: original.start,
            end: updatedEnd,
            joinURL: original.joinURL,
            rawSnapshotJSON: nil
        )
        try sut.eventWasUpdated(updated)

        clock.advance(to: now.addingTimeInterval(601))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await calls.stoppedIDs.isEmpty)

        clock.advance(to: updatedEnd.addingTimeInterval(1))
        for _ in 0..<20 {
            if !(await calls.stoppedIDs).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await calls.startedIDs.isEmpty)
        #expect(await calls.stoppedIDs == [occurrence.id])
    }

    @Test func deletingActiveCalendarEventStopsAndProcessesCaptureInsteadOfLosingDeadline() async throws {
        let schema = Schema(versionedSchema: TranscriptionRecordSchemaV13.self)
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let now = Date(timeIntervalSince1970: 40_000)
        let media = CalendarTestMediaLibrary(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("calendar-active-deletion-\(UUID().uuidString)", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: media.root) }
        let store = MeetingStore(modelContext: ModelContext(container), mediaLibrary: media)
        let occurrence = try store.arm(MeetingOccurrenceSnapshot(
            id: "deleted-active",
            provider: "google",
            calendarID: "primary",
            eventID: "deleted-active",
            recurringEventID: nil,
            title: "Deleted active call",
            start: now.addingTimeInterval(-60),
            end: now.addingTimeInterval(600),
            joinURL: URL(string: "https://meet.google.com/abc-defg-hij"),
            rawSnapshotJSON: nil
        ))
        try store.transition(id: occurrence.id, to: .preparing)
        try store.transition(id: occurrence.id, to: .recording)
        let calls = MeetingCaptureCallSpy()
        let notifier = MeetingNotifierSpy()
        let sut = CalendarMeetingScheduler(
            meetingStore: store,
            clock: StaticMeetingClock(now: now),
            notifier: notifier,
            launchAtLoginEnabled: { true },
            readiness: { MeetingPreflightReport(issues: []) },
            isBusy: { false },
            startCapture: { id in await calls.started(id) },
            stopCapture: { id in
                await calls.stopped(id)
                try store.transition(id: id, to: .processing)
                try store.transition(id: id, to: .ready)
            }
        )
        sut.adoptActiveCapture(id: occurrence.id, scheduledEnd: now.addingTimeInterval(600))

        await sut.eventWasDeleted(id: occurrence.id)

        #expect(await calls.startedIDs.isEmpty)
        #expect(await calls.stoppedIDs == [occurrence.id])
        #expect(try store.occurrence(id: occurrence.id)?.state == .ready)
        #expect(try store.occurrence(id: occurrence.id)?.isArmed == false)
        #expect(await notifier.titles == ["Calendar event removed"])
    }

    private func makeCalendarClient(transport: CalendarAPITransportMock) -> GoogleCalendarClient {
        let credentials = OAuthCredentialMemoryStore()
        try! credentials.saveRefreshToken("refresh")
        let oauth = GoogleOAuthService(
            configuration: .desktop(clientID: "desktop-client"),
            credentialStore: credentials,
            transport: OAuthTransportMock(),
            callbackReceiver: OAuthCallbackMock()
        )
        return GoogleCalendarClient(oauth: oauth, transport: transport)
    }

    private func makeEvent(
        recurringEventID: String? = nil,
        hangoutLink: String? = nil,
        conferenceURL: String? = nil,
        location: String? = nil
    ) -> GoogleCalendarEvent {
        GoogleCalendarEvent(
            id: "event-1",
            recurringEventId: recurringEventID,
            status: "confirmed",
            summary: "Planning",
            description: nil,
            location: location,
            hangoutLink: hangoutLink,
            conferenceData: conferenceURL.map {
                .init(entryPoints: [.init(entryPointType: "video", uri: $0)])
            },
            start: .init(dateTime: "2026-09-01T10:00:00Z", date: nil, timeZone: nil),
            end: .init(dateTime: "2026-09-01T10:30:00Z", date: nil, timeZone: nil),
            updated: nil
        )
    }
}

private final class CalendarAPITransportMock: GoogleCalendarAPITransporting, @unchecked Sendable {
    struct Call {
        let path: String
        let queryItems: [URLQueryItem]
        func queryValue(_ name: String) -> String? {
            queryItems.first { $0.name == name }?.value
        }
    }

    private var results: [Result<Data, Error>]
    private(set) var calls: [Call] = []

    init(results: [Result<Data, Error>]) { self.results = results }

    func get(path: String, queryItems: [URLQueryItem], accessToken: String) async throws -> Data {
        calls.append(Call(path: path, queryItems: queryItems))
        return try results.removeFirst().get()
    }
}

private struct StaticMeetingClock: MeetingClock {
    let now: Date
    func sleep(until date: Date) async throws {}
}

private final class ControllableMeetingClock: MeetingClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(now: Date) { current = now }

    var now: Date {
        lock.withLock { current }
    }

    func advance(to date: Date) {
        lock.withLock { current = date }
    }

    func sleep(until date: Date) async throws {
        while now < date {
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor MeetingNotifierSpy: MeetingNotifying {
    private(set) var titles: [String] = []
    func notify(title: String, body: String) async { titles.append(title) }
}

private actor MeetingCaptureCallSpy {
    private(set) var startedIDs: [UUID] = []
    private(set) var stoppedIDs: [UUID] = []

    func started(_ id: UUID) { startedIDs.append(id) }
    func stopped(_ id: UUID) { stoppedIDs.append(id) }
}

private final class CalendarTestMediaLibrary: MediaLibraryManaging {
    let root: URL
    init(root: URL) { self.root = root }

    func makeJobDirectory(for jobID: UUID) throws -> URL {
        let url = root.appendingPathComponent(jobID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func importLocalFile(at sourceURL: URL, jobID: UUID) async throws -> ManagedMediaAsset {
        fatalError("Unused by calendar tests")
    }
    func storeRecordedAudio(
        _ audioData: Data,
        jobID: UUID,
        displayName: String,
        sourceKind: MediaSourceKind
    ) throws -> ManagedMediaAsset { fatalError("Unused by calendar tests") }
    func finalizeDownloadedAsset(
        in directoryURL: URL,
        sourceURL: String,
        suggestedTitle: String?
    ) async throws -> ManagedMediaAsset { fatalError("Unused by calendar tests") }
}

private final class OAuthCredentialMemoryStore: GoogleOAuthCredentialStoring, @unchecked Sendable {
    private var token: String?
    func loadRefreshToken() throws -> String? { token }
    func saveRefreshToken(_ token: String) throws { self.token = token }
    func deleteRefreshToken() throws { token = nil }
}

private final class OAuthTransportMock: GoogleOAuthTransporting, @unchecked Sendable {
    var exchangeVerifier: String?

    func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthToken {
        exchangeVerifier = verifier
        return GoogleOAuthToken(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            scope: nil
        )
    }

    func refresh(
        _ refreshToken: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthToken {
        GoogleOAuthToken(accessToken: "refreshed", refreshToken: nil, expiresAt: Date().addingTimeInterval(3_600), scope: nil)
    }

    func revoke(_ token: String, endpoint: URL) async throws {}
}

private final class OAuthCallbackMock: GoogleOAuthCallbackReceiving {
    private let returnMismatchedState: Bool
    var authorizationURL: URL?

    init(returnMismatchedState: Bool = false) {
        self.returnMismatchedState = returnMismatchedState
    }

    func receiveCallback(
        authorizationURL: @escaping (URL) -> URL
    ) async throws -> URL {
        let redirect = URL(string: "http://127.0.0.1:54321/oauth/callback")!
        let authorization = authorizationURL(redirect)
        self.authorizationURL = authorization
        let state = URLComponents(url: authorization, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "state" }?.value ?? ""
        return URL(string: "\(redirect.absoluteString)?code=code&state=\(returnMismatchedState ? "wrong" : state)")!
    }
}
