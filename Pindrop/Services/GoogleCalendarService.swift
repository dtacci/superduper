//
//  GoogleCalendarService.swift
//  Pindrop
//
//  Created on 2026-08-25.
//

import AppKit
import CryptoKit
import Foundation
import Network
import Security
import UserNotifications

// MARK: - OAuth

struct GoogleOAuthConfiguration: Equatable, Sendable {
    let clientID: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL

    static func desktop(clientID: String) -> GoogleOAuthConfiguration {
        GoogleOAuthConfiguration(
            clientID: clientID,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!
        )
    }
}

struct GoogleOAuthToken: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date
    let scope: String?
}

protocol GoogleOAuthCredentialStoring: Sendable {
    func loadRefreshToken() throws -> String?
    func saveRefreshToken(_ token: String) throws
    func deleteRefreshToken() throws
}

final class GoogleOAuthKeychainStore: GoogleOAuthCredentialStoring, @unchecked Sendable {
    private let service: String
    private let account: String

    init(
        service: String = Bundle.main.bundleIdentifier ?? "tech.watzon.pindrop",
        account: String = "google-calendar-refresh-token"
    ) {
        self.service = service
        self.account = account
    }

    func loadRefreshToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw GoogleOAuthError.keychain(status)
        }
        return token
    }

    func saveRefreshToken(_ token: String) throws {
        try deleteRefreshToken()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw GoogleOAuthError.keychain(status) }
    }

    func deleteRefreshToken() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleOAuthError.keychain(status)
        }
    }
}

protocol GoogleOAuthTransporting: Sendable {
    func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthToken
    func refresh(
        _ refreshToken: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthToken
    func revoke(_ token: String, endpoint: URL) async throws
}

final class URLSessionGoogleOAuthTransport: GoogleOAuthTransporting, @unchecked Sendable {
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: TimeInterval
        let scope: String?
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func exchangeCode(
        _ code: String,
        verifier: String,
        redirectURI: URL,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthToken {
        try await tokenRequest(
            endpoint: configuration.tokenEndpoint,
            fields: [
                "client_id": configuration.clientID,
                "code": code,
                "code_verifier": verifier,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI.absoluteString
            ]
        )
    }

    func refresh(
        _ refreshToken: String,
        configuration: GoogleOAuthConfiguration
    ) async throws -> GoogleOAuthToken {
        try await tokenRequest(
            endpoint: configuration.tokenEndpoint,
            fields: [
                "client_id": configuration.clientID,
                "refresh_token": refreshToken,
                "grant_type": "refresh_token"
            ]
        )
    }

    func revoke(_ token: String, endpoint: URL) async throws {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData(["token": token])
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GoogleOAuthError.transport("Google rejected token revocation.")
        }
    }

    private func tokenRequest(endpoint: URL, fields: [String: String]) async throws -> GoogleOAuthToken {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "Unknown OAuth error"
            throw GoogleOAuthError.transport(detail)
        }
        let responseBody = try JSONDecoder().decode(TokenResponse.self, from: data)
        return GoogleOAuthToken(
            accessToken: responseBody.access_token,
            refreshToken: responseBody.refresh_token,
            expiresAt: Date().addingTimeInterval(responseBody.expires_in),
            scope: responseBody.scope
        )
    }

    private static func formData(_ fields: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = fields.sorted(by: { $0.key < $1.key }).map {
            URLQueryItem(name: $0.key, value: $0.value)
        }
        return components.percentEncodedQuery?.data(using: .utf8)
    }
}

protocol GoogleOAuthCallbackReceiving: AnyObject {
    func receiveCallback(
        authorizationURL: @escaping (_ redirectURI: URL) -> URL
    ) async throws -> URL
}

private final class OAuthCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var listener: NWListener?
    private var isComplete = false

    func install(_ continuation: CheckedContinuation<URL, Error>, listener: NWListener) {
        lock.withLock {
            self.continuation = continuation
            self.listener = listener
        }
    }

    func finish(_ result: Result<URL, Error>) {
        let continuation: CheckedContinuation<URL, Error>? = lock.withLock {
            guard !isComplete else { return nil }
            isComplete = true
            listener?.cancel()
            listener = nil
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

final class LoopbackGoogleOAuthReceiver: GoogleOAuthCallbackReceiving {
    private let openURL: (URL) -> Bool
    private var activeGate: OAuthCallbackGate?

    init(openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openURL = openURL
    }

    func receiveCallback(
        authorizationURL: @escaping (_ redirectURI: URL) -> URL
    ) async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let gate = OAuthCallbackGate()
        activeGate = gate

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation, listener: listener)
                listener.stateUpdateHandler = { [openURL] state in
                    switch state {
                    case .ready:
                        guard let port = listener.port,
                              let redirectURI = URL(string: "http://127.0.0.1:\(port.rawValue)/oauth/callback") else {
                            gate.finish(.failure(GoogleOAuthError.callback("Unable to create the loopback redirect.")))
                            return
                        }
                        let url = authorizationURL(redirectURI)
                        DispatchQueue.main.async {
                            if !openURL(url) {
                                gate.finish(.failure(GoogleOAuthError.callback("The system browser could not be opened.")))
                            }
                        }
                    case .failed(let error):
                        gate.finish(.failure(error))
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { connection in
                    connection.start(queue: .global(qos: .userInitiated))
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, error in
                        if let error {
                            gate.finish(.failure(error))
                            connection.cancel()
                            return
                        }
                        guard let data,
                              let request = String(data: data, encoding: .utf8),
                              let target = request.split(separator: "\r\n").first?.split(separator: " ").dropFirst().first,
                              let callback = URL(string: String(target), relativeTo: URL(string: "http://127.0.0.1"))?.absoluteURL else {
                            gate.finish(.failure(GoogleOAuthError.callback("The OAuth callback was malformed.")))
                            connection.cancel()
                            return
                        }
                        let body = "Pindrop is connected. You can close this window."
                        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                            connection.cancel()
                            gate.finish(.success(callback))
                        })
                    }
                }
                listener.start(queue: .global(qos: .userInitiated))
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }
}

enum GoogleOAuthError: Error, LocalizedError {
    case callback(String)
    case stateMismatch
    case authorizationDenied(String)
    case missingAuthorizationCode
    case transport(String)
    case keychain(OSStatus)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .callback(let detail): return "Google sign-in failed: \(detail)"
        case .stateMismatch: return "Google sign-in was rejected because its security state did not match."
        case .authorizationDenied(let detail): return "Google authorization was denied: \(detail)"
        case .missingAuthorizationCode: return "Google did not return an authorization code."
        case .transport(let detail): return "Google sign-in failed: \(detail)"
        case .keychain(let status): return "Google credentials could not be stored in Keychain (\(status))."
        case .notConnected: return "Connect Google Calendar first."
        }
    }
}

@MainActor
final class GoogleOAuthService {
    static let scopes = [
        "https://www.googleapis.com/auth/calendar.events.readonly",
        "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    ]

    private let configuration: GoogleOAuthConfiguration
    private let credentialStore: any GoogleOAuthCredentialStoring
    private let transport: any GoogleOAuthTransporting
    private let callbackReceiver: any GoogleOAuthCallbackReceiving
    private var accessToken: GoogleOAuthToken?

    init(
        configuration: GoogleOAuthConfiguration,
        credentialStore: any GoogleOAuthCredentialStoring = GoogleOAuthKeychainStore(),
        transport: any GoogleOAuthTransporting = URLSessionGoogleOAuthTransport(),
        callbackReceiver: any GoogleOAuthCallbackReceiving = LoopbackGoogleOAuthReceiver()
    ) {
        self.configuration = configuration
        self.credentialStore = credentialStore
        self.transport = transport
        self.callbackReceiver = callbackReceiver
    }

    var isConnected: Bool {
        (try? credentialStore.loadRefreshToken()) != nil
    }

    func connect() async throws {
        let state = Self.secureRandomBase64URL(byteCount: 32)
        let verifier = Self.secureRandomBase64URL(byteCount: 64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()

        var redirectURI: URL?
        let callback = try await callbackReceiver.receiveCallback { [configuration] redirect in
            redirectURI = redirect
            var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "client_id", value: configuration.clientID),
                URLQueryItem(name: "redirect_uri", value: redirect.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
                URLQueryItem(name: "access_type", value: "offline"),
                URLQueryItem(name: "prompt", value: "consent"),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256"),
                URLQueryItem(name: "state", value: state)
            ]
            return components.url!
        }

        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first(where: { $0.name == name })?.value }
        guard value("state") == state else { throw GoogleOAuthError.stateMismatch }
        if let error = value("error") {
            throw GoogleOAuthError.authorizationDenied(value("error_description") ?? error)
        }
        guard let code = value("code"), let redirectURI else {
            throw GoogleOAuthError.missingAuthorizationCode
        }
        let token = try await transport.exchangeCode(
            code,
            verifier: verifier,
            redirectURI: redirectURI,
            configuration: configuration
        )
        guard let refreshToken = token.refreshToken else {
            throw GoogleOAuthError.transport("Google did not issue a refresh token.")
        }
        try credentialStore.saveRefreshToken(refreshToken)
        accessToken = token
    }

    func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expiresAt.timeIntervalSinceNow > 60 {
            return accessToken.accessToken
        }
        guard let refreshToken = try credentialStore.loadRefreshToken() else {
            throw GoogleOAuthError.notConnected
        }
        let refreshed = try await transport.refresh(refreshToken, configuration: configuration)
        accessToken = GoogleOAuthToken(
            accessToken: refreshed.accessToken,
            refreshToken: refreshToken,
            expiresAt: refreshed.expiresAt,
            scope: refreshed.scope
        )
        return refreshed.accessToken
    }

    func disconnect() async throws {
        let refreshToken = try credentialStore.loadRefreshToken()
        let token = refreshToken ?? accessToken?.accessToken
        if let token {
            try? await transport.revoke(token, endpoint: configuration.revocationEndpoint)
        }
        accessToken = nil
        try credentialStore.deleteRefreshToken()
    }

    private static func secureRandomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Calendar API

struct GoogleCalendar: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let summary: String
    let primary: Bool?
    let selected: Bool?
}

struct GoogleCalendarEvent: Codable, Equatable, Sendable, Identifiable {
    struct DateValue: Codable, Equatable, Sendable {
        let dateTime: String?
        let date: String?
        let timeZone: String?

        var resolvedDate: Date? {
            if let dateTime { return GoogleCalendarDateParser.date(from: dateTime) }
            if let date { return GoogleCalendarDateParser.day(from: date, timeZone: timeZone) }
            return nil
        }
    }

    struct ConferenceData: Codable, Equatable, Sendable {
        struct EntryPoint: Codable, Equatable, Sendable {
            let entryPointType: String?
            let uri: String?
        }
        let entryPoints: [EntryPoint]?
    }

    let id: String
    let recurringEventId: String?
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let hangoutLink: String?
    let conferenceData: ConferenceData?
    let start: DateValue
    let end: DateValue
    let updated: String?
}

private enum GoogleCalendarDateParser {
    static let internetFormatter = ISO8601DateFormatter()

    static func date(from value: String) -> Date? {
        internetFormatter.date(from: value)
    }

    static func day(from value: String, timeZone: String?) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone.flatMap(TimeZone.init(identifier:)) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }
}

enum GoogleCalendarAPIError: Error, LocalizedError {
    case http(status: Int, detail: String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let detail): return "Google Calendar returned \(status): \(detail)"
        case .invalidResponse: return "Google Calendar returned an invalid response."
        }
    }
}

protocol GoogleCalendarAPITransporting: Sendable {
    func get(path: String, queryItems: [URLQueryItem], accessToken: String) async throws -> Data
}

final class URLSessionGoogleCalendarTransport: GoogleCalendarAPITransporting, @unchecked Sendable {
    private let session: URLSession
    private let baseURL: URL

    init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://www.googleapis.com/calendar/v3/")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    func get(path: String, queryItems: [URLQueryItem], accessToken: String) async throws -> Data {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let prefix = components.percentEncodedPath.hasSuffix("/")
            ? components.percentEncodedPath
            : components.percentEncodedPath + "/"
        components.percentEncodedPath = prefix + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw GoogleCalendarAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoogleCalendarAPIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleCalendarAPIError.http(
                status: http.statusCode,
                detail: String(data: data, encoding: .utf8) ?? "Unknown error"
            )
        }
        return data
    }
}

struct GoogleCalendarSyncResult: Equatable, Sendable {
    let events: [GoogleCalendarEvent]
    let nextSyncToken: String?
}

@MainActor
@Observable
final class MeetingsFeatureState {
    var isGoogleConfigured = false
    var isGoogleConnected = false
    var isLaunchAtLoginEnabled = false
    var isRefreshing = false
    var errorMessage: String?
    var readinessMessage: String?
    var calendarEvents: [MeetingOccurrenceSnapshot] = []
    var armedOccurrenceIDsByIdentity: [String: UUID] = [:]

    func replaceEvents(_ events: [MeetingOccurrenceSnapshot]) {
        calendarEvents = events.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.title < rhs.title }
            return lhs.start < rhs.start
        }
    }
}

@MainActor
final class GoogleCalendarClient {
    private struct CalendarListResponse: Decodable {
        let items: [GoogleCalendar]?
        let nextPageToken: String?
    }
    private struct EventListResponse: Decodable {
        let items: [GoogleCalendarEvent]?
        let nextPageToken: String?
        let nextSyncToken: String?
    }

    private let oauth: GoogleOAuthService
    private let transport: any GoogleCalendarAPITransporting

    init(
        oauth: GoogleOAuthService,
        transport: any GoogleCalendarAPITransporting = URLSessionGoogleCalendarTransport()
    ) {
        self.oauth = oauth
        self.transport = transport
    }

    func calendars() async throws -> [GoogleCalendar] {
        let token = try await oauth.validAccessToken()
        var pageToken: String?
        var calendars: [GoogleCalendar] = []
        repeat {
            let query = pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? []
            let data = try await transport.get(path: "users/me/calendarList", queryItems: query, accessToken: token)
            let page = try JSONDecoder().decode(CalendarListResponse.self, from: data)
            calendars.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
        } while pageToken != nil
        return calendars
    }

    func events(
        calendarID: String,
        from start: Date,
        through end: Date,
        syncToken: String? = nil
    ) async throws -> GoogleCalendarSyncResult {
        let token = try await oauth.validAccessToken()
        var pageToken: String?
        var allEvents: [GoogleCalendarEvent] = []
        var nextSyncToken: String?
        repeat {
            var query: [URLQueryItem] = [
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "singleEvents", value: "true"),
                URLQueryItem(name: "maxResults", value: "2500")
            ]
            if let syncToken {
                query.append(URLQueryItem(name: "syncToken", value: syncToken))
            } else {
                query.append(URLQueryItem(name: "timeMin", value: ISO8601DateFormatter().string(from: start)))
                query.append(URLQueryItem(name: "timeMax", value: ISO8601DateFormatter().string(from: end)))
                query.append(URLQueryItem(name: "orderBy", value: "startTime"))
            }
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var pathSegmentAllowed = CharacterSet.alphanumerics
            pathSegmentAllowed.insert(charactersIn: "-._~")
            let encodedCalendarID = calendarID.addingPercentEncoding(
                withAllowedCharacters: pathSegmentAllowed
            ) ?? calendarID
            let data = try await transport.get(
                path: "calendars/\(encodedCalendarID)/events",
                queryItems: query,
                accessToken: token
            )
            let page = try JSONDecoder().decode(EventListResponse.self, from: data)
            allEvents.append(contentsOf: page.items ?? [])
            pageToken = page.nextPageToken
            nextSyncToken = page.nextSyncToken ?? nextSyncToken
        } while pageToken != nil
        return GoogleCalendarSyncResult(events: allEvents, nextSyncToken: nextSyncToken)
    }

    func eventsRecoveringInvalidSyncToken(
        calendarID: String,
        from start: Date,
        through end: Date,
        syncToken: String?
    ) async throws -> GoogleCalendarSyncResult {
        do {
            return try await events(calendarID: calendarID, from: start, through: end, syncToken: syncToken)
        } catch GoogleCalendarAPIError.http(let status, _) where status == 410 {
            return try await events(calendarID: calendarID, from: start, through: end, syncToken: nil)
        }
    }
}

enum MeetingJoinURLResolver {
    static func resolve(from event: GoogleCalendarEvent) -> URL? {
        if let hangoutLink = event.hangoutLink,
           let url = URL(string: hangoutLink), isRecognizedMeetingURL(url) {
            return url
        }
        if let entry = event.conferenceData?.entryPoints?.first(where: {
            $0.entryPointType == "video" && $0.uri.flatMap(URL.init(string:)).map(isRecognizedMeetingURL) == true
        }), let uri = entry.uri {
            return URL(string: uri)
        }
        return firstRecognizedURL(in: [event.location, event.description].compactMap { $0 }.joined(separator: "\n"))
    }

    static func snapshot(event: GoogleCalendarEvent, calendarID: String) -> MeetingOccurrenceSnapshot? {
        guard let start = event.start.resolvedDate else { return nil }
        let rawJSON = try? JSONEncoder().encode(event)
        return MeetingOccurrenceSnapshot(
            id: event.id,
            provider: "google",
            calendarID: calendarID,
            eventID: event.id,
            recurringEventID: event.recurringEventId,
            title: event.summary?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Untitled meeting",
            start: start,
            end: event.end.resolvedDate,
            joinURL: resolve(from: event),
            rawSnapshotJSON: rawJSON.flatMap { String(data: $0, encoding: .utf8) }
        )
    }

    private static func firstRecognizedURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.matches(in: text, range: range)
            .compactMap(\.url)
            .first(where: isRecognizedMeetingURL)
    }

    private static func isRecognizedMeetingURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "meet.google.com"
            || host == "teams.microsoft.com"
            || host == "zoom.us"
            || host.hasSuffix(".zoom.us")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Scheduling

protocol MeetingClock: Sendable {
    var now: Date { get }
    func sleep(until date: Date) async throws
}

struct SystemMeetingClock: MeetingClock {
    var now: Date { Date() }
    func sleep(until date: Date) async throws {
        let delay = date.timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
    }
}

protocol MeetingURLStarting: Sendable {
    func open(_ url: URL) async -> Bool
}

struct SystemMeetingURLStarter: MeetingURLStarting {
    func open(_ url: URL) async -> Bool {
        await MainActor.run { NSWorkspace.shared.open(url) }
    }
}

protocol MeetingNotifying: Sendable {
    func notify(title: String, body: String) async
}

struct LogMeetingNotifier: MeetingNotifying {
    func notify(title: String, body: String) async {
        Log.app.info("Meeting notification: \(title) — \(body)")
    }
}

final class SystemMeetingNotifier: MeetingNotifying, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notify(title: String, body: String) async {
        do {
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                    Log.app.warning("Meeting notification permission was declined")
                    return
                }
            } else if settings.authorizationStatus != .authorized
                        && settings.authorizationStatus != .provisional {
                Log.app.warning("Meeting notification skipped because permission is unavailable")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "meeting-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try await center.add(request)
        } catch {
            Log.app.error("Failed to deliver meeting notification: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class CalendarMeetingScheduler {
    enum ArmError: Error, LocalizedError {
        case launchAtLoginRequired
        case prerequisites(String)

        var errorDescription: String? {
            switch self {
            case .launchAtLoginRequired:
                return "Enable Launch at Login before arming scheduled meetings."
            case .prerequisites(let detail):
                return detail
            }
        }
    }

    private let meetingStore: MeetingStore
    private let clock: any MeetingClock
    private let urlStarter: any MeetingURLStarting
    private let notifier: any MeetingNotifying
    private let launchAtLoginEnabled: () -> Bool
    private let readiness: () async -> MeetingPreflightReport
    private let isBusy: () -> Bool
    private let startCapture: (UUID) async throws -> Void
    private let stopCapture: (UUID) async throws -> Void
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var ownedOccurrenceID: UUID?

    init(
        meetingStore: MeetingStore,
        clock: any MeetingClock = SystemMeetingClock(),
        urlStarter: any MeetingURLStarting = SystemMeetingURLStarter(),
        notifier: any MeetingNotifying = LogMeetingNotifier(),
        launchAtLoginEnabled: @escaping () -> Bool,
        readiness: @escaping () async -> MeetingPreflightReport,
        isBusy: @escaping () -> Bool,
        startCapture: @escaping (UUID) async throws -> Void,
        stopCapture: @escaping (UUID) async throws -> Void
    ) {
        self.meetingStore = meetingStore
        self.clock = clock
        self.urlStarter = urlStarter
        self.notifier = notifier
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.readiness = readiness
        self.isBusy = isBusy
        self.startCapture = startCapture
        self.stopCapture = stopCapture
    }

    @discardableResult
    func arm(_ snapshot: MeetingOccurrenceSnapshot) async throws -> MeetingOccurrence {
        guard launchAtLoginEnabled() else { throw ArmError.launchAtLoginRequired }
        let report = await readiness()
        if let issue = report.primaryIssue { throw ArmError.prerequisites(issue.message) }
        let occurrence = try meetingStore.arm(snapshot)
        schedule(occurrence)
        return occurrence
    }

    func disarm(id: UUID) throws {
        tasks[id]?.cancel()
        tasks[id] = nil
        try meetingStore.disarm(id: id)
    }

    func restoreArmedSchedules() async throws {
        let now = clock.now
        let armed = try meetingStore.fetchArmedOccurrences(
            from: .distantPast,
            through: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
        for occurrence in armed {
            if occurrence.scheduledStart < now.addingTimeInterval(-60) {
                try meetingStore.transition(
                    id: occurrence.id,
                    to: .missed,
                    message: "Pindrop was not running at the scheduled start."
                )
                await notifier.notify(
                    title: "Meeting missed",
                    body: "Pindrop was closed or the Mac was asleep at the scheduled start."
                )
            } else {
                schedule(occurrence)
            }
        }
    }

    func eventWasDeleted(id: UUID) async {
        tasks[id]?.cancel()
        tasks[id] = nil

        let occurrence = try? meetingStore.occurrence(id: id)
        if ownedOccurrenceID == id || occurrence?.state == .recording {
            ownedOccurrenceID = nil
            do {
                try await stopCapture(id)
                await notifier.notify(
                    title: "Calendar event removed",
                    body: "The active recording was stopped and sent to transcription."
                )
            } catch {
                try? meetingStore.markFailedPreservingWorkspace(
                    id: id,
                    message: error.localizedDescription
                )
                await notifier.notify(
                    title: "Meeting recording failed",
                    body: error.localizedDescription
                )
            }
            return
        }

        try? meetingStore.disarm(id: id, canceled: true, message: "The calendar event was canceled or deleted.")
        await notifier.notify(title: "Meeting canceled", body: "An armed Google Calendar event was removed.")
    }

    func eventWasUpdated(_ snapshot: MeetingOccurrenceSnapshot) throws {
        let occurrence = try meetingStore.arm(snapshot)
        // A periodic sync must never replace an active meeting's end-time owner
        // with a fresh start-time task. Doing so after the start is more than a
        // minute in the past would mark it missed and lose automatic stop.
        if ownedOccurrenceID == occurrence.id || occurrence.state == .recording {
            adoptActiveCapture(id: occurrence.id, scheduledEnd: occurrence.scheduledEnd)
        } else if occurrence.state == .scheduled || occurrence.state == .preparing {
            schedule(occurrence)
        }
    }

    /// Transfers an already-running, user-started capture to the calendar owner.
    /// It never opens the URL or starts another recorder; it only owns the scheduled stop.
    func adoptActiveCapture(id: UUID, scheduledEnd: Date?) {
        tasks[id]?.cancel()
        ownedOccurrenceID = id
        guard let scheduledEnd else { return }
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(until: scheduledEnd)
                try Task.checkCancellation()
                guard self.ownedOccurrenceID == id else { return }
                try await self.stopCapture(id)
                self.ownedOccurrenceID = nil
            } catch is CancellationError {
                return
            } catch {
                try? self.meetingStore.markFailedPreservingWorkspace(
                    id: id,
                    message: error.localizedDescription
                )
                await self.notifier.notify(
                    title: "Meeting recording failed",
                    body: error.localizedDescription
                )
            }
        }
    }

    private func schedule(_ occurrence: MeetingOccurrence) {
        tasks[occurrence.id]?.cancel()
        let id = occurrence.id
        let start = occurrence.scheduledStart
        let end = occurrence.scheduledEnd
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.clock.sleep(until: start)
                try Task.checkCancellation()
                let lateness = self.clock.now.timeIntervalSince(start)
                guard lateness <= 60, !self.isBusy() else {
                    try? self.meetingStore.transition(
                        id: id,
                        to: .missed,
                        message: lateness > 60 ? "Pindrop was not running at the scheduled start." : "Another recording was active."
                    )
                    await self.notifier.notify(
                        title: "Meeting missed",
                        body: "Pindrop did not interrupt the active recording or start late."
                    )
                    return
                }
                let report = await self.readiness()
                guard report.isReady else {
                    try? self.meetingStore.transition(id: id, to: .missed, message: report.primaryIssue?.message)
                    await self.notifier.notify(title: "Meeting could not start", body: report.primaryIssue?.message ?? "Prerequisites are missing.")
                    return
                }
                if let url = try self.meetingStore.occurrence(id: id)?.joinURL {
                    _ = await self.urlStarter.open(url)
                }
                try await self.startCapture(id)
                self.ownedOccurrenceID = id
                if let end {
                    try await self.clock.sleep(until: end)
                    try Task.checkCancellation()
                    if self.ownedOccurrenceID == id {
                        try await self.stopCapture(id)
                        self.ownedOccurrenceID = nil
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                try? self.meetingStore.markFailedPreservingWorkspace(id: id, message: error.localizedDescription)
                await self.notifier.notify(title: "Meeting recording failed", body: error.localizedDescription)
            }
        }
    }
}
