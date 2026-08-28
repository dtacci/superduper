//
//  AppCoordinator.swift
//  Pindrop
//
//  Created on 2026-01-25.
//

import Foundation
import SwiftUI
import SwiftData
import Combine
import AVFoundation
import AppKit
import os.log

private final class EventTapRunLoopThread: Thread {

    private let readinessSemaphore = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private var runLoop: CFRunLoop?
    private let threadExitGroup = DispatchGroup()
    private var hasStarted = false
    private var hasExited = false
    private var stopRequested = false
    private let keepAlivePort = Port()

    init(name: String) {
        super.init()
        self.name = name
        self.qualityOfService = .userInteractive
        threadExitGroup.enter()
    }

    override func main() {
        let currentRunLoop = CFRunLoopGetCurrent()

        stateLock.lock()
        runLoop = currentRunLoop
        stateLock.unlock()

        RunLoop.current.add(keepAlivePort, forMode: .default)
        readinessSemaphore.signal()

        while !isCancelled {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }

        stateLock.lock()
        runLoop = nil
        hasExited = true
        stateLock.unlock()
        threadExitGroup.leave()
    }

    func performAndWait(_ block: @escaping (CFRunLoop) -> Void) {
        startIfNeeded()

        guard let runLoop = currentRunLoop else { return }
        guard let defaultMode = CFRunLoopMode.defaultMode else { return }

        let completionSemaphore = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, defaultMode.rawValue as CFTypeRef) {
            block(runLoop)
            completionSemaphore.signal()
        }
        CFRunLoopWakeUp(runLoop)
        completionSemaphore.wait()
    }

    func stopIfNeeded() {
        var shouldCompleteWithoutStarting = false

        stateLock.lock()
        if !stopRequested {
            stopRequested = true
            cancel()
        }
        let runLoop = runLoop
        if !hasStarted && !hasExited {
            hasExited = true
            shouldCompleteWithoutStarting = true
        }
        stateLock.unlock()

        if shouldCompleteWithoutStarting {
            threadExitGroup.leave()
        }

        // Cancellation is set while holding the same lock used to publish the
        // run loop. A starting thread therefore either observes cancellation
        // before its first iteration, or publishes a loop that we stop here.
        if let runLoop {
            // Cover the narrow window after the loop condition is evaluated but
            // before `run` begins: if that activation starts, this block stops it.
            if let defaultMode = CFRunLoopMode.defaultMode {
                CFRunLoopPerformBlock(runLoop, defaultMode.rawValue as CFTypeRef) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
            }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }

        // Waiting for thread exit, rather than for a queued run-loop block,
        // remains safe after the run loop has stopped processing blocks.
        guard Thread.current !== self else { return }
        threadExitGroup.wait()
    }

    private func startIfNeeded() {
        stateLock.lock()
        guard !stopRequested, !hasStarted else {
            stateLock.unlock()
            return
        }
        hasStarted = true
        stateLock.unlock()

        start()
        readinessSemaphore.wait()
    }

    private var currentRunLoop: CFRunLoop? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runLoop
    }
}

extension Notification.Name {
    static let switchModel = Notification.Name("tech.watzon.pindrop.switchModel")
    static let modelActiveChanged = Notification.Name("tech.watzon.pindrop.modelActiveChanged")
    static let requestActiveModel = Notification.Name("tech.watzon.pindrop.requestActiveModel")
    static let showWhatsNew = Notification.Name("tech.watzon.pindrop.showWhatsNew")
    /// UI posts this with `userInfo["text"]` (String) to copy with clipboard-undo toast.
    static let copyTextWithUndo = Notification.Name("tech.watzon.pindrop.copyTextWithUndo")
}

struct HotkeyConflict: Equatable {
    let existingIdentifier: String
    let incomingIdentifier: String
    let combination: HotkeyRegistrationState.Combination

    var conflictKey: String {
        [existingIdentifier, incomingIdentifier]
            .sorted()
            .joined(separator: "|") + "|\(combination.keyCode)|\(combination.modifiers)"
    }
}

struct HotkeyRegistrationState {
    struct Combination: Hashable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private(set) var registeredIdentifiersByCombination: [Combination: String] = [:]

    static func shouldRegisterHotkeys(hasCompletedOnboarding: Bool) -> Bool {
        hasCompletedOnboarding
    }

    mutating func register(
        identifier: String,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> HotkeyConflict? {
        let combination = Combination(keyCode: keyCode, modifiers: modifiers)

        if let existingIdentifier = registeredIdentifiersByCombination[combination] {
            return HotkeyConflict(
                existingIdentifier: existingIdentifier,
                incomingIdentifier: identifier,
                combination: combination
            )
        }

        registeredIdentifiersByCombination[combination] = identifier
        return nil
    }
}

struct HotkeyBindingSnapshot: Equatable {
    let hotkey: String
    let keyCode: Int
    let modifiers: Int
}

struct HotkeySettingsSnapshot: Equatable {
    let hasCompletedOnboarding: Bool
    let pushToTalk: HotkeyBindingSnapshot
    let toggle: HotkeyBindingSnapshot
    let meeting: HotkeyBindingSnapshot
    let recordingIndicator: HotkeyBindingSnapshot
    let copyLastTranscript: HotkeyBindingSnapshot
    let quickCapturePTT: HotkeyBindingSnapshot
    let quickCaptureToggle: HotkeyBindingSnapshot
    let openLibrary: HotkeyBindingSnapshot
    let cancelOperation: HotkeyBindingSnapshot
}

struct SettingsObservationSnapshot: Equatable {
    let outputMode: String
    let automaticDictionaryLearningEnabled: Bool
    let selectedInputDeviceUID: String
    let selectedAppLocale: AppLocale
    let selectedAppLanguage: AppLanguage
    let floatingIndicatorEnabled: Bool
    let floatingIndicatorType: FloatingIndicatorType
    let aiEnhancementEnabled: Bool
    let enableUIContext: Bool
    let vibeLiveSessionEnabled: Bool
    let streamingFeatureEnabled: Bool
    let hotkeys: HotkeySettingsSnapshot
    let mcpServerEnabled: Bool
    let mcpServerPort: Int
    let dictationAudioRetention: DictationAudioRetention
}

enum RecordingStopRoute: Equatable {
    case dictation
    case quickCapture
    case noteAppend(UUID)
    case manualTranscription

    static func resolve(
        isQuickCapture: Bool,
        noteAppendEditorID: UUID?,
        isManualTranscription: Bool
    ) -> RecordingStopRoute {
        if let noteAppendEditorID { return .noteAppend(noteAppendEditorID) }
        if isQuickCapture { return .quickCapture }
        if isManualTranscription { return .manualTranscription }
        return .dictation
    }
}

/// A synchronous, coordinator-owned admission gate shared by every stop source.
/// It lets only the first user/limit event own a recording's finalization route.
/// Claims are lease/generation-owned: cancel can free the gate immediately, and a
/// stale deferred release cannot clear a newer claim.
struct RecordingStopClaim: Equatable, Sendable {
    let id: UInt64
    let route: RecordingStopRoute
}

final class RecordingStopAdmission {
    private let lock = NSLock()
    private var isClaimed = false
    private var currentClaimID: UInt64 = 0
    private var nextClaimID: UInt64 = 0

    func claim(_ route: RecordingStopRoute) -> RecordingStopClaim? {
        lock.lock()
        defer { lock.unlock() }
        guard !isClaimed else { return nil }
        nextClaimID &+= 1
        currentClaimID = nextClaimID
        isClaimed = true
        return RecordingStopClaim(id: currentClaimID, route: route)
    }

    /// Releases only if `claim` is still the active lease.
    func release(_ claim: RecordingStopClaim) {
        lock.lock()
        defer { lock.unlock() }
        guard isClaimed, currentClaimID == claim.id else { return }
        isClaimed = false
    }

    /// Immediately frees the gate (e.g. cancel-operation). Any outstanding claim
    /// token becomes stale and its deferred `release` is a no-op.
    func invalidateCurrentClaim() {
        lock.lock()
        defer { lock.unlock() }
        guard isClaimed else { return }
        isClaimed = false
        currentClaimID &+= 1
    }
}

/// Generation-token ownership for a single in-flight dictation/processing pipeline.
/// Cancel advances the generation so post-await stages can discard stale results.
final class DictationOperationController: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func begin() -> DictationOperationToken {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return DictationOperationToken(generation: generation)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
    }

    func isCurrent(_ token: DictationOperationToken) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return token.generation == generation
    }
}

struct DictationOperationToken: Equatable, Sendable {
    let generation: UInt64
}

private final class LiveContextKeyRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isEnabled = false
    private var nextEligibleUptime: TimeInterval = 0

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        nextEligibleUptime = 0
    }

    func claim(now: TimeInterval, minimumInterval: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled, now >= nextEligibleUptime else { return false }
        nextEligibleUptime = now + minimumInterval
        return true
    }
}

private final class EscapeEventState: @unchecked Sendable {
    private let lock = NSLock()
    private var shouldSuppress = false

    func setShouldSuppress(_ shouldSuppress: Bool) {
        lock.lock()
        self.shouldSuppress = shouldSuppress
        lock.unlock()
    }

    func currentShouldSuppress() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shouldSuppress
    }
}

private final class CoordinatorNotificationResources: @unchecked Sendable {
    private let lock = NSLock()
    private let notificationCenter: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private var isTornDown = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func install(_ token: NSObjectProtocol) {
        lock.lock()
        if isTornDown {
            lock.unlock()
            notificationCenter.removeObserver(token)
            return
        }
        tokens.append(token)
        lock.unlock()
    }

    func tearDown() {
        lock.lock()
        guard !isTornDown else {
            lock.unlock()
            return
        }
        isTornDown = true
        let installedTokens = tokens
        tokens.removeAll()
        lock.unlock()

        for token in installedTokens {
            notificationCenter.removeObserver(token)
        }
    }

    deinit {
        tearDown()
    }
}

@MainActor
@Observable
final class AppCoordinator {

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["PINDROP_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private enum RecordingTriggerSource: String {
        case statusBarMenu = "status-bar-menu"
        case hotkeyToggle = "hotkey-toggle"
        case hotkeyPushToTalk = "hotkey-push-to-talk"
        case hotkeyQuickCapturePTT = "hotkey-quick-capture-ptt"
        case hotkeyQuickCaptureToggle = "hotkey-quick-capture-toggle"
        case floatingIndicatorStart = "floating-indicator-start"
        case floatingIndicatorStop = "floating-indicator-stop"
        case pillIndicatorStop = "pill-indicator-stop"
        case pillIndicatorStart = "pill-indicator-start"
        case orbIndicatorStart = "orb-indicator-start"
        case orbIndicatorStop = "orb-indicator-stop"
        case bubbleIndicatorStart = "bubble-indicator-start"
        case bubbleIndicatorStop = "bubble-indicator-stop"
        case noteAppend = "note-append"
    }

    enum EventTapRecoveryAction: Equatable {
        case reenable
        case recreate
    }

    struct EventTapRecoveryDecision: Equatable {
        let consecutiveDisableCount: Int
        let action: EventTapRecoveryAction
    }

    static func determineEventTapRecovery(
        now: Date,
        lastDisableAt: Date?,
        consecutiveDisableCount: Int,
        disableLoopWindow: TimeInterval,
        maxReenableAttemptsBeforeRecreate: Int
    ) -> EventTapRecoveryDecision {
        let nextCount: Int
        if let lastDisableAt,
           now.timeIntervalSince(lastDisableAt) <= disableLoopWindow {
            nextCount = consecutiveDisableCount + 1
        } else {
            nextCount = 1
        }

        let recreateThreshold = max(1, maxReenableAttemptsBeforeRecreate)
        let action: EventTapRecoveryAction = nextCount >= recreateThreshold ? .recreate : .reenable

        return EventTapRecoveryDecision(
            consecutiveDisableCount: nextCount,
            action: action
        )
    }

    static func floatingIndicatorFocusTrackingMode(
        floatingIndicatorEnabled: Bool,
        isTemporarilyHidden: Bool,
        selectedType: FloatingIndicatorType,
        isRecording: Bool,
        isProcessing: Bool
    ) -> FloatingIndicatorTrackingMode? {
        guard floatingIndicatorEnabled, !isTemporarilyHidden else { return nil }

        if isRecording || isProcessing {
            // Bubble manages its own caret-anchor refresh; other active styles use focus tracking.
            switch selectedType {
            case .pill, .orb, .notch, .waveform:
                return .activeSession
            case .bubble:
                return nil
            }
        }

        // Always-on styles need idle placement tracking; transient styles leave no idle footprint.
        return selectedType.isAlwaysOn ? .idlePill : nil
    }

    private enum EventTapKind {
        case escape
        case modifier
    }

    private struct EventTapDisableState {
        var lastDisableAt: Date?
        var consecutiveDisableCount = 0
        var lastDisabledTypeRawValue: UInt32?
    }

    // MARK: - Services
    
    let permissionManager: PermissionManager
    let audioRecorder: AudioRecorder
    let transcriptionService: TranscriptionService
    let modelManager: ModelManager
    let aiEnhancementService: AIEnhancementService
    let hotkeyManager: HotkeyManager
    let launchAtLoginManager: LaunchAtLoginManager
    let updateService: UpdateService
    let outputManager: OutputManager
    let historyStore: HistoryStore
    let meetingStore: MeetingStore
    let meetingsState: MeetingsFeatureState
    let meetingInsightGenerator: MeetingInsightGenerator
    let speakerIdentityService: SpeakerIdentityService
    let dictionaryStore: DictionaryStore
    let settingsStore: SettingsStore
    let notesStore: NotesStore
    let contextCaptureService: ContextCaptureService
    let contextEngineService: ContextEngineService
    let toastService: ToastService
    let automaticDictionaryLearningService: AutomaticDictionaryLearningService
    let promptPresetStore: PromptPresetStore
    let mentionRewriteService: MentionRewriteService
    let mediaPauseService: MediaPauseService
    let mediaIngestionService: MediaIngestionService
    let mediaPreparationService: MediaPreparationService
    let announcementService: AnnouncementService
    let telemetryService: TelemetryService
    let telemetryConsentService: TelemetryConsentService
    let contributionService: ContributionService
    let dictationAudioRetentionService: DictationAudioRetentionService
    let dictationRecoveryStore: DictationRecoveryStore
    let recordingState: RecordingFeatureState
    let mediaTranscriptionState: MediaTranscriptionFeatureState
    private(set) var mcpServer: MCPServer?
    private var googleOAuthService: GoogleOAuthService?
    private var googleCalendarClient: GoogleCalendarClient?
    private var calendarMeetingScheduler: CalendarMeetingScheduler?
    private var calendarRefreshTask: Task<Void, Never>?
    private var calendarWakeObserver: NSObjectProtocol?
    private var googleCalendarSyncTokens: [String: String] = [:]
    private var lastOfferedMeetingPinIdentity: String?

    // MARK: - UI Controllers
    
    let statusBarController: StatusBarController
    let floatingIndicatorState: FloatingIndicatorState
    /// Live-transcript model for overlay streaming. Shared by all indicator presenters
    /// (switching indicator type mid-session keeps the transcript) and fed by the
    /// streaming session's overlay sink.
    let liveTranscriptState: LiveTranscriptState
    /// Owns the streaming session lifecycle: engine callbacks, audio forwarding,
    /// refinement coordinator + overlay sink, and the post-stop finalize pipeline.
    let streamingSession: StreamingSessionController
    let floatingIndicatorController: FloatingIndicatorController
    let pillFloatingIndicatorController: PillFloatingIndicatorController
    let caretBubbleFloatingIndicatorController: CaretBubbleFloatingIndicatorController
    let orbFloatingIndicatorController: OrbFloatingIndicatorController
    let waveformFloatingIndicatorController: WaveformFloatingIndicatorController
    let floatingIndicatorPresenters: [FloatingIndicatorType: any FloatingIndicatorPresenting]
    let floatingIndicatorFocusTracker: FloatingIndicatorFocusTracker
    let onboardingController: OnboardingWindowController
    let announcementController: AnnouncementWindowController
    let telemetryConsentController: TelemetryConsentWindowController
    let splashController: SplashWindowController
    let settingsWindowController: SettingsWindowController
    let mainWindowController: MainWindowController
    let noteEditorWindowController: NoteEditorWindowController
    let toastWindowController: ToastWindowController
    
    // MARK: - Quick Capture State
    
    private var isQuickCaptureMode = false
    private var isNoteAppendMode = false
    private let recordingStopAdmission = RecordingStopAdmission()
    private var isRecordingFeatureCaptureActive = false
    private var manualExpectedSpeakerCount: Int?
    private var activeMeetingOccurrenceID: UUID?
    private var activeDictationRecoveryID: UUID?
    private var quickCaptureTranscription: String?
    private var noteAppendEditorID: UUID?
    private var mediaTranscriptionTask: Task<Void, Never>? {
        didSet {
            refreshEscapeSuppression()
        }
    }
    private var mediaTranscriptionGeneration: UInt64 = 0
    private var mediaTranscriptionTaskGeneration: UInt64?
    private var mediaQueueRestoreRequested = false
    private var mediaQueueNeedsProcessingReset = false
    /// Set when a dequeued media job had to yield to an active dictation session.
    /// The job goes back to the head of the queue and the queue stays paused until
    /// recording/processing clears, instead of silently dropping the job.
    private var mediaQueueDeferredUntilIdle = false
    /// Owned processing task for stop/transcribe/enhance pipelines. Cancelled by cancel-operation.
    private var activeOperationTask: Task<Void, Error>?
    private var operationController = DictationOperationController()
    private var queueOriginalModelName: String?

    // MARK: - State
    
    private let escapeEventState = EscapeEventState()
    private(set) var activeModelName: String?
    private(set) var isRecording = false {
        didSet {
            refreshEscapeSuppression()
            resumeDeferredMediaQueueIfIdle()
        }
    }
    private(set) var isProcessing = false {
        didSet {
            refreshEscapeSuppression()
            resumeDeferredMediaQueueIfIdle()
        }
    }

    /// True when the only active work is a background media transcription job.
    /// Those jobs were explicitly queued by the user and have their own cancel UI,
    /// so Escape neither cancels them nor gets swallowed while they run.
    private var isMediaTranscriptionOnlyWork: Bool {
        mediaTranscriptionTask != nil && !isRecording && activeOperationTask == nil
    }

    /// Escape is only suppressed when pressing it would actually cancel something;
    /// the predicate must stay in lockstep with `cancelCurrentOperation`'s media guard.
    private func refreshEscapeSuppression() {
        escapeEventState.setShouldSuppress(
            Self.shouldSuppressEscapeEvent(
                isRecording: isRecording,
                isProcessing: isProcessing,
                isMediaTranscriptionOnly: isMediaTranscriptionOnlyWork
            )
        )
    }
    private(set) var error: Error?
    
    private var recordingStartTime: Date?
    private var cancellables = Set<AnyCancellable>()
    private let notificationResources = CoordinatorNotificationResources()
    private var capturedContext: CapturedContext?
    private var capturedSnapshot: ContextSnapshot?
    private var capturedAdapterCapabilities: AppAdapterCapabilities?
    private var capturedRoutingSignal: PromptRoutingSignal?
    private var contextSessionState: ContextSessionState?
    private var contextSessionPollTimer: Timer?
    private var contextSessionAppActivationObserver: NSObjectProtocol?
    private var lastFocusOrWindowUpdateAt: Date?
    /// Single owner for live-context refresh work. New triggers coalesce while a
    /// refresh is suspended; only the generation that owns the active task may
    /// apply results, and stop/reset cancels the pending task.
    private var contextSessionRefreshTask: Task<Void, Never>?
    private var contextSessionRefreshGeneration: UInt64 = 0
    private var contextSessionPendingRefresh: (trigger: ContextSessionUpdateTrigger, snapshotOverride: ContextSnapshot?)?
    private let liveContextKeyRefreshGate = LiveContextKeyRefreshGate()
    private let contextSessionPollInterval: TimeInterval = 1.25
    private let contextSessionFocusUpdateThrottle: TimeInterval = 0.75
    private var recordingStartAttemptCounter: UInt64 = 0

    private let appContextAdapterRegistry = AppContextAdapterRegistry()
    private let promptRoutingResolver: any PromptRoutingResolver = NoOpPromptRoutingResolver()
    private let enableSystemHooks: Bool
    private var isShutdown = false
    private var lastObservedSettingsSnapshot: SettingsObservationSnapshot?
    private var hasRequestedAccessibilityPermissionThisLaunch = false
    private var hasShownAccessibilityFallbackAlertThisLaunch = false
    private var floatingIndicatorHiddenUntil: Date?
    private var floatingIndicatorHiddenTask: Task<Void, Never>?
    private var activeFloatingIndicatorType: FloatingIndicatorType?

    // MARK: - Dictionary Replacements
    
    /// Stores the last applied dictionary replacements for use in AI enhancement prompts
    var lastAppliedReplacements: [(original: String, replacement: String)] = []
    
    // MARK: - Escape Key Cancellation
    
    private var escapeEventTap: CFMachPort?
    private var escapeRunLoopSource: CFRunLoopSource?
    private var escapeGlobalMonitor: Any?
    private var modifierEventTap: CFMachPort?
    private var modifierRunLoopSource: CFRunLoopSource?
    private var modifierGlobalMonitor: Any?
    private let eventTapRunLoopThread = EventTapRunLoopThread(name: "tech.watzon.pindrop.event-tap-runloop")
    private var escapeEventTapDisableState = EventTapDisableState()
    private var modifierEventTapDisableState = EventTapDisableState()
    private var escapeEventTapRecoveryTask: Task<Void, Never>?
    private var modifierEventTapRecoveryTask: Task<Void, Never>?
    private var inputDeviceListMonitor: AudioDeviceListMonitor?
    private var inputMuteMonitor: InputMuteMonitor?
    private var lastEscapeSignalTime: Date?
    private let duplicateEscapeSignalThreshold: TimeInterval = 0.08
    /// First press of a double-Escape cancel sequence; cleared on cancel/finish.
    private var escapeCancelArmedAt: Date?
    static let doubleEscapeCancelWindow: TimeInterval = 0.6
    private let eventTapRecoveryDelay: Duration = .milliseconds(250)
    private let eventTapDisableLoopWindow: TimeInterval = 1.0
    private let maxEventTapReenableAttemptsBeforeRecreate = 3
    
    // MARK: - Initialization
    
    init(
        modelContext: ModelContext,
        modelContainer: ModelContainer,
        enableSystemHooks: Bool? = nil
    ) {
        self.enableSystemHooks = enableSystemHooks ?? !Self.isRunningTests
        self.permissionManager = PermissionManager()
        do {
            self.audioRecorder = try AudioRecorder(permissionManager: permissionManager)
        } catch {
            Log.app.error("Failed to initialize AudioRecorder: \(error)")
            fatalError("Failed to initialize AudioRecorder: \(error)")
        }
        self.speakerIdentityService = SpeakerIdentityService(modelContext: modelContext)
        self.modelManager = ModelManager()
        self.meetingsState = MeetingsFeatureState()
        self.meetingInsightGenerator = MeetingInsightGenerator(
            inference: self.modelManager.localMeetingModelService
        )
        self.aiEnhancementService = AIEnhancementService()
        self.hotkeyManager = HotkeyManager()
        self.launchAtLoginManager = LaunchAtLoginManager()
        self.updateService = UpdateService()
        self.settingsStore = SettingsStore()
        // TranscriptionService is built after SettingsStore so the streaming chunk
        // profile and backend providers can read the user's toggles when the engine
        // is (re)loaded.
        let settingsRef = self.settingsStore
        self.transcriptionService = TranscriptionService(
            openAIAPIKeyProvider: { [weak settingsRef] in
                guard let key = settingsRef?.loadTranscriptionAPIKey(for: .openAI) else {
                    throw OpenAITranscriptionEngine.EngineError.apiKeyMissing
                }
                return key
            },
            streamingChunkProfileProvider: { [weak settingsRef] in
                settingsRef?.streamingChunkProfile ?? .standard
            },
            streamingBackendProvider: { [weak settingsRef] in
                settingsRef?.resolvedTranscriptionBackend ?? .parakeet
            },
            speakerIdentityService: speakerIdentityService
        )
        do {
            try self.audioRecorder.setPreferredInputDeviceUID(settingsStore.selectedInputDeviceUID)
        } catch {
            Log.audio.error("Failed to apply initial preferred input device: \(error.localizedDescription)")
        }
        
        let initialOutputMode: OutputMode = settingsStore.outputMode == "directInsert" ? .directInsert : .clipboard
        self.outputManager = OutputManager(outputMode: initialOutputMode)
        self.contributionService = ContributionService(
            modelContext: modelContext,
            settingsStore: settingsStore
        )
        self.historyStore = HistoryStore(
            modelContext: modelContext,
            speakerIdentityService: speakerIdentityService,
            contributionService: contributionService
        )
        let meetingStore = MeetingStore(modelContext: modelContext)
        self.meetingStore = meetingStore
        do {
            let recovered = try meetingStore.recoverInterruptedOccurrences()
            if !recovered.isEmpty {
                Log.app.warning("Recovered \(recovered.count) interrupted meeting workspace(s)")
            }
        } catch {
            Log.app.error("Failed to recover interrupted meeting workspaces: \(error.localizedDescription)")
        }
        self.dictionaryStore = DictionaryStore(modelContext: modelContext)
        self.notesStore = NotesStore(modelContext: modelContext, aiEnhancementService: aiEnhancementService, settingsStore: settingsStore)
        self.contextCaptureService = ContextCaptureService()
        self.contextEngineService = ContextEngineService()
        self.floatingIndicatorFocusTracker = FloatingIndicatorFocusTracker(
            contextEngineService: contextEngineService
        )
        self.toastWindowController = ToastWindowController()
        self.toastService = ToastService(presenter: toastWindowController)
        self.automaticDictionaryLearningService = AutomaticDictionaryLearningService(
            snapshotProvider: contextEngineService,
            dictionaryStore: dictionaryStore,
            toastService: toastService
        )
        self.promptPresetStore = PromptPresetStore(modelContext: modelContext)
        self.mentionRewriteService = MentionRewriteService()
        self.mediaPauseService = MediaPauseService()
        self.mediaIngestionService = MediaIngestionService()
        self.mediaPreparationService = MediaPreparationService()
        self.dictationAudioRetentionService = DictationAudioRetentionService(
            historyStore: historyStore,
            settingsStore: settingsStore
        )
        self.dictationRecoveryStore = DictationRecoveryStore()
        self.recordingState = RecordingFeatureState()
        self.mediaTranscriptionState = MediaTranscriptionFeatureState()

        self.statusBarController = StatusBarController(
            audioRecorder: audioRecorder,
            settingsStore: settingsStore
        )
        self.floatingIndicatorState = FloatingIndicatorState()
        self.liveTranscriptState = LiveTranscriptState()
        self.streamingSession = StreamingSessionController(
            transcriptionService: transcriptionService,
            settingsStore: settingsStore,
            dictionaryStore: dictionaryStore,
            outputManager: outputManager,
            toastService: toastService,
            liveTranscriptState: liveTranscriptState,
            audioRecorder: audioRecorder,
            normalizeText: { AppCoordinator.normalizedTranscriptionText($0) },
            isEffectivelyEmptyText: { AppCoordinator.isTranscriptionEffectivelyEmpty($0) }
        )
        self.floatingIndicatorController = FloatingIndicatorController(
            state: floatingIndicatorState,
            liveTranscript: liveTranscriptState
        )
        self.pillFloatingIndicatorController = PillFloatingIndicatorController(
            state: floatingIndicatorState,
            settingsStore: settingsStore,
            liveTranscript: liveTranscriptState
        )
        self.caretBubbleFloatingIndicatorController = CaretBubbleFloatingIndicatorController(
            state: floatingIndicatorState,
            liveTranscript: liveTranscriptState
        )
        self.orbFloatingIndicatorController = OrbFloatingIndicatorController(
            state: floatingIndicatorState,
            settingsStore: settingsStore,
            liveTranscript: liveTranscriptState
        )
        self.waveformFloatingIndicatorController = WaveformFloatingIndicatorController(
            state: floatingIndicatorState,
            settingsStore: settingsStore
        )
        self.floatingIndicatorPresenters = [
            .notch: floatingIndicatorController,
            .pill: pillFloatingIndicatorController,
            .bubble: caretBubbleFloatingIndicatorController,
            .orb: orbFloatingIndicatorController,
            .waveform: waveformFloatingIndicatorController
        ]
        self.onboardingController = OnboardingWindowController()
        self.announcementController = AnnouncementWindowController()
        self.announcementService = AnnouncementService(
            settingsStore: settingsStore,
            presenter: announcementController
        )
        self.telemetryService = TelemetryService(settingsStore: settingsStore)
        self.telemetryConsentController = TelemetryConsentWindowController()
        self.telemetryConsentService = TelemetryConsentService(
            settingsStore: settingsStore,
            presenter: telemetryConsentController
        )
        let splashState = SplashScreenState()
        self.splashController = SplashWindowController(state: splashState)
        self.settingsWindowController = SettingsWindowController(
            settings: settingsStore,
            modelContainer: modelContainer,
            launchAtLoginManager: launchAtLoginManager,
            updateService: updateService,
            meetingsState: meetingsState
        )
        self.mainWindowController = MainWindowController()
        self.modelManager.telemetryService = telemetryService
        self.mainWindowController.setModelContainer(modelContainer)
        self.noteEditorWindowController = NoteEditorWindowController()
        self.noteEditorWindowController.setModelContainer(modelContainer)
        self.settingsWindowController.configureGoogleCalendar(
            onConnect: { [weak self] in self?.connectGoogleCalendar() },
            onConfigureClientID: { [weak self] clientID in
                self?.configureGoogleCalendarClientID(clientID)
            },
            onDisconnect: { [weak self] in self?.disconnectGoogleCalendar() }
        )
        self.mainWindowController.configureMeetingCapture(
            floatingIndicatorState: floatingIndicatorState,
            recordingState: recordingState,
            onNewTranscription: { [weak self] in
                Task { @MainActor in
                    await self?.handleToggleRecording(source: .statusBarMenu)
                }
            },
            onStartMeetingCapture: { [weak self] expectedSpeakerCount in
                self?.handleStartMeetingCapture(expectedSpeakerCount: expectedSpeakerCount)
            },
            onStartNoteCapture: { [weak self] in
                Task { @MainActor in
                    await self?.handleQuickCaptureToggle()
                }
            }
        )
        self.mainWindowController.configureMeetingsFeature(
            state: meetingsState,
            onConnect: { [weak self] in self?.connectGoogleCalendar() },
            onConfigureClientID: { [weak self] clientID in
                self?.configureGoogleCalendarClientID(clientID)
            },
            onEnableLaunchAtLogin: { [weak self] in self?.enableLaunchAtLoginForCalendarMeetings() },
            onDisconnect: { [weak self] in self?.disconnectGoogleCalendar() },
            onRefresh: { [weak self] in
                Task { @MainActor in await self?.refreshGoogleCalendar() }
            },
            onReviewWeek: { [weak self] in self?.presentWeeklyMeetingReview() },
            onApplyWeeklySelection: { [weak self] identities in
                self?.applyWeeklyMeetingSelection(identities)
            },
            onArm: { [weak self] snapshot in self?.armCalendarMeeting(snapshot) },
            onDisarm: { [weak self] identity in self?.disarmCalendarMeeting(identity: identity) },
            onRetryProcessing: { [weak self] id in self?.retryMeetingProcessing(id) },
            onRegenerateInsights: { [weak self] id in self?.regenerateMeetingInsights(id) }
        )
        self.mainWindowController.configureTranscribeFeature(
            state: mediaTranscriptionState,
            modelManager: modelManager,
            settingsStore: settingsStore,
            onImportMediaFiles: { [weak self] urls, options in
                self?.handleImportMediaFiles(urls, options: options)
            },
            onSubmitMediaLink: { [weak self] link, options in
                self?.handleSubmitMediaLink(link, options: options)
            },
            onClearMediaQueue: { [weak self] in
                self?.clearTranscriptionQueue()
            },
            onDownloadDiarizationModel: { [weak self] in
                self?.handleDownloadDiarizationModel()
            }
        )

        self.statusBarController.onToggleRecording = { [weak self] in
            await self?.handleToggleRecording(source: .statusBarMenu)
        }

        self.statusBarController.onToggleMeetingCapture = { [weak self] in
            await self?.handleMeetingCaptureToggle()
        }

        self.statusBarController.onReviewWeeklyMeetings = { [weak self] in
            self?.presentWeeklyMeetingReview()
        }

        self.statusBarController.onToggleRecordingIndicator = { [weak self] in
            guard let self else { return }
            self.settingsStore.floatingIndicatorEnabled.toggle()
            self.updateFloatingIndicatorVisibility()
            self.statusBarController.updateMenuState()
        }

        self.statusBarController.onCopyLastTranscript = { [weak self] in
            await self?.handleCopyLastTranscript()
        }

        self.statusBarController.onPasteLastTranscript = { [weak self] in
            await self?.handlePasteLastTranscript()
        }

        self.statusBarController.onExportLastTranscript = { [weak self] in
            await self?.handleExportLastTranscript()
        }

        self.statusBarController.onClearAudioBuffer = { [weak self] in
            await self?.handleClearAudioBuffer()
        }

        self.statusBarController.onCancelOperation = { [weak self] in
            await self?.handleCancelOperation()
        }

        self.statusBarController.onSelectPromptPreset = { [weak self] option in
            self?.handleSelectPromptPreset(option)
        }

        self.statusBarController.onOpenHistory = { [weak self] in
            self?.handleOpenHistory()
        }

        self.statusBarController.onShowApp = { [weak self] in
            self?.handleShowApp()
        }

        self.statusBarController.onMenuWillOpen = { [weak self] in
            self?.refreshStatusBarPresets()
        }

        self.statusBarController.onOpenSettings = { [weak self] tab in
            self?.settingsWindowController.show(tab: tab)
        }
        self.mainWindowController.onOpenSettings = { [weak self] tab in
            self?.settingsWindowController.show(tab: tab)
        }
        
        self.audioRecorder.onAudioLevel = { [weak self] level in
            self?.floatingIndicatorState.updateAudioLevel(level)
            if self?.isRecordingFeatureCaptureActive == true {
                self?.recordingState.audioLevel = level
            }
        }
        self.audioRecorder.onAudioBandLevels = { [weak self] bands in
            self?.floatingIndicatorState.updateBandLevels(bands)
        }
        self.streamingSession.configure(postStopEnhance: { [weak self] text, vocabularyWords in
            await self?.runBasicPostStopEnhance(text: text, vocabularyWords: vocabularyWords)
        })

        self.audioRecorder.onCaptureError = { [weak self] error in
            self?.handleAudioCaptureFailure(error)
        }

        let floatingIndicatorActions = FloatingIndicatorActions(
            onStartRecording: { [weak self] type in
                Task { @MainActor in
                    await self?.handleToggleRecording(source: self?.recordingTriggerSourceForIndicatorStart(type) ?? .floatingIndicatorStart)
                }
            },
            onStopRecording: { [weak self] type in
                Task { @MainActor in
                    await self?.handleToggleRecording(source: self?.recordingTriggerSourceForIndicatorStop(type) ?? .floatingIndicatorStop)
                }
            },
            onCancelRecording: { [weak self] in
                Task { @MainActor in
                    await self?.handleCancelOperation()
                }
            },
            onHideForOneHour: { [weak self] in
                self?.handleHideFloatingIndicatorForOneHour()
            },
            // Configure a fork-owned issue tracker before exposing this action.
            // Sending fork reports to the upstream Pindrop tracker is misleading.
            onReportIssue: nil,
            onGoToSettings: { [weak self] in
                self?.statusBarController.showSettings(tab: .general)
            },
            onViewTranscriptHistory: { [weak self] in
                self?.handleOpenHistory()
            },
            onPasteLastTranscript: { [weak self] in
                await self?.handlePasteLastTranscript()
            },
            onSelectInputDeviceUID: { [weak self] uid in
                self?.handleSelectInputDeviceUID(uid)
            },
            onSelectLanguage: { [weak self] language in
                self?.handleSelectLanguage(language)
            },
            onToastAnchorChanged: { [weak self] in
                self?.toastWindowController.repositionActiveToast()
            },
            availableInputDevicesProvider: {
                AudioDeviceManager.inputDevices().map { (uid: $0.uid, displayName: $0.displayName) }
            },
            selectedInputDeviceUIDProvider: { [weak self] in
                self?.settingsStore.selectedInputDeviceUID ?? ""
            },
            selectedLanguageProvider: { [weak self] in
                self?.settingsStore.selectedAppLanguage ?? .automatic
            },
            anchorProvider: { [weak self] in
                self?.contextEngineService.captureFocusedElementAnchorRect()
            },
            preferredScreenProvider: { [weak self] in
                self?.floatingIndicatorFocusTracker.preferredScreen()
            }
        )

        for presenter in self.floatingIndicatorPresenters.values {
            presenter.configure(actions: floatingIndicatorActions)
        }
        self.toastWindowController.configureIndicatorAnchorProvider { [weak self] in
            guard let self else { return nil }
            let type = self.settingsStore.selectedFloatingIndicatorType
            guard type.anchorsToastsToIndicator else { return nil }
            return self.floatingIndicatorPresenters[type]?.toastAnchor()
        }
        self.floatingIndicatorState.updateHotkeys(
            toggleHotkey: settingsStore.toggleHotkey,
            pushToTalkHotkey: settingsStore.pushToTalkHotkey
        )

        self.lastObservedSettingsSnapshot = currentSettingsObservationSnapshot()
        if self.enableSystemHooks {
            setupHotkeys()
            setupEscapeKeyMonitor()
            setupModifierKeyMonitor()
            setupInputDeviceMonitoring()
        } else {
            Log.app.debug("Skipping global hotkey and key monitor setup in test environment")
        }
        observeSettings()
        setupNotifications()
        setupGoogleCalendarIntegration()
        Log.boot.info("AppCoordinator init finished enableSystemHooks=\(self.enableSystemHooks)")
    }
    
    private func setupNotifications() {
        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .switchModel,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let modelName = notification.userInfo?["modelName"] as? String else {
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown else { return }
                    await self.switchToModel(named: modelName)
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .requestActiveModel,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown,
                          let activeModel = self.activeModelName else { return }
                    NotificationCenter.default.post(
                        name: .modelActiveChanged,
                        object: nil,
                        userInfo: ["modelName": activeModel]
                    )
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .showWhatsNew,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown else { return }
                    self.handleShowWhatsNew()
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .copyTextWithUndo,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown else { return }
                    self.handleCopyTextWithUndoNotification(notification)
                }
            }
        )

        notificationResources.install(
            NotificationCenter.default.addObserver(
                forName: .noteSpeakToAppendRequest,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutdown,
                          let editorID = notification.userInfo?["editorID"] as? UUID,
                          let action = notification.userInfo?["action"] as? String else { return }
                    if action == "start" {
                        await self.handleNoteAppendStart(editorID: editorID)
                    } else if action == "stop" {
                        await self.handleNoteAppendStop(editorID: editorID)
                    }
                }
            }
        )
    }

    // MARK: - Google Calendar meetings

    private static let googleCalendarSyncTokenDefaultsKey = "googleCalendarSyncTokens"

    private func setupGoogleCalendarIntegration() {
        meetingsState.isLaunchAtLoginEnabled = launchAtLoginManager.isEnabled
        let environmentClientID = ProcessInfo.processInfo.environment["PINDROP_GOOGLE_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundledClientID = (Bundle.main.object(forInfoDictionaryKey: "GoogleCalendarClientID") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedClientID = settingsStore.googleCalendarClientID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        meetingsState.googleClientIDDraft = savedClientID
        let clientID: String?
        if environmentClientID?.isEmpty == false {
            clientID = environmentClientID
        } else if !savedClientID.isEmpty {
            clientID = savedClientID
        } else {
            clientID = bundledClientID
        }
        meetingsState.isGoogleConfigured = clientID?.isEmpty == false
        guard let clientID, !clientID.isEmpty else {
            meetingsState.readinessMessage = "Google Calendar requires a desktop OAuth client ID in this build."
            return
        }

        let oauth = GoogleOAuthService(configuration: .desktop(clientID: clientID))
        let client = GoogleCalendarClient(oauth: oauth)
        let scheduler = CalendarMeetingScheduler(
            meetingStore: meetingStore,
            notifier: SystemMeetingNotifier(),
            launchAtLoginEnabled: { [weak self] in self?.launchAtLoginManager.isEnabled == true },
            readiness: { [weak self] in
                guard let self else {
                    return MeetingPreflightReport(issues: [.microphonePermission])
                }
                return await self.meetingPreflightReport()
            },
            isBusy: { [weak self] in
                guard let self else { return true }
                return self.isRecording || self.isProcessing
            },
            startCapture: { [weak self] occurrenceID in
                guard let self else { return }
                let expectedSpeakers = try self.meetingStore.occurrence(id: occurrenceID)?.expectedSpeakerCount
                try await self.startManualTranscriptionRecording(
                    mode: .microphoneAndSystemAudio,
                    expectedSpeakerCount: expectedSpeakers,
                    existingOccurrenceID: occurrenceID
                )
            },
            stopCapture: { [weak self] occurrenceID in
                guard let self, self.activeMeetingOccurrenceID == occurrenceID else { return }
                try await self.dispatchRecordingStop()
            }
        )
        googleOAuthService = oauth
        googleCalendarClient = client
        calendarMeetingScheduler = scheduler
        meetingsState.isGoogleConnected = oauth.isConnected
        googleCalendarSyncTokens = loadGoogleCalendarSyncTokens()
        refreshArmedMeetingState()
        Task { @MainActor [weak self, weak scheduler] in
            guard let self, let scheduler else { return }
            do {
                try await scheduler.restoreArmedSchedules()
                self.refreshArmedMeetingState()
            } catch {
                Log.app.error("Failed to restore scheduled meetings: \(error.localizedDescription)")
            }
        }

        calendarWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshGoogleCalendar()
            }
        }
    }

    private func meetingPreflightReport() async -> MeetingPreflightReport {
        let preflight = MeetingPreflightService(
            permissionProvider: permissionManager,
            modelManager: modelManager,
            diarizationLoader: {
                let diarizer = FluidSpeakerDiarizer()
                try await diarizer.loadModels()
                await diarizer.unloadModels()
            }
        )
        return await preflight.run(selectedTranscriptionModel: settingsStore.selectedModel)
    }

    func connectGoogleCalendar() {
        guard let googleOAuthService else {
            meetingsState.errorMessage = "Google Calendar is not configured in this build."
            return
        }
        meetingsState.isRefreshing = true
        meetingsState.errorMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await googleOAuthService.connect()
                self.meetingsState.isGoogleConnected = true
                await self.refreshGoogleCalendar()
                self.startGoogleCalendarRefreshLoop()
            } catch {
                self.meetingsState.errorMessage = error.localizedDescription
            }
            self.meetingsState.isRefreshing = false
        }
    }

    func configureGoogleCalendarClientID(_ value: String) {
        let clientID = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clientID.hasSuffix(".apps.googleusercontent.com") else {
            meetingsState.errorMessage = localized(
                "Enter a Google Desktop OAuth client ID ending in .apps.googleusercontent.com.",
                locale: settingsStore.selectedAppLocale.locale
            )
            return
        }
        guard googleOAuthService == nil else {
            meetingsState.errorMessage = localized(
                "Disconnect Google Calendar before changing its OAuth client ID.",
                locale: settingsStore.selectedAppLocale.locale
            )
            return
        }

        settingsStore.googleCalendarClientID = clientID
        meetingsState.googleClientIDDraft = clientID
        meetingsState.errorMessage = nil
        meetingsState.readinessMessage = nil
        setupGoogleCalendarIntegration()
    }

    func enableLaunchAtLoginForCalendarMeetings() {
        do {
            try launchAtLoginManager.setEnabled(true)
        } catch {
            meetingsState.errorMessage = error.localizedDescription
        }

        let enabled = launchAtLoginManager.isEnabled
        settingsStore.launchAtLogin = enabled
        meetingsState.isLaunchAtLoginEnabled = enabled
        if enabled {
            meetingsState.errorMessage = nil
        }
    }

    func disconnectGoogleCalendar() {
        guard let googleOAuthService else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await googleOAuthService.disconnect()
                self.meetingsState.isGoogleConnected = false
                self.meetingsState.replaceEvents([])
                self.googleCalendarSyncTokens = [:]
                self.saveGoogleCalendarSyncTokens()
                self.calendarRefreshTask?.cancel()
                self.calendarRefreshTask = nil
            } catch {
                self.meetingsState.errorMessage = error.localizedDescription
            }
        }
    }

    func refreshGoogleCalendar() async {
        guard meetingsState.isGoogleConnected, let googleCalendarClient else { return }
        meetingsState.isRefreshing = true
        meetingsState.errorMessage = nil
        defer { meetingsState.isRefreshing = false }

        do {
            let now = Date()
            let horizon = now.addingTimeInterval(30 * 24 * 60 * 60)
            let calendars = try await googleCalendarClient.calendars().filter {
                $0.primary == true || $0.selected != false
            }
            var cached = Dictionary(
                uniqueKeysWithValues: meetingsState.calendarEvents.map { ($0.persistentIdentity, $0) }
            )

            for calendar in calendars {
                // A durable sync token is useful only with a matching in-memory baseline.
                // On a cold launch perform one full 30-day read, then use deltas while running.
                let hasBaseline = cached.values.contains { $0.calendarID == calendar.id }
                let token = hasBaseline ? googleCalendarSyncTokens[calendar.id] : nil
                let result = try await googleCalendarClient.eventsRecoveringInvalidSyncToken(
                    calendarID: calendar.id,
                    from: now,
                    through: horizon,
                    syncToken: token
                )
                if token == nil {
                    cached = cached.filter { $0.value.calendarID != calendar.id }
                }

                var identitiesReturnedByFullSync = Set<String>()
                for event in result.events {
                    let identity = ["google", calendar.id, event.id].joined(separator: ":")
                    identitiesReturnedByFullSync.insert(identity)
                    if event.status == "cancelled" {
                        cached[identity] = nil
                        if let armed = try meetingStore.occurrence(calendarIdentity: identity), armed.isArmed {
                            await calendarMeetingScheduler?.eventWasDeleted(id: armed.id)
                        }
                        continue
                    }
                    guard let snapshot = MeetingJoinURLResolver.snapshot(event: event, calendarID: calendar.id) else {
                        continue
                    }
                    cached[snapshot.persistentIdentity] = snapshot
                    if let armed = try meetingStore.occurrence(calendarIdentity: snapshot.persistentIdentity), armed.isArmed {
                        try calendarMeetingScheduler?.eventWasUpdated(snapshot)
                    }
                }

                if token == nil {
                    let armedInCalendar = try meetingStore.fetchOccurrences().filter {
                        $0.isArmed && $0.providerRawValue == "google" && $0.calendarID == calendar.id
                    }
                    for armed in armedInCalendar {
                        guard let identity = armed.calendarOccurrenceIdentity,
                              !identitiesReturnedByFullSync.contains(identity) else { continue }
                        await calendarMeetingScheduler?.eventWasDeleted(id: armed.id)
                    }
                }
                if let next = result.nextSyncToken { googleCalendarSyncTokens[calendar.id] = next }
            }
            saveGoogleCalendarSyncTokens()
            meetingsState.replaceEvents(Array(cached.values).filter {
                $0.start <= horizon && ($0.end ?? $0.start) >= now
            })
            refreshArmedMeetingState()
            offerActiveRecordingMeetingPinIfNeeded()
        } catch {
            meetingsState.errorMessage = error.localizedDescription
        }
    }

    func armCalendarMeeting(_ snapshot: MeetingOccurrenceSnapshot) {
        Task { @MainActor [weak self] in
            guard let self, let scheduler = self.calendarMeetingScheduler else { return }
            do {
                _ = try await scheduler.arm(snapshot)
                self.refreshArmedMeetingState()
            } catch {
                self.meetingsState.errorMessage = error.localizedDescription
            }
        }
    }

    func disarmCalendarMeeting(identity: String) {
        do {
            guard let occurrence = try meetingStore.occurrence(calendarIdentity: identity) else { return }
            try calendarMeetingScheduler?.disarm(id: occurrence.id)
            refreshArmedMeetingState()
        } catch {
            meetingsState.errorMessage = error.localizedDescription
        }
    }

    func presentWeeklyMeetingReview() {
        mainWindowController.showNavigationItem(.meetings)
        meetingsState.weeklyReviewErrorMessage = nil

        guard meetingsState.isGoogleConfigured, meetingsState.isGoogleConnected else {
            meetingsState.isGoogleSetupPresented = true
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.refreshGoogleCalendar()
            guard self.meetingsState.errorMessage == nil else { return }
            self.meetingsState.isWeeklyReviewPresented = true
        }
    }

    func applyWeeklyMeetingSelection(_ selectedIdentities: Set<String>) {
        guard !meetingsState.isApplyingWeeklySelection else { return }
        meetingsState.isApplyingWeeklySelection = true
        meetingsState.weeklyReviewErrorMessage = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.meetingsState.isApplyingWeeklySelection = false }

            do {
                guard let scheduler = self.calendarMeetingScheduler else {
                    throw GoogleOAuthError.notConnected
                }
                let weeklyEvents = WeeklyMeetingReview.upcomingEvents(
                    from: self.meetingsState.calendarEvents,
                    now: Date()
                )
                let eventsByIdentity = Dictionary(
                    uniqueKeysWithValues: weeklyEvents.map { ($0.persistentIdentity, $0) }
                )
                let selectedSnapshots = selectedIdentities.compactMap { eventsByIdentity[$0] }
                let invalidSelection = selectedSnapshots.first {
                    !WeeklyMeetingReview.assessment(for: $0).canScheduleAutomatically
                }
                if invalidSelection != nil {
                    throw CalendarMeetingScheduler.ArmError.prerequisites(
                        localized(
                            "A checked event no longer has the calendar details needed for automatic recording.",
                            locale: self.settingsStore.selectedAppLocale.locale
                        )
                    )
                }

                let currentlyArmed = Set(
                    self.meetingsState.armedOccurrenceIDsByIdentity.keys
                )
                let snapshotsToArm = selectedSnapshots.filter {
                    !currentlyArmed.contains($0.persistentIdentity)
                }

                // Preserve existing choices if readiness fails: arm additions first,
                // then disarm occurrences the user unchecked.
                _ = try await scheduler.arm(snapshotsToArm)

                let weeklyIdentities = Set(eventsByIdentity.keys)
                let identitiesToDisarm = currentlyArmed
                    .intersection(weeklyIdentities)
                    .subtracting(selectedIdentities)
                for identity in identitiesToDisarm {
                    guard let occurrence = try self.meetingStore.occurrence(calendarIdentity: identity) else {
                        continue
                    }
                    try scheduler.disarm(id: occurrence.id)
                }

                self.refreshArmedMeetingState()
                self.meetingsState.isWeeklyReviewPresented = false
                let scheduledCount = selectedIdentities.intersection(weeklyIdentities).count
                self.toastService.show(
                    ToastPayload(
                        message: String(
                            format: localized(
                                "%d meeting recordings scheduled for this week.",
                                locale: self.settingsStore.selectedAppLocale.locale
                            ),
                            locale: self.settingsStore.selectedAppLocale.locale,
                            scheduledCount
                        )
                    )
                )
            } catch {
                self.meetingsState.weeklyReviewErrorMessage = error.localizedDescription
                self.meetingsState.errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshArmedMeetingState() {
        do {
            meetingsState.armedOccurrenceIDsByIdentity = Dictionary(
                uniqueKeysWithValues: try meetingStore.fetchOccurrences().compactMap {
                    guard $0.isArmed, let identity = $0.calendarOccurrenceIdentity else { return nil }
                    return (identity, $0.id)
                }
            )
        } catch {
            Log.app.error("Failed to refresh armed meeting state: \(error.localizedDescription)")
        }
    }

    static func activeCalendarMeetingCandidate(
        in events: [MeetingOccurrenceSnapshot],
        at now: Date
    ) -> MeetingOccurrenceSnapshot? {
        events
            .filter { event in
                guard event.joinURL != nil else { return false }
                let effectiveEnd = event.end ?? event.start.addingTimeInterval(2 * 60 * 60)
                return event.start.addingTimeInterval(-10 * 60) <= now
                    && effectiveEnd.addingTimeInterval(10 * 60) >= now
            }
            .min { lhs, rhs in
                abs(lhs.start.timeIntervalSince(now)) < abs(rhs.start.timeIntervalSince(now))
            }
    }

    private func offerActiveRecordingMeetingPinIfNeeded() {
        guard isRecording, !isRecordingFeatureCaptureActive,
              meetingsState.isGoogleConnected,
              let candidate = Self.activeCalendarMeetingCandidate(
                in: meetingsState.calendarEvents,
                at: Date()
              ),
              candidate.persistentIdentity != lastOfferedMeetingPinIdentity else { return }

        lastOfferedMeetingPinIdentity = candidate.persistentIdentity
        let locale = settingsStore.selectedAppLocale.locale
        toastService.show(
            ToastPayload(
                message: String(
                    format: localized("This looks like your calendar meeting: %@", locale: locale),
                    locale: locale,
                    candidate.title
                ),
                actions: [
                    ToastAction(
                        title: localized("Pin This Recording", locale: locale),
                        role: .primary
                    ) { [weak self] in
                        self?.pinActiveRecording(to: candidate)
                    }
                ],
                duration: 15
            )
        )
    }

    private func pinActiveRecording(to snapshot: MeetingOccurrenceSnapshot) {
        guard isRecording, !isRecordingFeatureCaptureActive else { return }
        do {
            let occurrence = try meetingStore.arm(snapshot)
            try meetingStore.transition(id: occurrence.id, to: .preparing)
            try meetingStore.transition(id: occurrence.id, to: .recording)
            activeMeetingOccurrenceID = occurrence.id
            isRecordingFeatureCaptureActive = true
            manualExpectedSpeakerCount = occurrence.expectedSpeakerCount
            recordingState.beginRecording(
                mode: .microphone,
                startedAt: recordingStartTime ?? Date()
            )
            statusBarController.setRecordingState(isMeetingCapture: true)
            statusBarController.updateMenuState()
            calendarMeetingScheduler?.adoptActiveCapture(
                id: occurrence.id,
                scheduledEnd: snapshot.end
            )
            refreshArmedMeetingState()
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(
                        format: localized("Pinned to %@. Recording will stop at the scheduled end.", locale: locale),
                        locale: locale,
                        snapshot.title
                    )
                )
            )
        } catch {
            meetingsState.errorMessage = error.localizedDescription
            toastService.show(ToastPayload(message: error.localizedDescription, style: .error))
        }
    }

    private func startGoogleCalendarRefreshLoop() {
        guard meetingsState.isGoogleConnected, calendarRefreshTask == nil else { return }
        calendarRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.refreshGoogleCalendar()
                do {
                    try await Task.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
            }
        }
    }

    private func loadGoogleCalendarSyncTokens() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: Self.googleCalendarSyncTokenDefaultsKey) else {
            return [:]
        }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func saveGoogleCalendarSyncTokens() {
        let data = try? JSONEncoder().encode(googleCalendarSyncTokens)
        UserDefaults.standard.set(data, forKey: Self.googleCalendarSyncTokenDefaultsKey)
    }
    
    // MARK: - Lifecycle
    
    func start(launchSemantics: StartupLaunchSemantics = .normal) async {
        Log.boot.info("AppCoordinator.start() entered hasCompletedOnboarding=\(settingsStore.hasCompletedOnboarding) selectedModel=\(settingsStore.selectedModel)")
        telemetryService.send(
            .appLaunched,
            parameters: [
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue,
                TelemetryParameter.model: settingsStore.selectedModel,
                TelemetryParameter.locale: settingsStore.selectedAppLocale.locale.identifier
            ]
        )
        if !settingsStore.hasCompletedOnboarding {
            Log.boot.info("Taking onboarding path (skipping splash and normal operation until complete)")
            showOnboarding()
            return
        }

        Log.boot.info("Taking normal startup path: seed presets, splash, startNormalOperation")
        seedBuiltInPresetsIfNeeded()
        refreshStatusBarPresets()

        let shouldOrderMainWindowFront = StartupWindowPresentationPolicy.shouldOrderMainWindowFront(
            for: .init(
                launchWithoutShowingWindow: settingsStore.launchWithoutShowingWindow,
                launchSemantics: launchSemantics,
                hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
            )
        )
        Log.boot.info(
            "Startup window presentation orderFront=\(shouldOrderMainWindowFront) preference=\(settingsStore.launchWithoutShowingWindow) hideFlag=\(launchSemantics.launchServicesRequestedHide)"
        )

        // Skip splash / main window / auto What's New so silent launches never
        // flash non-onboarding chrome. Manual menu-bar access still opens later.
        if shouldOrderMainWindowFront {
            splashController.show()
        }

        await startNormalOperation()
        startGoogleCalendarRefreshLoop()

        if shouldOrderMainWindowFront {
            splashController.dismiss { [weak self] in
                self?.mainWindowController.show()
                self?.presentAnnouncementAfterStartup()
            }
        } else {
            // Keep the main window out of AppKit restoration/frontmost state.
            mainWindowController.hide()
            Log.boot.info("Silent startup: suppressed main window and auto announcement presentation")
        }
        Log.boot.info("AppCoordinator.start() finished normal path")
    }

    private func showOnboarding() {
        Log.boot.info("showOnboarding: presenting onboarding window")
        onboardingController.showOnboarding(
            settings: settingsStore,
            modelManager: modelManager,
            transcriptionService: transcriptionService,
            permissionManager: permissionManager,
            onComplete: { [weak self] in
                Task { @MainActor in
                    self?.announcementService.markCurrentAnnouncementSeen()
                    await self?.finishPostOnboardingSetup()
                    self?.mainWindowController.show()
                    self?.showWelcomePopoverAfterDelay()
                    // Consent was answered via the onboarding permissions step;
                    // this sends only if the user opted in there.
                    self?.telemetryService.send(
                        .onboardingCompleted,
                        parameters: [
                            TelemetryParameter.model: self?.settingsStore.selectedModel ?? ""
                        ]
                    )
                }
            }
        )
    }

    private func presentAnnouncementAfterStartup() {
        guard !AppTestMode.isRunningAnyTests else {
            Log.app.debug("Skipping announcement presentation in test mode")
            return
        }

        // Telemetry consent takes priority; when it presents, defer What's New to
        // the next launch so the two windows never stack.
        if telemetryConsentService.presentConsentIfNeeded(
            hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
        ) {
            return
        }

        announcementService.presentCurrentAnnouncementIfNeeded(
            hasCompletedOnboarding: settingsStore.hasCompletedOnboarding
        )
    }


    private func handleShowWhatsNew() {
        guard !AppTestMode.isRunningAnyTests else {
            Log.app.debug("Skipping manual announcement presentation in test mode")
            return
        }

        announcementService.showCurrentAnnouncement()
    }
    
    private func showWelcomePopoverAfterDelay() {
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            statusBarController.showWelcomePopover()
        }
    }
    
    private func finishPostOnboardingSetup() async {
        Log.boot.info("finishPostOnboardingSetup begin")
        seedBuiltInPresetsIfNeeded()
        refreshStatusBarPresets()
        registerHotkeysFromSettings()

        ensureAccessibilityPermissionForDirectInsert(trigger: "post-onboarding", showFallbackAlert: false)
        updateVibeRuntimeStateFromSettings()
        Log.boot.info("finishPostOnboardingSetup complete")
    }
    
    private func seedBuiltInPresetsIfNeeded() {
        do {
            try promptPresetStore.seedBuiltInPresets()
            Log.app.debug("Synced built-in prompt presets")
        } catch {
            Log.app.error("Failed to seed built-in presets: \(error)")
        }

        applyDefaultPromptPresetIfNeeded()
    }

    private func refreshStatusBarPresets() {
        do {
            let presets = try promptPresetStore.fetchAll()
            let options = presets.map {
                StatusBarController.PromptPresetOption(
                    id: $0.id.uuidString,
                    assignmentID: $0.builtInIdentifier ?? $0.id.uuidString,
                    name: $0.name
                )
            }
            statusBarController.updatePromptPresets(options)
        } catch {
            statusBarController.updatePromptPresets([])
            Log.app.error("Failed to refresh status bar presets: \(error)")
        }
    }

    /// One-shot migration: select the "Clean Transcript" built-in preset as the
    /// default for users who never explicitly chose a preset and never
    /// customized the generic fallback prompt.
    private func applyDefaultPromptPresetIfNeeded() {
        guard !settingsStore.didMigrateToCleanTranscriptDefault else { return }
        guard settingsStore.selectedPresetId == nil else {
            settingsStore.didMigrateToCleanTranscriptDefault = true
            return
        }
        // The v2 AI config migrator already seeds transcriptionEnhancement with a
        // promptPresetID (defaulting to "clean"), so this legacy default-prompt migration
        // is a no-op once v2 migration has completed.
        guard !settingsStore.aiConfigV2Migrated else {
            settingsStore.didMigrateToCleanTranscriptDefault = true
            return
        }
        guard settingsStore.aiEnhancementPrompt == SettingsStore.Defaults.aiEnhancementPrompt else {
            settingsStore.didMigrateToCleanTranscriptDefault = true
            return
        }

        do {
            let builtIns = try promptPresetStore.fetchBuiltIn()
            let target = BuiltInPresets.defaultPreset.identifier
            if let preset = builtIns.first(where: { $0.builtInIdentifier == target }) {
                settingsStore.selectedPresetId = preset.id.uuidString
                Log.app.info("Applied default prompt preset '\(preset.name)' for new user")
            } else {
                Log.app.error("Default prompt preset '\(target)' not found after seeding")
            }
        } catch {
            Log.app.error("Failed to apply default prompt preset: \(error)")
        }

        settingsStore.didMigrateToCleanTranscriptDefault = true
    }

    private func setActiveModel(_ modelName: String) {
        activeModelName = modelName
        NotificationCenter.default.post(
            name: .modelActiveChanged,
            object: nil,
            userInfo: ["modelName": modelName]
        )
    }

    static func shouldAttemptWhisperModelRepair(after error: Error) -> Bool {
        !isNetworkConnectivityError(error)
    }

    static func isNetworkConnectivityError(_ error: Error) -> Bool {
        if containsNetworkURLError(error) {
            return true
        }

        let descriptions = [
            (error as? LocalizedError)?.errorDescription,
            error.localizedDescription
        ].compactMap { $0?.lowercased() }

        let networkFragments = [
            "internet connection appears to be offline",
            "not connected to the internet",
            "network connection was lost",
            "cannot find host",
            "could not find host",
            "could not connect to the server",
            "a server with the specified hostname could not be found",
            "request timed out",
            "connection timed out",
            "dns lookup failed"
        ]

        return descriptions.contains { description in
            networkFragments.contains { description.contains($0) }
        }
    }

    private static func containsNetworkURLError(_ error: Error, depth: Int = 0) -> Bool {
        guard depth < 4 else { return false }

        let nsError = error as NSError
        let networkCodes: Set<URLError.Code> = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .timedOut,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .secureConnectionFailed
        ]

        if nsError.domain == NSURLErrorDomain,
           networkCodes.contains(URLError.Code(rawValue: nsError.code)) {
            return true
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           containsNetworkURLError(underlyingError, depth: depth + 1) {
            return true
        }

        if let underlyingErrors = nsError.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
            return underlyingErrors.contains {
                containsNetworkURLError($0, depth: depth + 1)
            }
        }

        return false
    }

    private func loadAndActivateModel(
        named modelName: String,
        provider: ModelManager.ModelProvider
    ) async throws {
        do {
            if provider == .whisperKit,
               let localModelPath = modelManager.existingLocalModelPath(for: modelName) {
                Log.model.info("Loading WhisperKit model \(modelName) from local folder: \(localModelPath.path)")
                try await transcriptionService.loadModel(modelPath: localModelPath.path)
            } else {
                try await transcriptionService.loadModel(modelName: modelName, provider: provider)
            }
        } catch {
            telemetryService.send(
                .modelLoadFailed,
                parameters: [
                    TelemetryParameter.model: modelName,
                    TelemetryParameter.errorCase: TelemetryService.errorCaseName(error)
                ]
            )
            throw error
        }
        setActiveModel(modelName)
    }

    private func updateSplashDownloadState(
        with snapshot: ModelManager.DownloadSnapshot,
        displayName: String
    ) {
        let loadingText: String

        switch snapshot.phase {
        case .idle, .listing, .downloading:
            loadingText = "Downloading \(displayName)..."
        case .compiling, .preparing:
            loadingText = "Preparing \(displayName)..."
        case .completed:
            splashController.updateProgress(snapshot.progress)
            return
        }

        splashController.updateDownload(text: loadingText, progress: snapshot.progress)
    }

    private func attemptWhisperModelRepairAndReload(
        modelName: String,
        displayName: String,
        loadError: Error
    ) async throws {
        Log.boot.info("attemptWhisperModelRepairAndReload begin model=\(modelName)")

        guard Self.shouldAttemptWhisperModelRepair(after: loadError) else {
            Log.model.warning("Skipping Whisper model repair for \(modelName) after network/offline load failure; local model folder will not be deleted. Error: \(loadError.localizedDescription)")
            Log.boot.warning("attemptWhisperModelRepairAndReload skipped network/offline error model=\(modelName)")
            throw loadError
        }

        Log.model.warning("Selected Whisper model failed to load, attempting repair for \(modelName)")

        do {
            try await modelManager.deleteModel(named: modelName)
        } catch ModelManager.ModelError.modelNotFound {
            Log.model.debug("Model \(modelName) was not present when starting repair")
        }

        splashController.setDownloading("Repairing \(displayName)...")
        try await modelManager.downloadModel(named: modelName) { [weak self] snapshot in
            Task { @MainActor in
                self?.updateSplashDownloadState(with: snapshot, displayName: displayName)
            }
        }

        splashController.setLoading("Loading \(displayName)...")
        try await loadAndActivateModel(named: modelName, provider: .whisperKit)
        Log.boot.info("attemptWhisperModelRepairAndReload finished OK model=\(modelName)")
    }

    private func handleModelLoadError(_ error: Error, context: String) {
        self.error = error
        Log.app.error("\(context): \(error)")

        let errorMessage = (error as? LocalizedError)?.errorDescription ?? ""
        if errorMessage.contains("timed out") {
            AlertManager.shared.showModelTimeoutAlert()
        }
    }
    
    private func startNormalOperation() async {
        Log.boot.info("startNormalOperation begin")
        // Sync launch at login state on startup
        let actualLaunchAtLoginState = launchAtLoginManager.isEnabled
        if settingsStore.launchAtLogin != actualLaunchAtLoginState {
            settingsStore.launchAtLogin = actualLaunchAtLoginState
            Log.app.info("Synced launch at login state: \(actualLaunchAtLoginState)")
        }

        // Sweep expired dictation audio at launch and every 24h thereafter.
        dictationAudioRetentionService.startPeriodicSweep()

        let micStatus = permissionManager.checkPermissionStatus()
        if micStatus == .denied || micStatus == .restricted {
            Log.app.warning("Microphone permission denied - recording will not work")
            AlertManager.shared.showMicrophonePermissionAlert()
        } else if micStatus == .notDetermined {
            Log.app.info("Microphone permission not determined at launch; request deferred until recording starts")
        }

        ensureAccessibilityPermissionForDirectInsert(trigger: "startup", showFallbackAlert: false)

        var modelName = settingsStore.selectedModel

        if !modelManager.availableModels.contains(where: { $0.name == modelName }) {
            Log.model.warning("Selected model \(modelName) is not recognized, resetting to default")
            modelName = SettingsStore.Defaults.selectedModel
            settingsStore.selectedModel = modelName
        }

        let selectedModel = modelManager.availableModels.first(where: { $0.name == modelName })
        let selectedProvider = selectedModel?.provider ?? .whisperKit
        let selectedDisplayName = selectedModel?.displayName ?? modelName
        
        await modelManager.refreshDownloadedModels()
        let modelExists = modelManager.isModelDownloaded(modelName)
        
        if modelExists {
            splashController.setLoading("Loading model...")
            Log.model.info("Model \(modelName) found, loading...")
            do {
                try await loadAndActivateModel(named: modelName, provider: selectedProvider)
                Log.model.info("Model loaded successfully")
            } catch {
                if selectedProvider == .whisperKit {
                    do {
                        try await attemptWhisperModelRepairAndReload(
                            modelName: modelName,
                            displayName: selectedDisplayName,
                            loadError: error
                        )
                        Log.model.info("Model repaired and loaded successfully")
                    } catch {
                        handleModelLoadError(error, context: "Failed to repair transcription model")
                    }
                } else {
                    handleModelLoadError(error, context: "Failed to load transcription model")
                }
            }
        } else {
            // Model missing - check if any model is available for fallback
            let downloadedModels = await modelManager.getDownloadedModels()
            
            if let fallbackModel = downloadedModels.first {
                Log.model.info("Selected model \(modelName) not found, falling back to \(fallbackModel.name)")
                splashController.setLoading("Using \(fallbackModel.displayName)...")
                settingsStore.selectedModel = fallbackModel.name
                do {
                    try await loadAndActivateModel(named: fallbackModel.name, provider: fallbackModel.provider)
                    Log.model.info("Fallback model loaded successfully")
                } catch {
                    handleModelLoadError(error, context: "Failed to load fallback model")
                }
            } else {
                // No models available - download the selected one
                splashController.setDownloading("Downloading \(selectedDisplayName)...")
                Log.model.info("Model \(modelName) not found, downloading...")
                
                do {
                    try await modelManager.downloadModel(named: modelName) { [weak self] snapshot in
                        Task { @MainActor in
                            self?.updateSplashDownloadState(with: snapshot, displayName: selectedDisplayName)
                        }
                    }
                    splashController.setLoading("Loading model...")
                    Log.model.info("Model downloaded, loading...")
                    try await loadAndActivateModel(named: modelName, provider: selectedProvider)
                    Log.model.info("Model loaded successfully")
                } catch {
                    handleModelLoadError(error, context: "Failed to download/load model")
                }
            }
        }

        // Load recent transcripts for the menu
        updateRecentTranscriptsMenu()

        updateFloatingIndicatorVisibility()

        updateVibeRuntimeStateFromSettings()
        applyMCPServerSettings()
        prewarmStreamingEngineIfEnabled()
        resumeInterruptedDictationsIfNeeded()
        Log.boot.info("startNormalOperation complete")
    }

    /// Loads the streaming (Nemotron) engine and runs its CoreML warm-up inference
    /// in the background so the first dictation session doesn't pay that cost while
    /// the recording indicator is animating in. `prepareStreamingEngine` coalesces
    /// concurrent callers, so a session that starts mid-prewarm awaits this same
    /// load rather than failing over to batch.
    private func prewarmStreamingEngineIfEnabled() {
        guard settingsStore.streamingFeatureEnabled else { return }
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                try await self.transcriptionService.prepareStreamingEngine()
                Log.boot.info("Streaming engine prewarmed")
            } catch {
                // Model not downloaded yet, etc. — the session path handles
                // fallback; the next session simply pays the load as before.
                Log.transcription.info("Streaming engine prewarm skipped: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - MCP Server

    private func applyMCPServerSettings() {
        // The public local-only fork does not expose a network automation surface.
        // Fail closed even if an inherited preference was set by an older build or
        // modified directly in UserDefaults.
        if settingsStore.mcpServerEnabled {
            settingsStore.mcpServerEnabled = false
        }
        stopMCPServerIfRunning()
    }

    private func startMCPServerIfNeeded() {
        guard LocalOnlySecurityPolicy.allowsMCPServer else {
            stopMCPServerIfRunning()
            return
        }
        let port = UInt16(clamping: settingsStore.mcpServerPort)

        // Reuse existing server if port hasn't changed
        if let existing = mcpServer, existing.port == port {
            if !existing.isRunning { existing.start() }
            return
        }

        // Stop old server (port changed)
        mcpServer?.stop()

        let token = resolvedMCPToken()
        let server = MCPServer(port: port, token: token)
        server.coordinator = self
        mcpServer = server
        server.start()
    }

    private func stopMCPServerIfRunning() {
        mcpServer?.stop()
        mcpServer = nil
    }

    private func resolvedMCPToken() -> String {
        if let existing = settingsStore.loadMCPToken(), !existing.isEmpty {
            return existing
        }
        let token = MCPTokenGenerator.generate()
        try? settingsStore.saveMCPToken(token)
        return token
    }

    /// Submits a transcription job from the MCP server (bypasses UI source validation).
    func submitMCPTranscriptionJob(_ job: MediaTranscriptionJobState) {
        enqueueOrStart(job)
    }

    /// Cancels the MCP-submitted job with the given internal state ID.
    func cancelMCPJob(stateID: UUID) {
        if mediaTranscriptionState.currentJob?.id == stateID {
            mediaTranscriptionGeneration &+= 1
            mediaQueueNeedsProcessingReset = mediaQueueNeedsProcessingReset || isProcessing
            mediaTranscriptionTask?.cancel()
            mediaTranscriptionState.clearCurrentJob()
            if mediaTranscriptionTask == nil {
                startMediaQueueContinuationIfNeeded()
            }
            Log.mcp.info("Cancelled active MCP job \(stateID)")
        } else {
            mediaTranscriptionState.pendingJobs.removeAll { $0.id == stateID }
            Log.mcp.info("Removed pending MCP job \(stateID)")
        }
    }

    /// Loads and activates a transcription model by name for MCP callers.
    func loadAndActivateModelForMCP(named modelName: String) async throws {
        guard let model = modelManager.availableModels.first(where: { $0.name == modelName }) else {
            throw ModelManager.ModelError.modelNotFound(modelName)
        }
        if !modelManager.isModelDownloaded(modelName),
           modelManager.existingLocalModelPath(for: modelName) == nil {
            try await modelManager.downloadModel(named: modelName) { _ in }
        }
        try await loadAndActivateModel(named: modelName, provider: model.provider)
        settingsStore.selectedModel = modelName
    }

    // MARK: - Hotkey Setup
    
    private func setupHotkeys() {
        registerHotkeysFromSettings()
    }
    
    private func registerHotkeysFromSettings() {
        guard enableSystemHooks else { return }

        hotkeyManager.unregisterAll()
        guard HotkeyRegistrationState.shouldRegisterHotkeys(hasCompletedOnboarding: settingsStore.hasCompletedOnboarding) else {
            Log.hotkey.info("Skipping hotkey registration until onboarding is complete")
            return
        }

        var registrationState = HotkeyRegistrationState()

        if !settingsStore.pushToTalkHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Push-to-Talk",
               hotkeyString: settingsStore.pushToTalkHotkey,
               keyCodeValue: settingsStore.pushToTalkHotkeyCode,
               modifiersValue: settingsStore.pushToTalkHotkeyModifiers
           ) {
            if canRegisterHotkey(
                identifier: "push-to-talk",
                displayName: "Push-to-Talk",
                hotkeyString: settingsStore.pushToTalkHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "push-to-talk",
                    mode: .pushToTalk,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handlePushToTalkStart()
                        }
                    },
                    onKeyUp: { [weak self] in
                        Task { @MainActor in
                            await self?.handlePushToTalkEnd()
                        }
                    }
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Push-to-Talk", hotkeyString: settingsStore.pushToTalkHotkey)
                }
            }
        }

        if !settingsStore.toggleHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Toggle Recording",
               hotkeyString: settingsStore.toggleHotkey,
               keyCodeValue: settingsStore.toggleHotkeyCode,
               modifiersValue: settingsStore.toggleHotkeyModifiers
           ) {
            if canRegisterHotkey(
                identifier: "toggle-recording",
                displayName: "Toggle Recording",
                hotkeyString: settingsStore.toggleHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "toggle-recording",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleToggleRecording(source: .hotkeyToggle)
                        }
                    },
                    onKeyUp: nil
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Toggle Recording", hotkeyString: settingsStore.toggleHotkey)
                }
            }
        }

        if !settingsStore.meetingHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Toggle Meeting Capture",
               hotkeyString: settingsStore.meetingHotkey,
               keyCodeValue: settingsStore.meetingHotkeyCode,
               modifiersValue: settingsStore.meetingHotkeyModifiers
           ) {
            if canRegisterHotkey(
                identifier: HotkeySlot.toggleMeetingCapture.registrationIdentifier,
                displayName: "Toggle Meeting Capture",
                hotkeyString: settingsStore.meetingHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: HotkeySlot.toggleMeetingCapture.registrationIdentifier,
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleMeetingCaptureToggle()
                        }
                    },
                    onKeyUp: nil
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(
                        displayName: "Toggle Meeting Capture",
                        hotkeyString: settingsStore.meetingHotkey
                    )
                }
            }
        }

        if !settingsStore.recordingIndicatorHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Show Recording Indicator",
               hotkeyString: settingsStore.recordingIndicatorHotkey,
               keyCodeValue: settingsStore.recordingIndicatorHotkeyCode,
               modifiersValue: settingsStore.recordingIndicatorHotkeyModifiers
           ) {
            let slot = HotkeySlot.toggleRecordingIndicator
            if canRegisterHotkey(
                identifier: slot.registrationIdentifier,
                displayName: slot.displayName,
                hotkeyString: settingsStore.recordingIndicatorHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: slot.registrationIdentifier,
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            guard let self else { return }
                            self.settingsStore.floatingIndicatorEnabled.toggle()
                            self.updateFloatingIndicatorVisibility()
                            self.statusBarController.updateMenuState()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(
                        displayName: slot.displayName,
                        hotkeyString: settingsStore.recordingIndicatorHotkey
                    )
                }
            }
        }

        if !settingsStore.copyLastTranscriptHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Copy Last Transcript",
               hotkeyString: settingsStore.copyLastTranscriptHotkey,
               keyCodeValue: settingsStore.copyLastTranscriptHotkeyCode,
               modifiersValue: settingsStore.copyLastTranscriptHotkeyModifiers
           ) {
            Log.hotkey.info("Registering copy-last-transcript: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.copyLastTranscriptHotkey)")

            if canRegisterHotkey(
                identifier: "copy-last-transcript",
                displayName: "Copy Last Transcript",
                hotkeyString: settingsStore.copyLastTranscriptHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "copy-last-transcript",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleCopyLastTranscript()
                        }
                    },
                    onKeyUp: nil
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Copy Last Transcript", hotkeyString: settingsStore.copyLastTranscriptHotkey)
                }
            }
        }

        if !settingsStore.quickCapturePTTHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Note Capture (Push-to-Talk)",
               hotkeyString: settingsStore.quickCapturePTTHotkey,
               keyCodeValue: settingsStore.quickCapturePTTHotkeyCode,
               modifiersValue: settingsStore.quickCapturePTTHotkeyModifiers
           ) {
            Log.hotkey.info("Registering quick-capture-ptt: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.quickCapturePTTHotkey)")

            if canRegisterHotkey(
                identifier: "quick-capture-ptt",
                displayName: "Note Capture (Push-to-Talk)",
                hotkeyString: settingsStore.quickCapturePTTHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "quick-capture-ptt",
                    mode: .pushToTalk,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleQuickCapturePTTStart()
                        }
                    },
                    onKeyUp: { [weak self] in
                        Task { @MainActor in
                            await self?.handleQuickCapturePTTEnd()
                        }
                    }
                )

                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Note Capture (Push-to-Talk)", hotkeyString: settingsStore.quickCapturePTTHotkey)
                }
            }
        }

        if !settingsStore.quickCaptureToggleHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Note Capture (Toggle)",
               hotkeyString: settingsStore.quickCaptureToggleHotkey,
               keyCodeValue: settingsStore.quickCaptureToggleHotkeyCode,
               modifiersValue: settingsStore.quickCaptureToggleHotkeyModifiers
           ) {
            Log.hotkey.info("Registering quick-capture-toggle: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.quickCaptureToggleHotkey)")
            if canRegisterHotkey(
                identifier: "quick-capture-toggle",
                displayName: "Note Capture (Toggle)",
                hotkeyString: settingsStore.quickCaptureToggleHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "quick-capture-toggle",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleQuickCaptureToggle()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Note Capture (Toggle)", hotkeyString: settingsStore.quickCaptureToggleHotkey)
                }
            }
        }

        if !settingsStore.openLibraryHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Open History",
               hotkeyString: settingsStore.openLibraryHotkey,
               keyCodeValue: settingsStore.openLibraryHotkeyCode,
               modifiersValue: settingsStore.openLibraryHotkeyModifiers
           ) {
            Log.hotkey.info("Registering open-library: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.openLibraryHotkey)")
            if canRegisterHotkey(
                identifier: "open-library",
                displayName: "Open History",
                hotkeyString: settingsStore.openLibraryHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "open-library",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            self?.handleOpenHistory()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Open History", hotkeyString: settingsStore.openLibraryHotkey)
                }
            }
        }

        if !settingsStore.cancelOperationHotkey.isEmpty,
           let binding = validatedHotkeyBinding(
               displayName: "Cancel Operation",
               hotkeyString: settingsStore.cancelOperationHotkey,
               keyCodeValue: settingsStore.cancelOperationHotkeyCode,
               modifiersValue: settingsStore.cancelOperationHotkeyModifiers
           ) {
            Log.hotkey.info("Registering cancel-operation: keyCode=\(binding.keyCode), modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)), string=\(self.settingsStore.cancelOperationHotkey)")
            if canRegisterHotkey(
                identifier: "cancel-operation",
                displayName: "Cancel Operation",
                hotkeyString: settingsStore.cancelOperationHotkey,
                keyCode: binding.keyCode,
                modifiers: binding.modifiers,
                registrationState: &registrationState
            ) {
                let didRegister = hotkeyManager.registerHotkey(
                    keyCode: binding.keyCode,
                    modifiers: binding.modifiers,
                    identifier: "cancel-operation",
                    mode: .toggle,
                    onKeyDown: { [weak self] in
                        Task { @MainActor in
                            await self?.handleCancelOperation()
                        }
                    },
                    onKeyUp: nil
                )
                if !didRegister {
                    handleHotkeyRegistrationFailure(displayName: "Cancel Operation", hotkeyString: settingsStore.cancelOperationHotkey)
                }
            }
        }
    }

    private func validatedHotkeyBinding(
        displayName: String,
        hotkeyString: String,
        keyCodeValue: Int,
        modifiersValue: Int
    ) -> (keyCode: UInt32, modifiers: HotkeyManager.ModifierFlags)? {
        guard let keyCode = UInt32(exactly: keyCodeValue),
              let modifiersRawValue = UInt32(exactly: modifiersValue) else {
            Log.hotkey.error("Invalid hotkey values for \(displayName): string=\(hotkeyString), keyCode=\(keyCodeValue), modifiers=\(modifiersValue)")
            AlertManager.shared.showGenericErrorAlert(
                title: "Invalid Hotkey Configuration",
                message: "The saved hotkey for \(displayName) is invalid. Re-record this hotkey in Settings."
            )
            return nil
        }
        return (keyCode: keyCode, modifiers: HotkeyManager.ModifierFlags(rawValue: modifiersRawValue))
    }
    private func handleHotkeyRegistrationFailure(displayName: String, hotkeyString: String) {
        Log.hotkey.error("Failed to register hotkey for \(displayName): \(hotkeyString)")
        AlertManager.shared.showGenericErrorAlert(
            title: "Hotkey Registration Failed",
            message: "Could not register '\(hotkeyString)' for \(displayName). Choose a different shortcut in Settings."
        )
    }

    private func canRegisterHotkey(
        identifier: String,
        displayName: String,
        hotkeyString: String,
        keyCode: UInt32,
        modifiers: HotkeyManager.ModifierFlags,
        registrationState: inout HotkeyRegistrationState
    ) -> Bool {
        if let conflict = registrationState.register(
            identifier: identifier,
            keyCode: keyCode,
            modifiers: modifiers.rawValue
        ) {
            let existingDisplayName = hotkeyDisplayName(for: conflict.existingIdentifier)

            // Pre-save inline feedback in HotkeysSettingsView covers Pindrop-internal
            // conflicts; skip the blocking NSAlert for those. Still refuse to register
            // the duplicate and keep Carbon registration-failure alerts as fallback.
            Log.hotkey.error(
                "Hotkey conflict detected for \(hotkeyString): \(existingDisplayName) conflicts with \(displayName). Ignoring \(displayName)"
            )
            return false
        }

        return true
    }

    private func hotkeyDisplayName(for identifier: String) -> String {
        switch identifier {
        case "toggle-recording":
            return "Toggle Recording"
        case "toggle-meeting-capture":
            return "Toggle Meeting Capture"
        case "toggle-recording-indicator":
            return "Show Recording Indicator"
        case "push-to-talk":
            return "Push-to-Talk"
        case "copy-last-transcript":
            return "Copy Last Transcript"
        case "quick-capture-ptt":
            return "Note Capture (Push-to-Talk)"
        case "quick-capture-toggle":
            return "Note Capture (Toggle)"
        case "open-library":
            return "Open History"
        case "cancel-operation":
            return "Cancel Operation"
        default:
            return identifier
        }
    }
    
    // MARK: - Settings Observation
    
    private func currentSettingsObservationSnapshot() -> SettingsObservationSnapshot {
        SettingsObservationSnapshot(
            outputMode: settingsStore.outputMode,
            automaticDictionaryLearningEnabled: settingsStore.automaticDictionaryLearningEnabled,
            selectedInputDeviceUID: settingsStore.selectedInputDeviceUID,
            selectedAppLocale: settingsStore.selectedAppLocale,
            selectedAppLanguage: settingsStore.selectedAppLanguage,
            floatingIndicatorEnabled: settingsStore.floatingIndicatorEnabled,
            floatingIndicatorType: settingsStore.selectedFloatingIndicatorType,
            aiEnhancementEnabled: LocalOnlySecurityPolicy.allowsExternalAI
                && settingsStore.assignment(for: .transcriptionEnhancement) != nil,
            enableUIContext: settingsStore.enableUIContext,
            vibeLiveSessionEnabled: settingsStore.vibeLiveSessionEnabled,
            streamingFeatureEnabled: settingsStore.streamingFeatureEnabled,
            hotkeys: HotkeySettingsSnapshot(
                hasCompletedOnboarding: settingsStore.hasCompletedOnboarding,
                pushToTalk: HotkeyBindingSnapshot(
                    hotkey: settingsStore.pushToTalkHotkey,
                    keyCode: settingsStore.pushToTalkHotkeyCode,
                    modifiers: settingsStore.pushToTalkHotkeyModifiers
                ),
                toggle: HotkeyBindingSnapshot(
                    hotkey: settingsStore.toggleHotkey,
                    keyCode: settingsStore.toggleHotkeyCode,
                    modifiers: settingsStore.toggleHotkeyModifiers
                ),
                meeting: HotkeyBindingSnapshot(
                    hotkey: settingsStore.meetingHotkey,
                    keyCode: settingsStore.meetingHotkeyCode,
                    modifiers: settingsStore.meetingHotkeyModifiers
                ),
                recordingIndicator: HotkeyBindingSnapshot(
                    hotkey: settingsStore.recordingIndicatorHotkey,
                    keyCode: settingsStore.recordingIndicatorHotkeyCode,
                    modifiers: settingsStore.recordingIndicatorHotkeyModifiers
                ),
                copyLastTranscript: HotkeyBindingSnapshot(
                    hotkey: settingsStore.copyLastTranscriptHotkey,
                    keyCode: settingsStore.copyLastTranscriptHotkeyCode,
                    modifiers: settingsStore.copyLastTranscriptHotkeyModifiers
                ),
                quickCapturePTT: HotkeyBindingSnapshot(
                    hotkey: settingsStore.quickCapturePTTHotkey,
                    keyCode: settingsStore.quickCapturePTTHotkeyCode,
                    modifiers: settingsStore.quickCapturePTTHotkeyModifiers
                ),
                quickCaptureToggle: HotkeyBindingSnapshot(
                    hotkey: settingsStore.quickCaptureToggleHotkey,
                    keyCode: settingsStore.quickCaptureToggleHotkeyCode,
                    modifiers: settingsStore.quickCaptureToggleHotkeyModifiers
                ),
                openLibrary: HotkeyBindingSnapshot(
                    hotkey: settingsStore.openLibraryHotkey,
                    keyCode: settingsStore.openLibraryHotkeyCode,
                    modifiers: settingsStore.openLibraryHotkeyModifiers
                ),
                cancelOperation: HotkeyBindingSnapshot(
                    hotkey: settingsStore.cancelOperationHotkey,
                    keyCode: settingsStore.cancelOperationHotkeyCode,
                    modifiers: settingsStore.cancelOperationHotkeyModifiers
                )
            ),
            mcpServerEnabled: settingsStore.mcpServerEnabled,
            mcpServerPort: settingsStore.mcpServerPort,
            dictationAudioRetention: settingsStore.dictationAudioRetention
        )
    }
    private func observeSettings() {
        settingsStore.objectWillChange
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    guard !self.settingsStore.isApplyingHotkeyUpdate else { return }

                    let snapshot = self.currentSettingsObservationSnapshot()
                    let previousSnapshot = self.lastObservedSettingsSnapshot ?? snapshot
                    self.lastObservedSettingsSnapshot = snapshot

                    if previousSnapshot.outputMode != snapshot.outputMode {
                        let mode: OutputMode = snapshot.outputMode == "clipboard" ? .clipboard : .directInsert
                        self.outputManager.setOutputMode(mode)
                        if mode == .directInsert {
                            self.ensureAccessibilityPermissionForDirectInsert(trigger: "settings-change", showFallbackAlert: true)
                        }
                    }

                    if previousSnapshot.selectedInputDeviceUID != snapshot.selectedInputDeviceUID {
                        self.applyPreferredInputDeviceUID(snapshot.selectedInputDeviceUID)
                        self.inputMuteMonitor?.setPreferredDeviceUID(snapshot.selectedInputDeviceUID)
                    }

                    if previousSnapshot.floatingIndicatorEnabled != snapshot.floatingIndicatorEnabled
                        || previousSnapshot.floatingIndicatorType != snapshot.floatingIndicatorType {
                        // Re-enabling or switching styles clears "hide for 1 hour";
                        // disabling leaves it alone (irrelevant while off).
                        if (!previousSnapshot.floatingIndicatorEnabled && snapshot.floatingIndicatorEnabled)
                            || previousSnapshot.floatingIndicatorType != snapshot.floatingIndicatorType {
                            self.clearFloatingIndicatorTemporaryHiddenState()
                        }
                        self.updateFloatingIndicatorVisibility(previousType: previousSnapshot.floatingIndicatorType)
                    }

                    if !previousSnapshot.streamingFeatureEnabled && snapshot.streamingFeatureEnabled {
                        self.prewarmStreamingEngineIfEnabled()
                    }

                    if previousSnapshot.hotkeys != snapshot.hotkeys {
                        self.registerHotkeysFromSettings()
                        self.floatingIndicatorState.updateHotkeys(
                            toggleHotkey: self.settingsStore.toggleHotkey,
                            pushToTalkHotkey: self.settingsStore.pushToTalkHotkey
                        )
                    }

                    if previousSnapshot.automaticDictionaryLearningEnabled
                        && !snapshot.automaticDictionaryLearningEnabled {
                        self.automaticDictionaryLearningService.cancelObservation()
                    }

                    if previousSnapshot.selectedAppLocale != snapshot.selectedAppLocale
                        || previousSnapshot.selectedAppLanguage != snapshot.selectedAppLanguage {
                        if previousSnapshot.selectedAppLocale != snapshot.selectedAppLocale {
                            Log.app.infoVisible(
                                "Interface locale changed \(previousSnapshot.selectedAppLocale.rawValue) -> \(snapshot.selectedAppLocale.rawValue)"
                            )
                        }
                        if previousSnapshot.selectedAppLanguage != snapshot.selectedAppLanguage {
                            Log.app.infoVisible(
                                "Dictation language changed \(previousSnapshot.selectedAppLanguage.rawValue) -> \(snapshot.selectedAppLanguage.rawValue)"
                            )
                        }
                        Log.app.infoVisible("Reloading localized strings after settings change")
                        self.statusBarController.reloadLocalizedStrings()
                        self.pillFloatingIndicatorController.reloadLocalizedStrings()
                        self.orbFloatingIndicatorController.reloadLocalizedStrings()
                    }

                    if previousSnapshot.mcpServerEnabled != snapshot.mcpServerEnabled
                        || previousSnapshot.mcpServerPort != snapshot.mcpServerPort {
                        self.applyMCPServerSettings()
                    }

                    if previousSnapshot.dictationAudioRetention != snapshot.dictationAudioRetention {
                        self.dictationAudioRetentionService.applyRetentionPolicyChange()
                    }

                    self.statusBarController.updateDynamicItems()
                    if self.isRecording {
                        if self.shouldRunLiveContextSession() {
                            self.startLiveContextSessionIfNeeded(initialSnapshot: self.capturedSnapshot)
                        } else {
                            self.stopLiveContextSession()
                        }
                    } else if previousSnapshot.aiEnhancementEnabled != snapshot.aiEnhancementEnabled
                        || previousSnapshot.enableUIContext != snapshot.enableUIContext
                        || previousSnapshot.vibeLiveSessionEnabled != snapshot.vibeLiveSessionEnabled {
                        self.updateVibeRuntimeStateFromSettings()
                    }
                }
            }
            .store(in: &cancellables)
    }
    
    private func updateFloatingIndicatorVisibility(previousType: FloatingIndicatorType? = nil) {
        guard settingsStore.floatingIndicatorEnabled, !isFloatingIndicatorTemporarilyHidden() else {
            hideAllFloatingIndicators()
            syncFloatingIndicatorFocusTracking()
            return
        }

        let selectedType = configuredFloatingIndicatorType()
        syncFloatingIndicatorFocusTracking()
        
        if isRecording || isProcessing {
            if previousType != selectedType {
                let oldType = activeFloatingIndicatorType ?? previousType ?? selectedType
                if oldType != selectedType {
                    floatingIndicatorPresenters[oldType]?.hide()
                    activeFloatingIndicatorType = selectedType
                    floatingIndicatorPresenters[selectedType]?.showForCurrentState()
                }
            }
            return
        }

        hideAllFloatingIndicators(except: selectedType)
        floatingIndicatorPresenters[selectedType]?.showIdleIndicator()
    }

    private func configuredFloatingIndicatorType() -> FloatingIndicatorType {
        settingsStore.selectedFloatingIndicatorType
    }

    private func recordingTriggerSourceForIndicatorStart(_ type: FloatingIndicatorType) -> RecordingTriggerSource {
        switch type {
        case .pill:
            .pillIndicatorStart
        case .orb:
            .orbIndicatorStart
        case .notch:
            .floatingIndicatorStart
        case .bubble:
            .bubbleIndicatorStart
        case .waveform:
            .floatingIndicatorStart
        }
    }

    private func recordingTriggerSourceForIndicatorStop(_ type: FloatingIndicatorType) -> RecordingTriggerSource {
        switch type {
        case .pill:
            .pillIndicatorStop
        case .orb:
            .orbIndicatorStop
        case .notch:
            .floatingIndicatorStop
        case .bubble:
            .bubbleIndicatorStop
        case .waveform:
            .floatingIndicatorStop
        }
    }

    private func hideAllFloatingIndicators(except selectedType: FloatingIndicatorType? = nil) {
        for (type, presenter) in floatingIndicatorPresenters where type != selectedType {
            presenter.hide()
        }
    }

    private func syncFloatingIndicatorFocusTracking() {
        let trackingMode = Self.floatingIndicatorFocusTrackingMode(
            floatingIndicatorEnabled: settingsStore.floatingIndicatorEnabled,
            isTemporarilyHidden: isFloatingIndicatorTemporarilyHidden(),
            selectedType: configuredFloatingIndicatorType(),
            isRecording: isRecording,
            isProcessing: isProcessing
        )

        if let trackingMode {
            floatingIndicatorFocusTracker.start(mode: trackingMode)
        } else {
            floatingIndicatorFocusTracker.stop()
        }
    }

    private func startRecordingIndicatorSession() {
        guard settingsStore.floatingIndicatorEnabled, !isFloatingIndicatorTemporarilyHidden() else { return }

        let selectedType = configuredFloatingIndicatorType()
        activeFloatingIndicatorType = selectedType
        syncFloatingIndicatorFocusTracking()
        hideAllFloatingIndicators(except: selectedType)
        floatingIndicatorPresenters[selectedType]?.startRecording()
    }

    private func transitionRecordingIndicatorToProcessing() {
        guard settingsStore.floatingIndicatorEnabled else {
            finishIndicatorSession()
            return
        }

        let activeType = activeFloatingIndicatorType ?? configuredFloatingIndicatorType()
        syncFloatingIndicatorFocusTracking()
        floatingIndicatorPresenters[activeType]?.transitionToProcessing()
    }

    private func startProcessingIndicatorSession() {
        guard settingsStore.floatingIndicatorEnabled else { return }
        startRecordingIndicatorSession()
        transitionRecordingIndicatorToProcessing()
    }

    private func finishIndicatorSession() {
        for presenter in floatingIndicatorPresenters.values {
            presenter.finishProcessing()
        }
        activeFloatingIndicatorType = nil


        updateFloatingIndicatorVisibility()
    }


    private func isFloatingIndicatorTemporarilyHidden() -> Bool {
        guard let hiddenUntil = floatingIndicatorHiddenUntil else { return false }
        if Date() >= hiddenUntil {
            floatingIndicatorHiddenUntil = nil
            return false
        }
        return true
    }

    private func clearFloatingIndicatorTemporaryHiddenState() {
        floatingIndicatorHiddenUntil = nil
        floatingIndicatorHiddenTask?.cancel()
        floatingIndicatorHiddenTask = nil
    }

    // MARK: - Live Session Context

    private func shouldRunLiveContextSession() -> Bool {
        LocalOnlySecurityPolicy.allowsExternalAI &&
            settingsStore.assignment(for: .transcriptionEnhancement) != nil &&
            settingsStore.enableUIContext &&
            settingsStore.vibeLiveSessionEnabled
    }

    private func updateVibeRuntimeStateFromSettings() {
        guard LocalOnlySecurityPolicy.allowsExternalAI else {
            settingsStore.updateVibeRuntimeState(.degraded, detail: "External AI is disabled in this local-only build.")
            return
        }
        guard settingsStore.assignment(for: .transcriptionEnhancement) != nil else {
            settingsStore.updateVibeRuntimeState(.degraded, detail: "AI enhancement is disabled.")
            return
        }

        guard settingsStore.enableUIContext else {
            settingsStore.updateVibeRuntimeState(.degraded, detail: "Vibe mode is disabled.")
            return
        }

        guard settingsStore.vibeLiveSessionEnabled else {
            settingsStore.updateVibeRuntimeState(.limited, detail: "Live session updates are disabled.")
            return
        }

        if let contextSessionState {
            let detail = contextEngineService.deriveRuntimeDetail(
                for: contextSessionState.latestSnapshot,
                runtimeState: contextSessionState.runtimeState
            )
            settingsStore.updateVibeRuntimeState(contextSessionState.runtimeState, detail: detail)
            return
        }

        if permissionManager.checkAccessibilityPermission() {
            settingsStore.updateVibeRuntimeState(.ready, detail: "Ready for live session context.")
        } else {
            settingsStore.updateVibeRuntimeState(.limited, detail: "Accessibility permission not granted. Using limited context.")
        }
    }

    private func deriveWorkspaceRoots(
        routingSignal: PromptRoutingSignal?,
        snapshot: ContextSnapshot?
    ) -> [String] {
        var roots: [String] = []

        if let workspacePath = routingSignal?.workspacePath,
           !workspacePath.isEmpty {
            roots.append(workspacePath)
        } else if let documentPath = snapshot?.appContext?.documentPath,
                  !documentPath.isEmpty {
            let parent = (documentPath as NSString).deletingLastPathComponent
            if !parent.isEmpty {
                roots.append(parent)
            }
        }

        return mergeUniqueContextSignals(roots)
    }

    private func mentionRewriteWorkspaceDebugSummary(
        adapterName: String,
        routingSignal: PromptRoutingSignal?,
        snapshot: ContextSnapshot?,
        derivedWorkspaceRoots: [String]
    ) -> String {
        let appContext = snapshot?.appContext
        return """
        adapter=\(adapterName) bundle=\(routingSignal?.appBundleIdentifier ?? "nil") app=\(appContext?.appName ?? "nil") signalWorkspacePresent=\(hasUsableContextValue(routingSignal?.workspacePath)) documentPathPresent=\(hasUsableContextValue(appContext?.documentPath)) windowTitlePresent=\(hasUsableContextValue(appContext?.windowTitle)) focusedValuePresent=\(hasUsableContextValue(appContext?.focusedElementValue)) terminalProvider=\(routingSignal?.terminalProviderIdentifier ?? "nil") isCodeEditorContext=\(routingSignal?.isCodeEditorContext ?? false) derivedWorkspaceRootCount=\(derivedWorkspaceRoots.count)
        """
    }

    private func hasUsableContextValue(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !value.isEmpty
    }

    private func mergeUniqueContextSignals(_ groups: [String]..., limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var merged: [String] = []

        for group in groups {
            for value in group {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                if seen.insert(normalized).inserted {
                    merged.append(normalized)
                }
                if merged.count >= limit {
                    return merged
                }
            }
        }

        return merged
    }

    private func buildSessionTransitionSignature(
        snapshot: ContextSnapshot,
        activeFilePath: String?,
        workspacePath: String?
    ) -> String {
        let signature = snapshot.transitionSignature
        return [
            signature.bundleIdentifier,
            signature.windowTitle,
            signature.focusedElementRole,
            signature.documentPath,
            signature.selectedText,
            activeFilePath,
            workspacePath
        ]
        .map { $0?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        .joined(separator: "|")
    }

    private func shouldAppendTransition(
        signature: String,
        trigger: ContextSessionUpdateTrigger,
        in session: ContextSessionState
    ) -> Bool {
        guard trigger != .recordingStart else { return true }
        guard let lastSignature = session.transitions.last?.transitionSignature else { return true }
        return lastSignature != signature
    }

    private func currentLiveSessionContext() -> AIEnhancementService.LiveSessionContext? {
        guard let contextSessionState else { return nil }

        let enrichment = contextSessionState.latestAdapterEnrichment
        let latestTransition = contextSessionState.transitions.last

        let fileTagCandidates = mergeUniqueContextSignals(
            enrichment?.fileTagCandidates ?? [],
            contextSessionState.transitions.compactMap { $0.activeFilePath },
            contextSessionState.transitions.flatMap { $0.contextTags }
        )

        return AIEnhancementService.LiveSessionContext(
            runtimeState: contextSessionState.runtimeState,
            latestAppName: contextSessionState.latestSnapshot.appContext?.appName,
            latestWindowTitle: contextSessionState.latestSnapshot.appContext?.windowTitle,
            activeFilePath: latestTransition?.activeFilePath ?? enrichment?.activeFilePath ?? contextSessionState.latestSnapshot.appContext?.documentPath,
            activeFileConfidence: latestTransition?.activeFileConfidence ?? enrichment?.activeFileConfidence ?? 0,
            workspacePath: latestTransition?.workspacePath ?? contextSessionState.latestRoutingSignal.workspacePath ?? enrichment?.workspacePath,
            workspaceConfidence: latestTransition?.workspaceConfidence ?? enrichment?.workspaceConfidence ?? 0,
            fileTagCandidates: fileTagCandidates,
            styleSignals: enrichment?.styleSignals ?? [],
            codingSignals: enrichment?.codingSignals ?? [],
            transitions: contextSessionState.transitions
        ).bounded()
    }

    private func startLiveContextSessionIfNeeded(initialSnapshot: ContextSnapshot?) {
        guard isRecording else { return }
        guard shouldRunLiveContextSession() else {
            stopLiveContextSession()
            updateVibeRuntimeStateFromSettings()
            return
        }

        liveContextKeyRefreshGate.setEnabled(true)
        installContextSessionObserversIfNeeded()

        if contextSessionPollTimer == nil {
            let timer = Timer.scheduledTimer(withTimeInterval: contextSessionPollInterval, repeats: true) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    guard self.isRecording, self.shouldRunLiveContextSession() else { return }
                    self.requestContextSessionRefresh(trigger: .poll)
                }
            }
            timer.tolerance = 0.2
            RunLoop.main.add(timer, forMode: .common)
            contextSessionPollTimer = timer
        }

        if contextSessionState == nil {
            requestContextSessionRefresh(trigger: .recordingStart, snapshotOverride: initialSnapshot)
        }
    }

    private func stopLiveContextSession() {
        liveContextKeyRefreshGate.setEnabled(false)
        contextSessionPollTimer?.invalidate()
        contextSessionPollTimer = nil
        removeContextSessionObserversIfNeeded()
        cancelPendingContextSessionRefresh()
        contextSessionState = nil
        lastFocusOrWindowUpdateAt = nil
    }

    private func suspendLiveContextSessionUpdates() {
        liveContextKeyRefreshGate.setEnabled(false)
        contextSessionPollTimer?.invalidate()
        contextSessionPollTimer = nil
        removeContextSessionObserversIfNeeded()
        cancelPendingContextSessionRefresh()
    }

    private func installContextSessionObserversIfNeeded() {
        guard contextSessionAppActivationObserver == nil else { return }

        contextSessionAppActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                guard self.isRecording, self.shouldRunLiveContextSession() else { return }
                self.requestContextSessionRefresh(trigger: .frontmostAppChange)
            }
        }
    }

    private func removeContextSessionObserversIfNeeded() {
        if let contextSessionAppActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(contextSessionAppActivationObserver)
            self.contextSessionAppActivationObserver = nil
        }
    }

    private func scheduleFocusOrWindowContextRefreshIfNeeded() {
        guard isRecording, shouldRunLiveContextSession() else { return }

        let now = Date()
        if let lastFocusOrWindowUpdateAt,
           now.timeIntervalSince(lastFocusOrWindowUpdateAt) < contextSessionFocusUpdateThrottle {
            return
        }

        lastFocusOrWindowUpdateAt = now
        requestContextSessionRefresh(trigger: .focusOrWindowChange)
    }

    private func cancelPendingContextSessionRefresh() {
        contextSessionRefreshGeneration &+= 1
        contextSessionPendingRefresh = nil
        contextSessionRefreshTask?.cancel()
        contextSessionRefreshTask = nil
    }

    /// Coalesces concurrent live-context triggers into one owner task. While a
    /// refresh is suspended, later triggers replace the pending request so only
    /// the latest work runs after the active refresh finishes.
    private func requestContextSessionRefresh(
        trigger: ContextSessionUpdateTrigger,
        snapshotOverride: ContextSnapshot? = nil
    ) {
        guard isRecording, shouldRunLiveContextSession() else { return }

        if contextSessionRefreshTask != nil {
            contextSessionPendingRefresh = (trigger, snapshotOverride)
            return
        }

        contextSessionRefreshGeneration &+= 1
        let generation = contextSessionRefreshGeneration
        contextSessionPendingRefresh = nil
        contextSessionRefreshTask = Task { @MainActor [weak self] in
            await self?.runContextSessionRefreshOwner(
                initialTrigger: trigger,
                initialSnapshotOverride: snapshotOverride,
                generation: generation
            )
        }
    }

    private func runContextSessionRefreshOwner(
        initialTrigger: ContextSessionUpdateTrigger,
        initialSnapshotOverride: ContextSnapshot?,
        generation: UInt64
    ) async {
        defer {
            if contextSessionRefreshGeneration == generation {
                contextSessionRefreshTask = nil
            }
        }

        var nextTrigger = initialTrigger
        var nextSnapshotOverride = initialSnapshotOverride

        while !Task.isCancelled {
            guard contextSessionRefreshGeneration == generation else { return }
            guard isRecording, shouldRunLiveContextSession() else { return }

            await updateContextSession(
                trigger: nextTrigger,
                snapshotOverride: nextSnapshotOverride,
                generation: generation
            )

            guard contextSessionRefreshGeneration == generation else { return }
            guard !Task.isCancelled else { return }

            guard let pending = contextSessionPendingRefresh else { return }
            contextSessionPendingRefresh = nil
            nextTrigger = pending.trigger
            nextSnapshotOverride = pending.snapshotOverride
        }
    }

    private func updateContextSession(
        trigger: ContextSessionUpdateTrigger,
        snapshotOverride: ContextSnapshot? = nil,
        generation: UInt64
    ) async {
        guard isRecording else { return }
        guard settingsStore.enableUIContext else { return }
        guard contextSessionRefreshGeneration == generation else { return }

        let clipboardText = settingsStore.enableClipboardContext ? capturedContext?.clipboardText : nil
        let snapshot = snapshotOverride ?? contextEngineService.captureSnapshot(clipboardText: clipboardText)

        let routingSignal = PromptRoutingSignal.from(
            snapshot: snapshot,
            adapterRegistry: appContextAdapterRegistry
        )

        var adapterCapabilities: AppAdapterCapabilities?
        var adapterEnrichment: AppRuntimeEnrichment?

        if let bundleIdentifier = snapshot.appContext?.bundleIdentifier {
            let adapter = appContextAdapterRegistry.adapter(for: bundleIdentifier)
            adapterCapabilities = adapter.capabilities
            adapterEnrichment = appContextAdapterRegistry.enrichment(for: snapshot, routingSignal: routingSignal)
        }

        let workspaceRoots = deriveWorkspaceRoots(routingSignal: routingSignal, snapshot: snapshot)
        let workspaceInsights = await mentionRewriteService.deriveWorkspaceInsights(
            workspaceRoots: workspaceRoots,
            activeDocumentPath: snapshot.appContext?.documentPath
        )

        // Drop any intermediate work that finished after stop/reset or a newer
        // owner generation took over. Nothing above mutates session state.
        guard contextSessionRefreshGeneration == generation, !Task.isCancelled else { return }
        guard isRecording, settingsStore.enableUIContext else { return }

        capturedSnapshot = snapshot
        capturedRoutingSignal = routingSignal
        _ = promptRoutingResolver.resolve(signal: routingSignal)
        capturedAdapterCapabilities = adapterCapabilities

        let activeFilePath = workspaceInsights.activeDocumentRelativePath
            ?? adapterEnrichment?.activeFilePath
            ?? snapshot.appContext?.documentPath

        let activeFileConfidence = max(
            workspaceInsights.activeDocumentConfidence,
            adapterEnrichment?.activeFileConfidence ?? 0
        )

        let workspacePath = routingSignal.workspacePath
            ?? workspaceInsights.normalizedWorkspaceRoots.first
            ?? adapterEnrichment?.workspacePath

        let workspaceConfidence = max(
            workspaceInsights.workspaceConfidence,
            adapterEnrichment?.workspaceConfidence ?? 0
        )

        let contextTags = mergeUniqueContextSignals(
            workspaceInsights.fileTagCandidates,
            adapterEnrichment?.fileTagCandidates ?? [],
            adapterEnrichment?.styleSignals ?? [],
            adapterEnrichment?.codingSignals ?? []
        )

        let transitionSignature = buildSessionTransitionSignature(
            snapshot: snapshot,
            activeFilePath: activeFilePath,
            workspacePath: workspacePath
        )

        let runtimeState = contextEngineService.deriveRuntimeState(
            for: snapshot,
            adapterCapabilities: adapterCapabilities
        )

        let transition = ContextSessionTransition(
            timestamp: snapshot.timestamp,
            trigger: trigger,
            snapshot: snapshot,
            activeFilePath: activeFilePath,
            activeFileConfidence: activeFileConfidence,
            workspacePath: workspacePath,
            workspaceConfidence: workspaceConfidence,
            outputMode: settingsStore.outputMode,
            contextTags: contextTags,
            transitionSignature: transitionSignature
        )

        if var contextSessionState {
            contextSessionState.latestSnapshot = snapshot
            contextSessionState.latestRoutingSignal = routingSignal
            contextSessionState.latestAdapterCapabilities = adapterCapabilities
            contextSessionState.latestAdapterEnrichment = adapterEnrichment
            contextSessionState.runtimeState = runtimeState

            if shouldAppendTransition(
                signature: transitionSignature,
                trigger: trigger,
                in: contextSessionState
            ) {
                contextSessionState.appendTransition(transition)
            }

            self.contextSessionState = contextSessionState
        } else {
            self.contextSessionState = ContextSessionState(
                startedAt: recordingStartTime ?? Date(),
                latestSnapshot: snapshot,
                latestRoutingSignal: routingSignal,
                latestAdapterCapabilities: adapterCapabilities,
                latestAdapterEnrichment: adapterEnrichment,
                runtimeState: runtimeState,
                transitions: [transition]
            )
        }

        let runtimeDetail = contextEngineService.deriveRuntimeDetail(
            for: snapshot,
            runtimeState: runtimeState
        )
        settingsStore.updateVibeRuntimeState(runtimeState, detail: runtimeDetail)
    }

    
    // MARK: - Recording Flow

    /// Single mode-aware stop entry for user actions and controlled capture-limit
    /// finalization. Claiming occurs synchronously before the first suspension so
    /// simultaneous events cannot stop or transcribe the same recording twice.
    private func dispatchRecordingStop() async throws {
        guard isRecording else { return }
        let route = RecordingStopRoute.resolve(
            isQuickCapture: isQuickCaptureMode,
            noteAppendEditorID: isNoteAppendMode ? noteAppendEditorID : nil,
            isManualTranscription: isRecordingFeatureCaptureActive
        )
        guard let claim = recordingStopAdmission.claim(route) else {
            Log.app.debug("Ignoring duplicate recording stop request")
            return
        }

        let recoveryID = claim.route == .manualTranscription ? nil : activeDictationRecoveryID
        if let recoveryID {
            do {
                try dictationRecoveryStore.markProcessing(id: recoveryID)
            } catch {
                recordingStopAdmission.release(claim)
                throw error
            }
        }

        let token = operationController.begin()
        let operationTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRecordingStop(route: claim.route, token: token)
        }
        activeOperationTask = operationTask

        defer {
            if activeOperationTask == operationTask {
                activeOperationTask = nil
            }
            // Only frees the gate if this claim is still current. Cancel may have
            // already invalidated it so a newer stop can proceed.
            recordingStopAdmission.release(claim)
        }

        do {
            try await operationTask.value
            if let recoveryID {
                if try dictationRecoveryStore.session(id: recoveryID).state == .processing {
                    try dictationRecoveryStore.complete(id: recoveryID)
                } else if dictationRecoveryStore.hasAudio(id: recoveryID) {
                    showRecoverableRecordingToast(id: recoveryID, wasExplicitlyCanceled: false)
                }
                if activeDictationRecoveryID == recoveryID {
                    activeDictationRecoveryID = nil
                }
            }
        } catch {
            if Self.isTaskCancellation(error) {
                Log.app.info("Recording stop interrupted; recoverable audio was preserved")
                return
            }
            if let recoveryID {
                _ = try? dictationRecoveryStore.markFailed(id: recoveryID, message: error.localizedDescription)
                if activeDictationRecoveryID == recoveryID {
                    activeDictationRecoveryID = nil
                }
            }
            // A superseded generation was already cancelled; do not surface its failure.
            guard operationController.isCurrent(token) else { return }
            throw error
        }
    }

    private func performRecordingStop(
        route: RecordingStopRoute,
        token: DictationOperationToken
    ) async throws {
        switch route {
        case .dictation:
            try await stopRecordingAndTranscribe(token: token)
        case .quickCapture:
            if let enhancedNote = try await stopRecordingAndTranscribeForQuickCapture(token: token) {
                try ensureOperationCurrent(token)
                openNoteEditorWithEnhancedNote(enhancedNote)
            }
            isQuickCaptureMode = false
        case .noteAppend(let editorID):
            if let text = try await stopRecordingAndTranscribeForNoteAppend(token: token) {
                try ensureOperationCurrent(token)
                NotificationCenter.default.post(
                    name: .noteSpeakToAppendTranscript,
                    object: nil,
                    userInfo: ["editorID": editorID, "text": text]
                )
            }
            clearNoteAppendMode()
        case .manualTranscription:
            try await stopManualTranscriptionRecording(token: token)
        }
    }
    
    private func handlePushToTalkStart() async {
        guard !isRecording && !isProcessing else { return }
        guard NoteAppendGate.canStartGlobalDictation(isNoteAppendListening: isNoteAppendMode) else {
            Log.app.info("Refuse global dictation: note-append listening is active")
            return
        }

        do {
            try await startRecording(source: .hotkeyPushToTalk)
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to start recording: \(error)")
            handleRecordingStartFailure(error, source: .hotkeyPushToTalk)
        }
    }
    
    private func handlePushToTalkEnd() async {
        // Note-append is not started by global PTT, so a PTT keyup must not
        // cancel an in-editor speak-to-append session.
        if isNoteAppendMode {
            Log.app.debug("Ignore global PTT end during note-append listening")
            return
        }
        guard isRecording else { return }

        do {
            try await dispatchRecordingStop()
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to stop recording: \(error)")
        }
    }

    // MARK: - Quick Capture Handlers (Push-to-Talk)

    private func handleQuickCapturePTTStart() async {
        guard !isRecording && !isProcessing else { return }
        guard NoteAppendGate.canStartGlobalDictation(isNoteAppendListening: isNoteAppendMode) else {
            Log.app.info("Refuse quick-capture: note-append listening is active")
            return
        }

        isQuickCaptureMode = true
        quickCaptureTranscription = nil

        do {
            try await startRecording(source: .hotkeyQuickCapturePTT)
        } catch {
            self.error = error
            isQuickCaptureMode = false
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to start quick capture recording: \(error)")
            handleRecordingStartFailure(error, source: .hotkeyQuickCapturePTT)
        }
    }

    private func handleQuickCapturePTTEnd() async {
        guard isRecording && isQuickCaptureMode else { return }

        do {
            try await dispatchRecordingStop()
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to stop quick capture recording: \(error)")
        }

        isQuickCaptureMode = false
    }

    // MARK: - Quick Capture Handlers (Toggle)

    private func handleQuickCaptureToggle() async {
        if isRecording && isQuickCaptureMode {
            do {
                try await dispatchRecordingStop()
            } catch {
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to stop quick capture recording: \(error)")
            }
            isQuickCaptureMode = false
        } else if !isRecording && !isProcessing {
            guard NoteAppendGate.canStartGlobalDictation(isNoteAppendListening: isNoteAppendMode) else {
                Log.app.info("Refuse quick-capture toggle: note-append listening is active")
                return
            }
            isQuickCaptureMode = true
            quickCaptureTranscription = nil

            do {
                try await startRecording(source: .hotkeyQuickCaptureToggle)
            } catch {
                self.error = error
                isQuickCaptureMode = false
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to start quick capture recording: \(error)")
                handleRecordingStartFailure(error, source: .hotkeyQuickCaptureToggle)
            }
        }
    }

    // MARK: - Speak-to-Append (open note editor)

    private func handleNoteAppendStart(editorID: UUID) async {
        guard NoteAppendGate.canStartNoteAppend(isRecording: isRecording, isProcessing: isProcessing) else {
            Log.app.info("Refuse note-append listening: global dictation or processing is active")
            return
        }

        isNoteAppendMode = true
        noteAppendEditorID = editorID
        NoteAppendListeningCoordinator.shared.state.startListening(editorID: editorID)

        do {
            try await startRecording(source: .noteAppend)
        } catch {
            self.error = error
            clearNoteAppendMode()
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to start note-append recording: \(error)")
            handleRecordingStartFailure(error, source: .noteAppend)
        }
    }

    private func handleNoteAppendStop(editorID: UUID) async {
        guard isRecording && isNoteAppendMode else {
            // Allow stop when only processing state is stuck, or ignore stale stop.
            if noteAppendEditorID == editorID, !isProcessing {
                clearNoteAppendMode()
            }
            return
        }
        guard noteAppendEditorID == editorID else {
            Log.app.info("Ignore note-append stop for non-active editor")
            return
        }

        do {
            try await dispatchRecordingStop()
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            Log.app.error("Failed to stop note-append recording: \(error)")
        }

        if !isRecording { clearNoteAppendMode() }
    }

    private func clearNoteAppendMode() {
        isNoteAppendMode = false
        noteAppendEditorID = nil
        NoteAppendListeningCoordinator.shared.state.finishSession()
    }

    private func stopRecordingAndTranscribeForNoteAppend(token: DictationOperationToken) async throws -> String? {
        guard recordingStartTime != nil else {
            Log.app.warning("stopRecordingAndTranscribeForNoteAppend called but recordingStartTime is nil")
            return nil
        }

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        var didResetProcessingState = false

        statusBarController.setProcessingState()
        NoteAppendListeningCoordinator.shared.state.transitionToProcessing()
        // No global indicator session was started for note-append.

        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        let audioData: Data
        do {
            audioData = try await audioRecorder.stopRecording()
            try ensureOperationCurrent(token)
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Failed to stop note-append recording: \(error)")
            throw error
        }

        guard !audioData.isEmpty else {
            Log.app.warning("No audio data recorded for note-append")
            handleNoSpeechDetected(context: "note-append")
            return nil
        }

        let diarizationEnabled = Self.dictationUsesSpeakerDiarization

        let transcriptionOutput: TranscriptionOutput
        do {
            transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: diarizationEnabled,
                options: makeTranscriptionOptions(),
                diarizationOptions: .init(),
                diarizationFailurePolicy: .bestEffort,
                progressHandler: makeTranscriptionProgressHandler()
            )
            try ensureOperationCurrent(token)
        } catch let error as TranscriptionService.TranscriptionError {
            // Stale/cancelled operations must not toast or mutate UI after a newer session started.
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Note-append transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let message = if case .modelNotLoaded = error {
                "No model loaded. Please download a model in Settings."
            } else {
                "Transcription failed: \(error.localizedDescription)"
            }
            toastService.show(ToastPayload(message: message, style: .error))
            throw error
        } catch {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Note-append transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            throw error
        }

        try ensureOperationCurrent(token)
        let transcribedText = transcriptionOutput.text
        var (textAfterReplacements, appliedReplacements) = try dictionaryStore.applyReplacements(to: transcribedText)
        textAfterReplacements = normalizedTranscriptionText(textAfterReplacements)

        guard !isTranscriptionEffectivelyEmpty(textAfterReplacements) else {
            handleNoSpeechDetected(context: "note-append")
            return nil
        }
        self.lastAppliedReplacements = appliedReplacements
        try? dictionaryStore.recordVocabularyHits(in: textAfterReplacements)

        if !appliedReplacements.isEmpty {
            Log.app.info("Applied \(appliedReplacements.count) dictionary replacements (note-append)")
        }

        Log.app.info("Note-append transcript ready (\(textAfterReplacements.count) chars)")
        return textAfterReplacements
    }

    private func stopRecordingAndTranscribeForQuickCapture(token: DictationOperationToken) async throws -> AIEnhancementService.EnhancedNote? {
        guard recordingStartTime != nil else {
            Log.app.warning("stopRecordingAndTranscribeForQuickCapture called but recordingStartTime is nil")
            return nil
        }

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        var didResetProcessingState = false

        statusBarController.setProcessingState()

        transitionRecordingIndicatorToProcessing()

        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        let audioData: Data
        do {
            audioData = try await audioRecorder.stopRecording()
            try ensureOperationCurrent(token)
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Failed to stop recording: \(error)")
            throw error
        }

        guard !audioData.isEmpty else {
            Log.app.warning("No audio data recorded")
            handleNoSpeechDetected(context: "quick-capture")
            return nil
        }

        let diarizationEnabled = Self.dictationUsesSpeakerDiarization

        let transcriptionOutput: TranscriptionOutput
        do {
            transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: diarizationEnabled,
                options: makeTranscriptionOptions(),
                diarizationOptions: .init(),
                diarizationFailurePolicy: .bestEffort,
                progressHandler: makeTranscriptionProgressHandler()
            )
            try ensureOperationCurrent(token)
        } catch let error as TranscriptionService.TranscriptionError {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            let message = if case .modelNotLoaded = error {
                localized("No model loaded. Please download a model in Settings.", locale: locale)
            } else {
                String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription)
            }
            toastService.show(
                ToastPayload(message: message, style: .error)
            )
            throw error
        } catch {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            throw error
        }

        if diarizationEnabled {
            let segmentCount = transcriptionOutput.diarizedSegments?.count ?? 0
            if segmentCount > 0 {
                Log.app.info("Quick capture diarization produced \(segmentCount) segments")
            } else {
                Log.app.info("Quick capture diarization produced no attributed segments")
            }
        }

        let transcribedText = transcriptionOutput.text

        var (textAfterReplacements, appliedReplacements) = try dictionaryStore.applyReplacements(to: transcribedText)
        textAfterReplacements = normalizedTranscriptionText(textAfterReplacements)

        guard !isTranscriptionEffectivelyEmpty(textAfterReplacements) else {
            handleNoSpeechDetected(context: "quick-capture")
            return nil
        }
        self.lastAppliedReplacements = appliedReplacements
        try? dictionaryStore.recordVocabularyHits(in: textAfterReplacements)

        if !appliedReplacements.isEmpty {
            Log.app.info("Applied \(appliedReplacements.count) dictionary replacements")
        }

        if LocalOnlySecurityPolicy.allowsExternalAI,
           let noteAssignment = settingsStore.resolveAssignment(for: .noteEnhancement) {
            do {
                let notePrompt = resolvedPrompt(
                    for: noteAssignment,
                    fallback: SettingsStore.Defaults.noteEnhancementPrompt
                )
                let vocabularyWords = try dictionaryStore.fetchAllVocabularyWords().map(\.word)
                let replacementCorrections = appliedReplacements.map {
                    AIEnhancementService.ContextMetadata.ReplacementCorrection(
                        original: $0.original,
                        replacement: $0.replacement
                    )
                }
                let enhancementContext = AIEnhancementService.ContextMetadata(
                    hasClipboardText: false,
                    clipboardText: nil,
                    hasClipboardImage: false,
                    appContext: nil,
                    vocabularyWords: vocabularyWords,
                    replacementCorrections: replacementCorrections
                )

                let existingTags = (try? notesStore.getAllUniqueTags()) ?? []
                let enhancedNote = try await aiEnhancementService.enhanceNote(
                    content: textAfterReplacements,
                    apiEndpoint: noteAssignment.endpoint ?? "",
                    apiKey: noteAssignment.apiKey,
                    model: noteAssignment.modelID,
                    contentPrompt: notePrompt,
                    generateMetadata: true,
                    existingTags: existingTags,
                    context: enhancementContext,
                    provider: noteAssignment.kind
                )
                try ensureOperationCurrent(token)
                Log.app.info("Note enhancement completed: title='\(enhancedNote.title)', tags=\(enhancedNote.tags.count)")
                let normalizedEnhancedContent = normalizedTranscriptionText(enhancedNote.content)
                guard !isTranscriptionEffectivelyEmpty(normalizedEnhancedContent) else {
                    handleNoSpeechDetected(context: "quick-capture")
                    return nil
                }
                return AIEnhancementService.EnhancedNote(
                    content: normalizedEnhancedContent,
                    title: enhancedNote.title,
                    tags: enhancedNote.tags
                )
            } catch {
                if Self.isTaskCancellation(error) || !operationController.isCurrent(token) {
                    throw CancellationError()
                }
                Log.app.error("Note enhancement failed: \(error)")
            }
        }

        try ensureOperationCurrent(token)
        let fallbackTitle = aiEnhancementService.generateFallbackTitle(from: textAfterReplacements)
        return AIEnhancementService.EnhancedNote(
            content: textAfterReplacements,
            title: fallbackTitle,
            tags: []
        )
    }

    private func openNoteEditorWithEnhancedNote(_ enhancedNote: AIEnhancementService.EnhancedNote) {
        let newNote = NoteSchema.Note(
            title: enhancedNote.title,
            content: enhancedNote.content,
            tags: enhancedNote.tags,
            sourceTranscriptionID: nil
        )

        noteEditorWindowController.show(note: newNote, isNewNote: true)

        Log.app.info("Opened note editor with enhanced note")
    }

    private func handleToggleRecording(source: RecordingTriggerSource) async {
        if isRecording {
            do {
                if isNoteAppendMode {
                    guard noteAppendEditorID != nil else { return }
                    try await dispatchRecordingStop()
                } else {
                    try await dispatchRecordingStop()
                }
            } catch {
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to stop recording: \(error)")
            }
        } else if !isProcessing {
            guard NoteAppendGate.canStartGlobalDictation(isNoteAppendListening: isNoteAppendMode) else {
                Log.app.info("Refuse global dictation toggle: note-append listening is active")
                return
            }
            do {
                try await startRecording(source: source)
            } catch {
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to start recording: \(error)")
                handleRecordingStartFailure(error, source: source)
            }
        }
    }
    
    private func startRecording(source: RecordingTriggerSource) async throws {
        automaticDictionaryLearningService.cancelObservation()
        logRecordingStartAttempt(source: source)

        // If permissions were granted after launch, recreate global event taps
        // so escape-to-cancel and modifier tracking become available mid-session.
        ensureGlobalKeyMonitorsIfPossible()

        await beginStreamingSessionIfAvailable()

        // Retention encodes a native-rate copy so kept audio isn't the 16 kHz ASR feed.
        audioRecorder.retainNativeAudioForSession =
            settingsStore.dictationAudioRetention != .off

        let recoverySession: DictationRecoverySession
        do {
            recoverySession = try dictationRecoveryStore.begin()
            activeDictationRecoveryID = recoverySession.id
            audioRecorder.persistentSpoolDirectoryURL = dictationRecoveryStore.workspaceURL(
                for: recoverySession.id
            )
        } catch {
            Log.audio.error("Unable to create durable recording workspace: \(error.localizedDescription)")
            throw error
        }

        let didStartRecording: Bool
        do {
            didStartRecording = try await audioRecorder.startRecording()
        } catch {
            try? dictationRecoveryStore.complete(id: recoverySession.id)
            if activeDictationRecoveryID == recoverySession.id {
                activeDictationRecoveryID = nil
            }
            if streamingSession.isSessionActive {
                await streamingSession.cancel()
            }
            Log.app.error("Audio engine failed to start: \(error)")
            throw error
        }

        guard didStartRecording else {
            try? dictationRecoveryStore.complete(id: recoverySession.id)
            if activeDictationRecoveryID == recoverySession.id {
                activeDictationRecoveryID = nil
            }
            if streamingSession.isSessionActive {
                await streamingSession.cancel()
            }
            Log.app.debug("Recording start already in progress; ignoring duplicate start request")
            return
        }

        if settingsStore.pauseMediaOnRecording || settingsStore.muteAudioDuringRecording {
            mediaPauseService.beginRecordingSession(
                pauseMedia: settingsStore.pauseMediaOnRecording,
                muteSystemAudio: settingsStore.muteAudioDuringRecording
            )
        }
        
        isRecording = true
        recordingStartTime = recoverySession.startedAt
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        cancelPendingContextSessionRefresh()
        contextSessionState = nil
        lastFocusOrWindowUpdateAt = nil

        if settingsStore.enableClipboardContext || settingsStore.enableUIContext {
            let clipboardText = settingsStore.enableClipboardContext ? contextCaptureService.captureClipboardText() : nil
            capturedContext = CapturedContext(clipboardText: clipboardText)

            // Capture AX-based UI context when enabled (non-blocking)
            var appContext: AppContextInfo? = nil
            var captureWarnings: [ContextCaptureWarning] = []
            if settingsStore.enableUIContext {
                let result = contextEngineService.captureAppContext()
                appContext = result.appContext
                captureWarnings = result.warnings
                if !captureWarnings.isEmpty {
                    Log.app.debug("UI context capture warnings: \(captureWarnings.map(\.localizedDescription).joined(separator: ", "))")
                }
                if let ctx = appContext {
                    Log.app.info("Captured UI context: hasAppName=\(!ctx.appName.isEmpty), hasWindowTitle=\(ctx.windowTitle != nil)")
                }
            }

            capturedSnapshot = ContextSnapshot(
                timestamp: Date(),
                appContext: appContext,
                clipboardText: clipboardText,
                warnings: captureWarnings
            )

            if let snapshot = capturedSnapshot {
                let routingSignal = PromptRoutingSignal.from(
                    snapshot: snapshot,
                    adapterRegistry: appContextAdapterRegistry
                )
                capturedRoutingSignal = routingSignal
                _ = promptRoutingResolver.resolve(signal: routingSignal)

                if let bundleIdentifier = snapshot.appContext?.bundleIdentifier {
                    let adapter = appContextAdapterRegistry.adapter(for: bundleIdentifier)
                    capturedAdapterCapabilities = adapter.capabilities
                    let caps = adapter.capabilities
                    Log.context.info("Adapter context: app=\(caps.displayName) prefix=\(caps.mentionPrefix) fileMentions=\(caps.supportsFileMentions) codeContext=\(caps.supportsCodeContext) docsMentions=\(caps.supportsDocsMentions) diffContext=\(caps.supportsDiffContext) webContext=\(caps.supportsWebContext) chatHistory=\(caps.supportsChatHistory)")
                }
            }
        }

        if shouldRunLiveContextSession() {
            startLiveContextSessionIfNeeded(initialSnapshot: capturedSnapshot)
        } else {
            updateVibeRuntimeStateFromSettings()
        }

        statusBarController.setRecordingState()

        // Speak-to-append uses the in-editor listening chip only — no global orb/pill.
        if source != .noteAppend {
            startRecordingIndicatorSession()
        }
        lastOfferedMeetingPinIdentity = nil
        offerActiveRecordingMeetingPinIfNeeded()
    }

    private func logRecordingStartAttempt(source: RecordingTriggerSource) {
        recordingStartAttemptCounter += 1
        let snapshot = permissionManager.microphoneAuthorizationSnapshot()
        let shortVersion = Bundle.main.appShortVersionString
        let buildVersion = Bundle.main.appBuildVersionString
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "unknown"
        let bundlePath = Bundle.main.bundleURL.path
        let executablePath = Bundle.main.executableURL?.path ?? "unknown"
        let cachedDecision = snapshot.cachedDecision.map { $0 ? "granted" : "denied" } ?? "none"

        Log.app.info(
            "recording_start_attempt id=\(self.recordingStartAttemptCounter) source=\(source.rawValue) resolved=\(String(describing: snapshot.resolvedStatus)) avaudio=\(snapshot.audioApplicationStatus) avcapture=\(snapshot.captureDeviceStatus) requestedThisLaunch=\(snapshot.hasRequestedThisLaunch) cachedDecision=\(cachedDecision) bundleId=\(bundleIdentifier) shortVersion=\(shortVersion) buildVersion=\(buildVersion) pid=\(ProcessInfo.processInfo.processIdentifier) onboardingCompleted=\(self.settingsStore.hasCompletedOnboarding) bundlePath=\(bundlePath) executablePath=\(executablePath)"
        )
    }

    /// Builds transcription options including WhisperKit vocabulary bias words.
    private func makeTranscriptionOptions(
        language: AppLanguage? = nil
    ) -> TranscriptionOptions {
        let bias = (try? dictionaryStore.vocabularyBiasWords()) ?? []
        return TranscriptionOptions(
            language: language ?? settingsStore.selectedAppLanguage,
            vocabularyBiasWords: bias
        )
    }

    private func makeTranscriptionProgressHandler() -> TranscriptionProgressHandler {
        { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.isProcessing else { return }
                self.floatingIndicatorState.updateProcessingProgress(update)
                self.statusBarController.setProcessingProgress(update)
            }
        }
    }

    private func normalizedTranscriptionText(_ text: String) -> String {
        Self.normalizedTranscriptionText(text)
    }

    static func normalizedTranscriptionText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func isTranscriptionEffectivelyEmpty(_ text: String) -> Bool {
        Self.isTranscriptionEffectivelyEmpty(text)
    }

    static func isTranscriptionEffectivelyEmpty(_ text: String) -> Bool {
        let normalizedText = normalizedTranscriptionText(text)
        if normalizedText.isEmpty {
            return true
        }
        return normalizedText.caseInsensitiveCompare("[BLANK AUDIO]") == .orderedSame
    }

    static func shouldPersistHistory(text: String) -> Bool {
        !isTranscriptionEffectivelyEmpty(text)
    }

    /// Dictation transcriptions never diarize: the output is a single-speaker paste
    /// into the target app, and speaker attribution both pollutes it with
    /// "Speaker N:" prefixes and can drop tail words when segment stitching
    /// disagrees with the final transcript. Speaker diarization belongs to meeting
    /// and media transcription jobs, which gate it via `TranscriptionJobOptions`.
    static let dictationUsesSpeakerDiarization = false

    /// The v3 (overlay) streaming gate. Streaming transcription runs whenever the user's
    /// streaming preference says so, independent of any AI-enhancement assignment. Live
    /// text renders in the floating-indicator overlay; the target app receives the final
    /// text once, via a single paste at stop (after dictionary replacements and the
    /// optional post-stop enhancement rewrite).
    ///
    /// Gates that matter: feature flag, quick-capture mode, and floating-indicator
    /// availability. With overlay streaming the live transcript renders in Pindrop's own
    /// indicator overlay and the target app receives one paste at the end, so:
    ///   - `outputMode` no longer gates — clipboard-mode users get the live overlay too;
    ///     the final landing routes through `output(_:)` per mode.
    ///   - The indicator must be available: without an overlay there is nowhere to show
    ///     live text, and streaming has no user-visible benefit over batch. We never
    ///     force-show UI the user disabled or temporarily hid.
    static func shouldUseStreamingTranscription(
        streamingFeatureEnabled: Bool,
        isQuickCaptureMode: Bool,
        floatingIndicatorAvailable: Bool,
        isNoteAppendMode: Bool = false
    ) -> Bool {
        streamingFeatureEnabled
            && !isQuickCaptureMode
            && !isNoteAppendMode
            && floatingIndicatorAvailable
    }

    private func encodeDiarizationSegmentsJSON(_ segments: [DiarizedTranscriptSegment]?) -> String? {
        guard let segments, !segments.isEmpty else {
            return nil
        }

        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encodedData = try encoder.encode(segments)
            return String(data: encodedData, encoding: .utf8)
        } catch {
            Log.app.warning("Failed to encode diarization segments for history: \(error.localizedDescription)")
            return nil
        }
    }

    private func speakerTrainingSegments(
        audioData: Data,
        existingSegments: [DiarizedTranscriptSegment]?
    ) async -> [DiarizedTranscriptSegment] {
        if let existingSegments, !existingSegments.isEmpty {
            return existingSegments
        }

        // Loading the diarization model for every ordinary dictation is expensive
        // and surprising. Speaker learning is opt-in with the diarization feature.
        guard settingsStore.diarizationFeatureEnabled else {
            return []
        }

        do {
            return try await transcriptionService.extractSpeakerProfileSegments(audioData: audioData)
        } catch {
            Log.transcription.warning(
                "Speaker profile training skipped for this dictation: \(error.localizedDescription)"
            )
            return []
        }
    }

    private func shouldUseStreamingTranscriptionForCurrentSession() -> Bool {
        Self.shouldUseStreamingTranscription(
            streamingFeatureEnabled: settingsStore.streamingFeatureEnabled,
            isQuickCaptureMode: isQuickCaptureMode,
            floatingIndicatorAvailable: isFloatingIndicatorAvailable(),
            isNoteAppendMode: isNoteAppendMode
        )
    }

    /// Whether any floating indicator can currently present — the master enable
    /// switch and the temporary "hide for 1 hour" state both suppress it.
    private func isFloatingIndicatorAvailable() -> Bool {
        settingsStore.floatingIndicatorEnabled && !isFloatingIndicatorTemporarilyHidden()
    }

    private func handleNoSpeechDetected(context: String) {
        Log.app.info("No speech detected for \(context); skipping output")
        if let recoveryID = activeDictationRecoveryID {
            _ = try? dictationRecoveryStore.markFailed(
                id: recoveryID,
                message: "No speech was detected. The audio was preserved for retry."
            )
        }
        telemetryService.send(
            .transcriptionEmptyResult,
            parameters: [
                TelemetryParameter.stage: context,
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue
            ]
        )
        toastService.show(
            ToastPayload(
                message: localized(
                    "No speech detected. Try speaking closer to your microphone.",
                    locale: settingsStore.selectedAppLocale.locale
                )
            )
        )
    }

    /// Reports a transcription failure as a telemetry signal. Only the bare error
    /// case label and pipeline stage are sent — never messages or paths.
    private func reportTranscriptionFailureSignal(_ error: Error, stage: String) {
        telemetryService.send(
            .transcriptionFailed,
            parameters: [
                TelemetryParameter.errorCase: TelemetryService.errorCaseName(error),
                TelemetryParameter.stage: stage,
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue,
                TelemetryParameter.model: settingsStore.selectedModel
            ]
        )
    }

    /// Success toast after a paste landed in the target app. Not shown for clipboard-only
    /// fallback (that path gets a separate Copied+Undo toast in B7).
    private func showInsertionSuccessToast(appName: String?, wordCount: Int) {
        let locale = settingsStore.selectedAppLocale.locale
        let trimmedName = appName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = trimmedName.isEmpty
            ? localized("Unknown App", locale: locale)
            : trimmedName
        let format = localized("Inserted into %@", locale: locale)
        let message = String(format: format, locale: locale, displayName)
        toastService.show(
            ToastPayload(
                message: message,
                style: .standard,
                variant: .inserted(wordCount: wordCount)
            )
        )
    }

    private func handleRecordingStartFailure(_ error: Error, source: RecordingTriggerSource) {
        let isHotkeySource: Bool
        switch source {
        case .hotkeyToggle, .hotkeyPushToTalk, .hotkeyQuickCapturePTT, .hotkeyQuickCaptureToggle:
            isHotkeySource = true
        default:
            isHotkeySource = false
        }

        let isNoteAppendSource = source == .noteAppend
        guard isHotkeySource || isNoteAppendSource,
              let audioError = error as? AudioRecorderError,
              case .permissionDenied = audioError else {
            return
        }

        let locale = settingsStore.selectedAppLocale.locale
        toastService.show(
            ToastPayload(
                message: localized("Microphone unavailable", locale: locale),
                // Permission denial is only fixable in System Settings' mic privacy pane —
                // the app's Dictation tab has no permission controls.
                actions: [
                    ToastAction(
                        title: localized("Settings", locale: locale),
                        role: .primary
                    ) {
                        AlertManager.shared.openMicrophoneSettings()
                    }
                ],
                duration: 8.0,
                style: .error,
                variant: .microphoneUnavailable
            )
        )
    }

    private func beginStreamingSessionIfAvailable() async {
        let shouldUseStreaming = shouldUseStreamingTranscriptionForCurrentSession()
        guard shouldUseStreaming else {
            let indicatorAvailable = isFloatingIndicatorAvailable()
            let reasons = [
                settingsStore.streamingFeatureEnabled ? nil : "feature-disabled",
                indicatorAvailable ? nil : "indicator-unavailable",
                isQuickCaptureMode ? "quick-capture-mode" : nil
            ].compactMap { $0 }
            Log.transcription.info("Streaming transcription disabled for session: \(reasons.joined(separator: ","))")
            streamingSession.deactivate()
            return
        }

        await streamingSession.begin()
    }

    /// Resolves prompt overrides, stable built-in identifiers, and persisted preset
    /// UUIDs through one path so every enhancement entry point sends the same text.
    func resolvedPrompt(
        for assignment: ResolvedAssignment,
        fallback: String
    ) -> String {
        if let prompt = assignment.prompt {
            return prompt
        }

        do {
            if let prompt = try promptPresetStore.resolvePrompt(for: assignment.promptPresetID) {
                return prompt
            }
        } catch {
            Log.aiEnhancement.error(
                "Failed to resolve prompt preset \(assignment.promptPresetID ?? "nil"): \(error)"
            )
        }
        return fallback
    }

    /// Runs the post-stop transcriptionEnhancement assignment on `text` with the user's
    /// vocabulary available as spelling/casing context. Used exclusively by the streaming
    /// finalize path — the non-streaming path constructs its own richer context-aware call
    /// with clipboard, app snapshot, mentions, and routing signals.
    ///
    /// Returns nil when no assignment resolves, the text is empty, or the call fails.
    private func runBasicPostStopEnhance(
        text: String,
        vocabularyWords: [String]
    ) async -> StreamingSessionController.PostStopEnhanceOutcome? {
        guard LocalOnlySecurityPolicy.allowsExternalAI else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let assignment = settingsStore.resolveAssignment(for: .transcriptionEnhancement)
        else { return nil }

        let basePrompt = resolvedPrompt(
            for: assignment,
            fallback: SettingsStore.Defaults.aiEnhancementPrompt
        )

        let context = AIEnhancementService.ContextMetadata(
            hasClipboardText: false,
            hasClipboardImage: false,
            appContext: nil,
            vocabularyWords: vocabularyWords
        )

        do {
            // Route through the context-aware overload so streaming finalization gets
            // the same vocabulary spelling/casing guidance and output contract as batch
            // dictation, without injecting clipboard or UI snapshots.
            let result = try await aiEnhancementService.enhanceWithMetrics(
                text: text,
                apiEndpoint: assignment.endpoint ?? "",
                apiKey: assignment.apiKey,
                model: assignment.modelID,
                customPrompt: basePrompt,
                imageBase64: nil,
                context: context,
                provider: assignment.kind
            )
            let sanitized = AIEnhancementService.stripResponsePreamble(result.text)
            return StreamingSessionController.PostStopEnhanceOutcome(
                enhancedText: sanitized,
                modelID: assignment.modelID,
                providerKind: assignment.kind.rawValue,
                usage: result.usage,
                requestSeconds: result.requestSeconds
            )
        } catch {
            if Self.isTaskCancellation(error) {
                Log.aiEnhancement.info("Streaming post-stop enhance cancelled")
                return nil
            }
            Log.aiEnhancement.warning(
                "Streaming post-stop enhance failed: \(error.localizedDescription)")
            toastService.show(
                ToastPayload(
                    message: localized(
                        "AI enhancement failed. Streamed text kept as-is.",
                        locale: settingsStore.selectedAppLocale.locale
                    ),
                    style: .error
                )
            )
            return nil
        }
    }

    private func stopRecordingAndFinalizeStreaming(token: DictationOperationToken) async throws {
        guard let startTime = recordingStartTime else {
            Log.app.warning("stopRecordingAndFinalizeStreaming called but recordingStartTime is nil")
            return
        }

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        let didResetProcessingState = false

        statusBarController.setProcessingState()

        transitionRecordingIndicatorToProcessing()

        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        // Keep the recorded audio: the finalize path re-transcribes it offline so the
        // pasted text gets full-context (pause-aware) punctuation.
        let pipelineClock = ContinuousClock()
        let pipelineStart = pipelineClock.now
        let recordedAudioData: Data
        let audioStopSeconds: Double
        do {
            let audioStopStart = pipelineClock.now
            recordedAudioData = try await audioRecorder.stopRecording()
            audioStopSeconds = audioStopStart.duration(to: pipelineClock.now).pipelineSeconds
            try ensureOperationCurrent(token)
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Failed to stop recording for streaming session: \(error)")
            await streamingSession.cancel()
            throw error
        }

        var outcome = try await streamingSession.finalize(
            recordedAudioData: recordedAudioData,
            recordingDuration: Date().timeIntervalSince(startTime)
        )
        outcome.pipelineMetrics.audioStopSeconds = audioStopSeconds
        outcome.pipelineMetrics.totalSeconds = pipelineStart.duration(to: pipelineClock.now).pipelineSeconds
        Log.app.info("Pipeline timing: \(outcome.pipelineMetrics.logSummary)")
        // Once the final paste landed, the session is committed: a cancel arriving
        // after that point must not drop the transcription from history. Only the
        // not-yet-output path may abort here.
        if !outcome.outputSucceeded {
            try ensureOperationCurrent(token)
        }
        lastAppliedReplacements = outcome.appliedReplacements

        guard !outcome.isEffectivelyEmpty else {
            handleNoSpeechDetected(context: "streaming recording")
            return
        }

        guard Self.shouldPersistHistory(text: outcome.finalText) else {
            return
        }

        let duration = Date().timeIntervalSince(startTime)
        let speakerTrainingSegments = await speakerTrainingSegments(
            audioData: recordedAudioData,
            existingSegments: nil
        )
        do {
            let record = try historyStore.save(
                text: outcome.finalText,
                originalText: outcome.originalStreamedText,
                duration: duration,
                modelUsed: settingsStore.selectedModel,
                enhancedWith: outcome.enhancedWithModel,
                diarizationSegmentsJSON: nil,
                destinationAppName: outcome.destinationAppName,
                destinationAppBundleID: outcome.destinationAppBundleID,
                speakerTrainingSegments: speakerTrainingSegments,
                pipelineMetricsJSON: outcome.pipelineMetrics.hasAnyStage
                    ? outcome.pipelineMetrics.jsonString()
                    : nil
            )
            if let nativeAudio = audioRecorder.takeLastNativeAudio(),
               let nativePCMURL = nativeAudio.takeFileURL() {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatFileURL: nativePCMURL,
                    sampleRate: nativeAudio.sampleRate,
                    recordID: record.id
                )
            } else {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatData: recordedAudioData,
                    recordID: record.id
                )
            }
            updateRecentTranscriptsMenu()
            if outcome.didPaste {
                showInsertionSuccessToast(
                    appName: outcome.destinationAppName,
                    wordCount: outcome.finalText.wordCount
                )
            }
        } catch {
            Log.app.error("Failed to save streamed transcription to history: \(error)")
            if let recoveryID = activeDictationRecoveryID {
                _ = try? dictationRecoveryStore.markFailed(id: recoveryID, message: error.localizedDescription)
            }
        }
    }
    
    private func stopRecordingAndTranscribe(token: DictationOperationToken) async throws {
        guard let startTime = recordingStartTime else {
            Log.app.warning("stopRecordingAndTranscribe called but recordingStartTime is nil")
            return
        }

        if streamingSession.isSessionActive {
            try await stopRecordingAndFinalizeStreaming(token: token)
            return
        }

        let pipelineClock = ContinuousClock()
        let pipelineStart = pipelineClock.now
        var pipelineMetrics = PipelineMetrics(kind: .batch)

        isRecording = false
        mediaPauseService.endRecordingSession()
        suspendLiveContextSessionUpdates()
        isProcessing = true
        var didResetProcessingState = false

        statusBarController.setProcessingState()
        
        transitionRecordingIndicatorToProcessing()
        
        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        let audioData: Data
        do {
            let audioStopStart = pipelineClock.now
            audioData = try await audioRecorder.stopRecording()
            pipelineMetrics.audioStopSeconds = audioStopStart.duration(to: pipelineClock.now).pipelineSeconds
            try ensureOperationCurrent(token)
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Failed to stop recording: \(error)")
            throw error
        }

        guard !audioData.isEmpty else {
            Log.app.warning("No audio data recorded")
            handleNoSpeechDetected(context: "recording")
            return
        }
        
        let duration = Date().timeIntervalSince(startTime)
        
        let diarizationEnabled = Self.dictationUsesSpeakerDiarization

        let transcriptionOutput: TranscriptionOutput
        do {
            let transcriptionStart = pipelineClock.now
            transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: diarizationEnabled,
                options: makeTranscriptionOptions(),
                diarizationOptions: .init(),
                diarizationFailurePolicy: .bestEffort,
                progressHandler: makeTranscriptionProgressHandler()
            )
            pipelineMetrics.transcriptionSeconds = transcriptionStart.duration(to: pipelineClock.now).pipelineSeconds
            try ensureOperationCurrent(token)
        } catch let error as TranscriptionService.TranscriptionError {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            let message = if case .modelNotLoaded = error {
                localized("No model loaded. Please download a model in Settings.", locale: locale)
            } else {
                String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription)
            }
            toastService.show(
                ToastPayload(message: message, style: .error)
            )
            throw error
        } catch {
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else {
                throw CancellationError()
            }
            Log.app.error("Transcription failed: \(error)")
            reportTranscriptionFailureSignal(error, stage: "transcribe")
            resetProcessingState()
            didResetProcessingState = true
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcription failed: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            throw error
        }

        if diarizationEnabled {
            let segmentCount = transcriptionOutput.diarizedSegments?.count ?? 0
            if segmentCount > 0 {
                Log.app.info("Batch diarization produced \(segmentCount) segments")
            } else {
                Log.app.info("Batch diarization produced no attributed segments")
            }
        }

        let diarizationSegmentsJSON = encodeDiarizationSegmentsJSON(transcriptionOutput.diarizedSegments)
        let transcribedText = transcriptionOutput.text

        let textProcessingStart = pipelineClock.now
        var (textAfterReplacements, appliedReplacements) = try dictionaryStore.applyReplacements(to: transcribedText)
        textAfterReplacements = normalizedTranscriptionText(textAfterReplacements)

        guard !isTranscriptionEffectivelyEmpty(textAfterReplacements) else {
            handleNoSpeechDetected(context: "recording")
            return
        }
        self.lastAppliedReplacements = appliedReplacements
        try? dictionaryStore.recordVocabularyHits(in: textAfterReplacements)
        
        if !appliedReplacements.isEmpty {
            Log.app.info("Applied \(appliedReplacements.count) dictionary replacements")
        }
        
        // Mention rewrite: resolve spoken file mentions to app-specific syntax
        // Runs whenever adapter supports file mentions AND workspace roots are derivable
        // (not gated by isCodeEditorContext — enables Antigravity and other non-IDE adapters)
        var textAfterMentions = textAfterReplacements
        var mentionFormattingCapabilities = capturedAdapterCapabilities
        let derivedWorkspaceRoots = deriveWorkspaceRoots(
            routingSignal: capturedRoutingSignal,
            snapshot: capturedSnapshot
        )
        let shouldUsePlaceholderMentions = LocalOnlySecurityPolicy.allowsExternalAI
            && settingsStore.resolveAssignment(for: .transcriptionEnhancement) != nil
        if let capabilities = capturedAdapterCapabilities,
           capabilities.supportsFileMentions {
            let resolvedMentionFormatting = settingsStore.resolveMentionFormatting(
                editorBundleIdentifier: capturedRoutingSignal?.appBundleIdentifier,
                terminalProviderIdentifier: capturedRoutingSignal?.terminalProviderIdentifier,
                adapterDefaultTemplate: capabilities.mentionTemplate,
                adapterDefaultPrefix: capabilities.mentionPrefix
            )
            let effectiveCapabilities = capabilities.withMentionFormatting(
                prefix: resolvedMentionFormatting.mentionPrefix,
                template: resolvedMentionFormatting.mentionTemplate
            )
            mentionFormattingCapabilities = effectiveCapabilities
            if !derivedWorkspaceRoots.isEmpty {
                let rewriteResult: MentionRewriteResult
                if shouldUsePlaceholderMentions {
                    rewriteResult = await mentionRewriteService.rewriteToCanonicalPlaceholders(
                        text: textAfterReplacements,
                        capabilities: effectiveCapabilities,
                        workspaceRoots: derivedWorkspaceRoots,
                        activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                    )
                } else {
                    rewriteResult = await mentionRewriteService.rewrite(
                        text: textAfterReplacements,
                        capabilities: effectiveCapabilities,
                        workspaceRoots: derivedWorkspaceRoots,
                        activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                    )
                }
                textAfterMentions = rewriteResult.text
                if rewriteResult.didRewrite {
                    Log.app.info("Mention rewrite: \(rewriteResult.rewrittenCount) mention(s) rewritten, \(rewriteResult.preservedCount) preserved")
                }
            } else {
                let adapterName = capturedAdapterCapabilities?.displayName ?? "unknown"
                let hasDocPath = capturedSnapshot?.appContext?.documentPath != nil
                let debugSummary = mentionRewriteWorkspaceDebugSummary(
                    adapterName: adapterName,
                    routingSignal: capturedRoutingSignal,
                    snapshot: capturedSnapshot,
                    derivedWorkspaceRoots: derivedWorkspaceRoots
                )
                Log.app.warning("Adapter '\(adapterName)' supports file mentions but no workspace roots derived (documentPath available: \(hasDocPath)); skipping mention rewrite. \(debugSummary)")
            }
        }
        
        pipelineMetrics.textProcessingSeconds = textProcessingStart.duration(to: pipelineClock.now).pipelineSeconds

        var finalText = normalizedTranscriptionText(textAfterMentions)
        var originalText: String? = nil
        var enhancedWithModel: String? = nil

        if LocalOnlySecurityPolicy.allowsExternalAI,
           let transcriptionAssignment = settingsStore.resolveAssignment(
            for: .transcriptionEnhancement)
        {
            let enhancementStart = pipelineClock.now
            do {
                originalText = textAfterMentions
                Log.app.info("AI enhancement enabled, saving original text before enhancement")

                var basePrompt = resolvedPrompt(
                    for: transcriptionAssignment,
                    fallback: SettingsStore.Defaults.aiEnhancementPrompt
                )

                let vocabularyWords = try dictionaryStore.fetchAllVocabularyWords().map(\.word)
                let replacementCorrections = lastAppliedReplacements.map {
                    AIEnhancementService.ContextMetadata.ReplacementCorrection(
                        original: $0.original,
                        replacement: $0.replacement
                    )
                }

                if mentionFormattingCapabilities?.supportsFileMentions == true {
                    basePrompt += "\n\nIf the input contains file placeholders formatted as [[:relative/path.ext:]], preserve each placeholder token exactly. Do not change brackets, colons, slashes, file names, or extensions inside those tokens."
                }
                
                var contextMetadata = AIEnhancementService.ContextMetadata.none
                var clipboardText: String? = nil

                var workspaceTreeSummary: String? = nil
                if !derivedWorkspaceRoots.isEmpty {
                    workspaceTreeSummary = await mentionRewriteService.generateWorkspaceTreeSummary(
                        workspaceRoots: derivedWorkspaceRoots,
                        activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                    )
                }

                let liveSessionContext = currentLiveSessionContext()
                
                if let context = capturedContext {
                    let hasClipboardText = context.clipboardText != nil && !context.clipboardText!.isEmpty
                    clipboardText = hasClipboardText ? context.clipboardText : nil
                    
                    contextMetadata = AIEnhancementService.ContextMetadata(
                        hasClipboardText: hasClipboardText,
                        clipboardText: clipboardText,
                        hasClipboardImage: false,
                        appContext: capturedSnapshot?.appContext,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: liveSessionContext,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                } else if let appContext = capturedSnapshot?.appContext {
                    contextMetadata = AIEnhancementService.ContextMetadata(
                        hasClipboardText: false,
                        clipboardText: nil,
                        hasClipboardImage: false,
                        appContext: appContext,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: liveSessionContext,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                } else if let liveSessionContext {
                    contextMetadata = AIEnhancementService.ContextMetadata(
                        hasClipboardText: false,
                        clipboardText: nil,
                        hasClipboardImage: false,
                        appContext: nil,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: liveSessionContext,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                } else if !vocabularyWords.isEmpty || !replacementCorrections.isEmpty {
                    contextMetadata = AIEnhancementService.ContextMetadata(
                        hasClipboardText: false,
                        clipboardText: nil,
                        hasClipboardImage: false,
                        appContext: nil,
                        adapterCapabilities: mentionFormattingCapabilities,
                        routingSignal: capturedRoutingSignal,
                        workspaceFileTree: workspaceTreeSummary,
                        liveSessionContext: nil,
                        vocabularyWords: vocabularyWords,
                        replacementCorrections: replacementCorrections
                    )
                }

                let enhancementResult = try await aiEnhancementService.enhanceWithMetrics(
                    text: textAfterMentions,
                    apiEndpoint: transcriptionAssignment.endpoint ?? "",
                    apiKey: transcriptionAssignment.apiKey,
                    model: transcriptionAssignment.modelID,
                    customPrompt: basePrompt,
                    imageBase64: nil,
                    context: contextMetadata,
                    provider: transcriptionAssignment.kind
                )
                finalText = enhancementResult.text
                pipelineMetrics.enhancementRequestSeconds = enhancementResult.requestSeconds
                pipelineMetrics.enhancementProvider = transcriptionAssignment.kind.rawValue
                pipelineMetrics.enhancementModel = transcriptionAssignment.modelID
                if let usage = enhancementResult.usage {
                    pipelineMetrics.enhancementPromptTokens = usage.promptTokens
                    pipelineMetrics.enhancementCompletionTokens = usage.completionTokens
                    pipelineMetrics.enhancementReasoningTokens = usage.reasoningTokens
                    pipelineMetrics.enhancementTotalTokens = usage.totalTokens
                }
                try ensureOperationCurrent(token)
                if let capabilities = mentionFormattingCapabilities,
                   capabilities.supportsFileMentions,
                   !derivedWorkspaceRoots.isEmpty {
                    let renderedPlaceholders = mentionRewriteService.renderCanonicalPlaceholders(
                        in: finalText,
                        capabilities: capabilities
                    )
                    finalText = renderedPlaceholders.text

                    if renderedPlaceholders.didRewrite {
                        Log.app.info("Post-enhancement placeholder render: \(renderedPlaceholders.rewrittenCount) placeholder(s) rendered, \(renderedPlaceholders.preservedCount) preserved")
                    } else {
                        let postEnhancementRewriteResult = await mentionRewriteService.rewrite(
                            text: finalText,
                            capabilities: capabilities,
                            workspaceRoots: derivedWorkspaceRoots,
                            activeDocumentPath: capturedSnapshot?.appContext?.documentPath
                        )
                        finalText = postEnhancementRewriteResult.text
                        if postEnhancementRewriteResult.didRewrite {
                            Log.app.info("Post-enhancement mention rewrite: \(postEnhancementRewriteResult.rewrittenCount) mention(s) rewritten, \(postEnhancementRewriteResult.preservedCount) preserved")
                        }
                    }
                }
                capturedContext = nil
                capturedSnapshot = nil
                capturedAdapterCapabilities = nil
                capturedRoutingSignal = nil
                stopLiveContextSession()
                enhancedWithModel = transcriptionAssignment.modelID
                pipelineMetrics.enhancementSeconds = enhancementStart.duration(to: pipelineClock.now).pipelineSeconds
                Log.app.info("AI enhancement completed, original: \(textAfterMentions.count) chars, enhanced: \(finalText.count) chars")
            } catch {
                // Cancelled/stale generation must not toast; abort the operation entirely.
                if Self.isTaskCancellation(error) || !operationController.isCurrent(token) {
                    throw CancellationError()
                }
                Log.app.error("AI enhancement failed: \(error)")
                telemetryService.send(
                    .enhancementFailed,
                    parameters: [
                        TelemetryParameter.providerKind: transcriptionAssignment.kind.rawValue,
                        TelemetryParameter.errorCase: TelemetryService.errorCaseName(error)
                    ]
                )
                toastService.show(
                    ToastPayload(
                        message: localized(
                            "AI enhancement failed. Transcription inserted without enhancement.",
                            locale: settingsStore.selectedAppLocale.locale
                        ),
                        style: .error
                    )
                )
                // Keep originalText so the unenhanced transcription is saved to history
            }
        } else {
            Log.app.debug("AI enhancement skipped: no transcriptionEnhancement assignment resolves")
        }
        finalText = ProgrammaticTranscriptFormatter.formatIfEnabled(
            finalText,
            enabled: settingsStore.programmaticFormattingEnabled
        )

        try ensureOperationCurrent(token)
        finalText = normalizedTranscriptionText(finalText)
        guard !isTranscriptionEffectivelyEmpty(finalText) else {
            handleNoSpeechDetected(context: "recording")
            return
        }

        let directInsertSnapshot = outputManager.outputMode == .directInsert
            && settingsStore.automaticDictionaryLearningEnabled
            ? contextEngineService.captureFocusedTextSnapshot()
            : nil
        var outputSucceeded = false
        var outputResult: OutputManager.OutputResult?
        do {
            if outputManager.outputMode == .directInsert {
                ensureAccessibilityPermissionForDirectInsert(trigger: "output", showFallbackAlert: true)
            }
            let outputText = settingsStore.addTrailingSpace ? finalText + " " : finalText
            let outputStart = pipelineClock.now
            outputResult = try await outputManager.output(outputText)
            pipelineMetrics.outputSeconds = outputStart.duration(to: pipelineClock.now).pipelineSeconds
            outputSucceeded = true
            if outputManager.outputMode == .directInsert,
               settingsStore.automaticDictionaryLearningEnabled {
                automaticDictionaryLearningService.beginObservation(
                    preInsertSnapshot: directInsertSnapshot,
                    insertedText: outputText
                )
            } else if outputManager.outputMode == .directInsert {
                Log.app.info("Automatic dictionary learning disabled in settings; skipping observation")
            }
        } catch {
            if Self.isTaskCancellation(error) { throw CancellationError() }
            Log.app.error("Output failed: \(error)")
        }

        pipelineMetrics.totalSeconds = pipelineStart.duration(to: pipelineClock.now).pipelineSeconds
        Log.app.info("Pipeline timing: \(pipelineMetrics.logSummary)")

        // Once the output landed in the target app the operation is committed: a
        // cancel arriving after that point must not drop the transcription from
        // history. Only the not-yet-output path may abort here.
        if !outputSucceeded {
            try ensureOperationCurrent(token)
        }
        guard Self.shouldPersistHistory(text: finalText) else { return }

        let speakerTrainingSegments = await speakerTrainingSegments(
            audioData: audioData,
            existingSegments: transcriptionOutput.diarizedSegments
        )
        do {
            let record = try historyStore.save(
                text: finalText,
                originalText: originalText,
                duration: duration,
                modelUsed: settingsStore.selectedModel,
                enhancedWith: enhancedWithModel,
                diarizationSegmentsJSON: diarizationSegmentsJSON,
                destinationAppName: outputResult?.destinationAppName,
                destinationAppBundleID: outputResult?.destinationAppBundleID,
                speakerTrainingSegments: speakerTrainingSegments,
                pipelineMetricsJSON: pipelineMetrics.hasAnyStage ? pipelineMetrics.jsonString() : nil
            )
            var successParameters: [String: String] = [
                TelemetryParameter.backend: settingsStore.resolvedTranscriptionBackend.rawValue,
                TelemetryParameter.model: settingsStore.selectedModel,
                TelemetryParameter.durationBucket: TelemetryService.durationBucket(duration),
                TelemetryParameter.wordCountBucket: TelemetryService.wordCountBucket(finalText.wordCount),
                TelemetryParameter.enhanced: String(enhancedWithModel != nil),
                TelemetryParameter.diarized: String(diarizationSegmentsJSON != nil)
            ]
            if let seconds = pipelineMetrics.transcriptionSeconds {
                successParameters[TelemetryParameter.transcribeLatencyBucket] = TelemetryService.latencyBucket(seconds)
            }
            if let seconds = pipelineMetrics.enhancementSeconds {
                successParameters[TelemetryParameter.enhanceLatencyBucket] = TelemetryService.latencyBucket(seconds)
            }
            if let seconds = pipelineMetrics.totalSeconds {
                successParameters[TelemetryParameter.totalLatencyBucket] = TelemetryService.latencyBucket(seconds)
            }
            telemetryService.send(
                .transcriptionSucceeded,
                parameters: successParameters,
                sampleRate: TelemetryService.successSampleRate
            )
            if let nativeAudio = audioRecorder.takeLastNativeAudio(),
               let nativePCMURL = nativeAudio.takeFileURL() {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatFileURL: nativePCMURL,
                    sampleRate: nativeAudio.sampleRate,
                    recordID: record.id
                )
            } else {
                dictationAudioRetentionService.schedulePersist(
                    pcmFloatData: audioData,
                    recordID: record.id
                )
            }
            updateRecentTranscriptsMenu()
            if let outputResult {
                showOutputResultToast(outputResult, wordCount: finalText.wordCount)
            }
        } catch {
            Log.app.error("Failed to save to history: \(error)")
            if let recoveryID = activeDictationRecoveryID {
                _ = try? dictationRecoveryStore.markFailed(id: recoveryID, message: error.localizedDescription)
            }
        }
    }

    /// Post-output feedback for the batch path. A landed paste gets the insertion
    /// toast; the intentional no-Accessibility copy fallback gets "Copied" with Undo
    /// (previously it was silent, making dictation look like a no-op); a real paste
    /// failure that fell back to the clipboard gets an error toast.
    private func showOutputResultToast(_ result: OutputManager.OutputResult, wordCount: Int) {
        let locale = settingsStore.selectedAppLocale.locale
        if result.didPaste {
            showInsertionSuccessToast(
                appName: result.destinationAppName,
                wordCount: wordCount
            )
            return
        }

        switch result.clipboardFallbackReason {
        case .copyOnlyMode, .accessibilityUnavailable:
            var actions: [ToastAction] = []
            if let snapshot = result.previousClipboardSnapshot {
                actions.append(
                    ToastAction(title: localized("Undo", locale: locale), role: .primary) { [weak self] in
                        let restored = self?.outputManager.restoreClipboardSnapshot(snapshot) ?? false
                        if restored {
                            Log.output.info("Restored clipboard after copy undo")
                        } else {
                            Log.output.error("Failed to restore clipboard after copy undo")
                        }
                    }
                )
            }
            toastService.show(
                ToastPayload(
                    message: localized("Copied to clipboard", locale: locale),
                    actions: actions,
                    variant: .copied
                )
            )
        case .pasteFailed, nil:
            toastService.show(
                ToastPayload(
                    message: localized("Paste failed. Transcript copied to clipboard.", locale: locale),
                    style: .error
                )
            )
        }
    }

    // MARK: - Escape Key Cancellation
    
    private func setupEscapeKeyMonitor() {
        if escapeEventTap != nil, escapeRunLoopSource != nil {
            installEscapeGlobalMonitorFallbackIfNeeded()
            return
        }

        if escapeEventTap != nil, escapeRunLoopSource == nil {
            Log.app.warning("Escape event tap missing run loop source; recreating monitor")
            teardownEscapeKeyMonitor()
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                
                let coordinator = Unmanaged<AppCoordinator>.fromOpaque(refcon).takeUnretainedValue()
                return coordinator.handleKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.app.error("Failed to create CGEventTap - Accessibility or Input Monitoring permission may be required")
            resetEventTapRecoveryState(for: .escape)
            installEscapeGlobalMonitorFallbackIfNeeded()
            return
        }

        installEscapeGlobalMonitorFallbackIfNeeded()
        
        escapeEventTap = eventTap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            Log.app.error("Failed to create run loop source for escape CGEventTap")
            escapeEventTap = nil
            resetEventTapRecoveryState(for: .escape)
            return
        }

        escapeRunLoopSource = source
        eventTapRunLoopThread.performAndWait { runLoop in
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        resetEventTapRecoveryState(for: .escape)
        Log.app.info("Escape key monitor installed")
    }

    private func setupModifierKeyMonitor() {
        if modifierEventTap != nil, modifierRunLoopSource != nil {
            removeModifierGlobalMonitorFallbackIfNeeded()
            return
        }

        if modifierEventTap != nil, modifierRunLoopSource == nil {
            Log.hotkey.warning("Modifier event tap missing run loop source; recreating monitor")
            teardownModifierKeyMonitor()
        }

        let eventMask = (1 << CGEventType.flagsChanged.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }

                let coordinator = Unmanaged<AppCoordinator>.fromOpaque(refcon).takeUnretainedValue()
                return coordinator.handleModifierKeyEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("Failed to create modifier CGEventTap - Accessibility or Input Monitoring permission may be required")
            resetEventTapRecoveryState(for: .modifier)
            installModifierGlobalMonitorFallbackIfNeeded()
            return
        }

        removeModifierGlobalMonitorFallbackIfNeeded()

        modifierEventTap = eventTap

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            Log.hotkey.error("Failed to create run loop source for modifier CGEventTap")
            modifierEventTap = nil
            resetEventTapRecoveryState(for: .modifier)
            return
        }

        modifierRunLoopSource = source
        eventTapRunLoopThread.performAndWait { runLoop in
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        resetEventTapRecoveryState(for: .modifier)
        Log.hotkey.info("Modifier key monitor installed")
    }

    private func teardownEscapeKeyMonitor() {
        escapeEventTapRecoveryTask?.cancel()
        escapeEventTapRecoveryTask = nil

        if let source = escapeRunLoopSource {
            let eventTap = escapeEventTap
            eventTapRunLoopThread.performAndWait { runLoop in
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        } else if let eventTap = escapeEventTap {
            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
        }

        escapeEventTap = nil
        escapeRunLoopSource = nil
        resetEventTapRecoveryState(for: .escape)
    }

    private func teardownModifierKeyMonitor() {
        modifierEventTapRecoveryTask?.cancel()
        modifierEventTapRecoveryTask = nil
        calendarRefreshTask?.cancel()
        calendarRefreshTask = nil
        if let calendarWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(calendarWakeObserver)
            self.calendarWakeObserver = nil
        }

        if let source = modifierRunLoopSource {
            let eventTap = modifierEventTap
            eventTapRunLoopThread.performAndWait { runLoop in
                if let eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: false)
                }
                CFRunLoopRemoveSource(runLoop, source, .commonModes)
            }
        } else if let eventTap = modifierEventTap {
            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: eventTap, enable: false)
            }
        }

        modifierEventTap = nil
        modifierRunLoopSource = nil
        resetEventTapRecoveryState(for: .modifier)
    }

    private func scheduleEventTapRecovery(for kind: EventTapKind, disabledType: CGEventType) {
        let now = Date()

        switch kind {
        case .escape:
            let decision = Self.determineEventTapRecovery(
                now: now,
                lastDisableAt: escapeEventTapDisableState.lastDisableAt,
                consecutiveDisableCount: escapeEventTapDisableState.consecutiveDisableCount,
                disableLoopWindow: eventTapDisableLoopWindow,
                maxReenableAttemptsBeforeRecreate: maxEventTapReenableAttemptsBeforeRecreate
            )
            escapeEventTapDisableState.lastDisableAt = now
            escapeEventTapDisableState.consecutiveDisableCount = decision.consecutiveDisableCount
            escapeEventTapDisableState.lastDisabledTypeRawValue = disabledType.rawValue

            guard escapeEventTapRecoveryTask == nil else { return }
            let recoveryDelay = eventTapRecoveryDelay
            escapeEventTapRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: recoveryDelay)
                guard let self, !Task.isCancelled else { return }
                self.escapeEventTapRecoveryTask = nil
                self.performEventTapRecovery(for: .escape)
            }
        case .modifier:
            let decision = Self.determineEventTapRecovery(
                now: now,
                lastDisableAt: modifierEventTapDisableState.lastDisableAt,
                consecutiveDisableCount: modifierEventTapDisableState.consecutiveDisableCount,
                disableLoopWindow: eventTapDisableLoopWindow,
                maxReenableAttemptsBeforeRecreate: maxEventTapReenableAttemptsBeforeRecreate
            )
            modifierEventTapDisableState.lastDisableAt = now
            modifierEventTapDisableState.consecutiveDisableCount = decision.consecutiveDisableCount
            modifierEventTapDisableState.lastDisabledTypeRawValue = disabledType.rawValue

            guard modifierEventTapRecoveryTask == nil else { return }
            let recoveryDelay = eventTapRecoveryDelay
            modifierEventTapRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: recoveryDelay)
                guard let self, !Task.isCancelled else { return }
                self.modifierEventTapRecoveryTask = nil
                self.performEventTapRecovery(for: .modifier)
            }
        }
    }

    private func performEventTapRecovery(for kind: EventTapKind) {
        switch kind {
        case .escape:
            let state = escapeEventTapDisableState
            resetEventTapRecoveryState(for: .escape)

            guard state.consecutiveDisableCount > 0 else { return }

            if state.consecutiveDisableCount >= maxEventTapReenableAttemptsBeforeRecreate {
                Log.app.error(
                    "Escape key monitor kept disabling (count=\(state.consecutiveDisableCount), lastType=\(state.lastDisabledTypeRawValue ?? 0)); recreating monitor"
                )
                teardownEscapeKeyMonitor()
                setupEscapeKeyMonitor()
                return
            }

            guard let tap = escapeEventTap else { return }

            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Log.app.warning("Escape key monitor was disabled (type=\(state.lastDisabledTypeRawValue ?? 0)); re-enabled after backoff")
        case .modifier:
            let state = modifierEventTapDisableState
            resetEventTapRecoveryState(for: .modifier)

            guard state.consecutiveDisableCount > 0 else { return }

            if state.consecutiveDisableCount >= maxEventTapReenableAttemptsBeforeRecreate {
                Log.hotkey.error(
                    "Modifier key monitor kept disabling (count=\(state.consecutiveDisableCount), lastType=\(state.lastDisabledTypeRawValue ?? 0)); recreating monitor"
                )
                teardownModifierKeyMonitor()
                setupModifierKeyMonitor()
                return
            }

            guard let tap = modifierEventTap else { return }

            eventTapRunLoopThread.performAndWait { _ in
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            Log.hotkey.warning("Modifier key monitor was disabled (type=\(state.lastDisabledTypeRawValue ?? 0)); re-enabled after backoff")
        }
    }

    private func resetEventTapRecoveryState(for kind: EventTapKind) {
        switch kind {
        case .escape:
            escapeEventTapDisableState = EventTapDisableState()
        case .modifier:
            modifierEventTapDisableState = EventTapDisableState()
        }
    }

    private func installEscapeGlobalMonitorFallbackIfNeeded() {
        guard escapeGlobalMonitor == nil else { return }

        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.handleEscapeSignal(source: "nsevent-global")
            }
        }

        if escapeGlobalMonitor != nil {
            Log.app.warning("Using NSEvent global monitor fallback for escape key (observation only; suppression unavailable)")
        }
    }

    private func removeEscapeGlobalMonitorFallbackIfNeeded() {
        guard let monitor = escapeGlobalMonitor else { return }
        NSEvent.removeMonitor(monitor)
        escapeGlobalMonitor = nil
        Log.app.debug("Removed NSEvent global monitor fallback for escape key")
    }

    private func installModifierGlobalMonitorFallbackIfNeeded() {
        guard modifierGlobalMonitor == nil else { return }

        modifierGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let cgEvent = event.cgEvent else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.hotkeyManager.handleModifierFlagsChanged(event: cgEvent)
            }
        }

        if modifierGlobalMonitor != nil {
            Log.hotkey.warning("Using NSEvent global monitor fallback for modifier changes")
        }
    }

    private func removeModifierGlobalMonitorFallbackIfNeeded() {
        guard let monitor = modifierGlobalMonitor else { return }
        NSEvent.removeMonitor(monitor)
        modifierGlobalMonitor = nil
        Log.hotkey.debug("Removed NSEvent global monitor fallback for modifier changes")
    }
    
    static func shouldSuppressEscapeEvent(
        isRecording: Bool,
        isProcessing: Bool,
        isMediaTranscriptionOnly: Bool = false
    ) -> Bool {
        (isRecording || isProcessing) && !isMediaTranscriptionOnly
    }

    /// Single Escape cancels while a recording/processing session is active.
    /// Same predicate as suppression so the key is only swallowed when we act on it.
    /// Media-only work is excluded from both: cancel intentionally ignores queued
    /// media jobs, so Escape must not be stolen from the focused app while they run.
    static func shouldCancelOperationOnEscape(
        isRecording: Bool,
        isProcessing: Bool,
        isMediaTranscriptionOnly: Bool = false
    ) -> Bool {
        shouldSuppressEscapeEvent(
            isRecording: isRecording,
            isProcessing: isProcessing,
            isMediaTranscriptionOnly: isMediaTranscriptionOnly
        )
    }

    static func isTaskCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func ensureOperationCurrent(_ token: DictationOperationToken) throws {
        try Task.checkCancellation()
        guard operationController.isCurrent(token) else {
            throw CancellationError()
        }
    }

    /// Deferred stop/transcribe cleanup must only run for the still-current operation.
    /// After cancel frees admission and a new recording starts, a stale cancelled task
    /// must not wipe the new session's processing/recording state.
    static func shouldResetProcessingStateOnExit(
        didResetProcessingState: Bool,
        isOperationCurrent: Bool
    ) -> Bool {
        !didResetProcessingState && isOperationCurrent
    }

    /// Whether a stop-path catch may toast or mutate shared UI/RecordingState.
    /// Stale generations (cancelled then superseded) and cooperative cancellation
    /// must produce no user-visible side effects.
    static func shouldEmitOperationFailureSideEffects(
        isOperationCurrent: Bool,
        error: Error
    ) -> Bool {
        isOperationCurrent && !isTaskCancellation(error)
    }

    private func resetProcessingStateIfCurrent(_ token: DictationOperationToken) {
        guard Self.shouldResetProcessingStateOnExit(
            didResetProcessingState: false,
            isOperationCurrent: operationController.isCurrent(token)
        ) else {
            return
        }
        resetProcessingState()
    }

    private nonisolated func handleKeyEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.scheduleEventTapRecovery(for: .escape, disabledType: type)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == 53 else {
            guard liveContextKeyRefreshGate.claim(
                now: ProcessInfo.processInfo.systemUptime,
                minimumInterval: 0.75
            ) else {
                return Unmanaged.passUnretained(event)
            }
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.scheduleFocusOrWindowContextRefreshIfNeeded()
            }
            return Unmanaged.passUnretained(event)
        }
        
        let shouldSuppress = escapeEventState.currentShouldSuppress()
        guard shouldSuppress else {
            return Unmanaged.passUnretained(event)
        }

        Task { @MainActor [weak self] in
            guard let self, !self.isShutdown else { return }
            self.handleEscapeSignal(source: "cg-event-tap")
            Log.app.info("Escape intercepted+suppressing (recordingOrProcessing=true)")
        }
        return nil
    }

    private func handleEscapeSignal(source: String) {
        let now = Date()
        if let lastSignal = lastEscapeSignalTime,
           now.timeIntervalSince(lastSignal) <= duplicateEscapeSignalThreshold {
            Log.app.debug("Ignoring duplicate escape signal from \(source)")
            return
        }

        lastEscapeSignalTime = now
        Log.app.info("Escape signal received (source=\(source))")
        handleEscapeKeyPress()
    }

    private nonisolated func handleModifierKeyEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Task { @MainActor [weak self] in
                guard let self, !self.isShutdown else { return }
                self.scheduleEventTapRecovery(for: .modifier, disabledType: type)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else { return Unmanaged.passUnretained(event) }

        Task { @MainActor [weak self] in
            guard let self, !self.isShutdown else { return }
            self.hotkeyManager.handleModifierFlagsChanged(event: event)
        }
        return Unmanaged.passUnretained(event)
    }
    
    private func handleEscapeKeyPress() {
        // Escape cancels while Pindrop owns an active recording/processing session.
        // Idle Escape is intentionally a no-op so other apps keep the key, and
        // media-only work is skipped so an Escape that cannot cancel anything
        // neither arms the double-press sequence nor pretends to act.
        guard isRecording || isProcessing || activeOperationTask != nil else { return }
        guard !isMediaTranscriptionOnlyWork else { return }

        let now = Date()
        if Self.escapeShouldCancel(
            requiresDoublePress: settingsStore.cancelRequiresDoubleEscape,
            armedAt: escapeCancelArmedAt,
            now: now,
            window: Self.doubleEscapeCancelWindow
        ) {
            escapeCancelArmedAt = nil
            requestCancelCurrentOperation(source: "escape")
        } else {
            escapeCancelArmedAt = now
            Log.app.info("Escape armed for cancel — press again within \(Self.doubleEscapeCancelWindow)s")
        }
    }

    /// Whether an Escape press should cancel the active session, or merely arm the
    /// double-press sequence. Single-press mode always cancels; double-press mode
    /// cancels only when a prior press armed the sequence within `window`.
    static func escapeShouldCancel(
        requiresDoublePress: Bool,
        armedAt: Date?,
        now: Date,
        window: TimeInterval
    ) -> Bool {
        guard requiresDoublePress else { return true }
        guard let armedAt else { return false }
        return now.timeIntervalSince(armedAt) <= window
    }

    private func requestCancelCurrentOperation(source: String) {
        guard isRecording || isProcessing || activeOperationTask != nil else { return }
        guard !isMediaTranscriptionOnlyWork else { return }

        let wasRecording = isRecording
        guard AlertManager.shared.confirmCancelOperation(isRecording: wasRecording) else {
            Log.app.info("Cancel declined via \(source); operation will continue")
            return
        }
        cancelCurrentOperation(source: source)
    }

    private func cancelCurrentOperation(source: String = "cancel") {
        guard isRecording || isProcessing || activeOperationTask != nil else {
            Log.app.debug("Cancel requested (\(source)) but no operation in progress")
            return
        }

        // Background media transcription jobs are long-running and were explicitly
        // queued by the user — don't cancel them via keyboard shortcut. Only bail
        // when the media job is the sole active work: a concurrent dictation
        // session must stay cancellable.
        guard !isMediaTranscriptionOnlyWork else {
            Log.app.debug("Cancel requested (\(source)) during background media transcription — ignoring")
            return
        }

        Log.app.info("Cancelling current operation via explicit confirmation (source=\(source))")

        let recoveryID = activeDictationRecoveryID
        if let recoveryID {
            _ = try? dictationRecoveryStore.markCanceled(id: recoveryID)
            activeDictationRecoveryID = nil
        }

        escapeCancelArmedAt = nil
        // Invalidate any in-flight stop/transcribe/enhance pipeline first so post-await
        // stages discard results even if cooperative cancellation is delayed.
        operationController.cancel()
        activeOperationTask?.cancel()
        activeOperationTask = nil
        // Free stop admission immediately so a new recording can stop even while the
        // cancelled finalize task is still unwinding its defer.
        recordingStopAdmission.invalidateCurrentClaim()

        streamingSession.cancelDetached()
        recordingState.endRecording(message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale))
        recordingState.clearCurrentJob()

        audioRecorder.resetAudioEngine()
        markActiveMeetingFailed(
            "Meeting capture was canceled. Recoverable audio remains available for retry."
        )
        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        isQuickCaptureMode = false
        clearNoteAppendMode()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()
        error = nil

        statusBarController.setIdleState()
        statusBarController.updateMenuState()

        finishIndicatorSession()

        if let recoveryID, dictationRecoveryStore.hasAudio(id: recoveryID) {
            showRecoverableRecordingToast(id: recoveryID, wasExplicitlyCanceled: true)
        }
    }

    private func markActiveMeetingFailed(_ message: String) {
        guard let occurrenceID = activeMeetingOccurrenceID else { return }
        try? meetingStore.markFailedPreservingWorkspace(id: occurrenceID, message: message)
        activeMeetingOccurrenceID = nil
    }

    private func handleAudioCaptureFailure(_ failure: Error) {
        if case .recordingLimitReached = failure as? AudioRecorderError {
            handleRecordingLimitReached(failure)
            return
        }
        error = failure
        Log.app.error("Audio capture failed: \(failure.localizedDescription)")

        let recoveryID = activeDictationRecoveryID
        if let recoveryID {
            _ = try? dictationRecoveryStore.markFailed(id: recoveryID, message: failure.localizedDescription)
            activeDictationRecoveryID = nil
        }

        let hadStreamingSession = streamingSession.isSessionActive
        streamingSession.cancelDetached()
        let captureFailureLocale = settingsStore.selectedAppLocale.locale
        let captureFailureMessage = String(
            format: localized("Recording stopped: %@", locale: captureFailureLocale),
            locale: captureFailureLocale,
            failure.localizedDescription
        )
        recordingState.endRecording(message: captureFailureMessage)
        recordingState.clearCurrentJob()
        if hadStreamingSession {
            Log.transcription.info("Cancelled streaming transcription after audio capture failure")
        }

        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        isQuickCaptureMode = false
        clearNoteAppendMode()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()

        statusBarController.setIdleState()
        statusBarController.updateMenuState()
        finishIndicatorSession()

        markActiveMeetingFailed(captureFailureMessage)

        toastService.show(
            ToastPayload(message: captureFailureMessage, style: .error)
        )
        if let recoveryID, dictationRecoveryStore.hasAudio(id: recoveryID) {
            showRecoverableRecordingToast(id: recoveryID, wasExplicitlyCanceled: false)
        }
    }

    /// The recorder has stopped accepting new PCM, but its valid spool remains
    /// intact. Route this through the normal stop path so captured speech is
    /// transcribed instead of treating the limit as a cancellation.
    private func handleRecordingLimitReached(_ signal: Error) {
        guard isRecording, recordingStartTime != nil else { return }
        Log.app.info("Recording duration limit reached; finalizing captured audio")
        toastService.show(
            ToastPayload(message: signal.localizedDescription, style: .standard)
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.dispatchRecordingStop()
            } catch {
                self.handleAudioCaptureFailure(error)
            }
        }
    }

    private func resetProcessingState() {
        mediaPauseService.endRecordingSession()
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        // Note-append mode is cleared by the stop path after processing; only clear if not mid-append.
        if !isNoteAppendMode {
            NoteAppendListeningCoordinator.shared.state.finishSession()
        }
        recordingState.endRecording()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()
        statusBarController.setIdleState()
        statusBarController.updateMenuState()

        finishIndicatorSession()
    }

    private func resumeInterruptedDictationsIfNeeded() {
        let interrupted = dictationRecoveryStore.recoverableSessions(includeCanceled: false)
        let canceled = dictationRecoveryStore.recoverableSessions(includeCanceled: true)
            .filter { $0.state == .canceled }

        if let canceledSession = canceled.last {
            showRecoverableRecordingToast(id: canceledSession.id, wasExplicitlyCanceled: true)
        }
        guard !interrupted.isEmpty else { return }

        Log.audio.warning("Found \(interrupted.count) interrupted recording(s); resuming transcription")
        Task { @MainActor [weak self] in
            guard let self else { return }
            for session in interrupted {
                guard !self.isRecording, !self.isProcessing else { return }
                await self.processRecoverableRecording(id: session.id, automatic: true)
            }
        }
    }

    private func showRecoverableRecordingToast(id: UUID, wasExplicitlyCanceled: Bool) {
        let locale = settingsStore.selectedAppLocale.locale
        let message = wasExplicitlyCanceled
            ? localized("Recording canceled. The audio is safe and can be transcribed later.", locale: locale)
            : localized("An interrupted recording is safe and ready to resume.", locale: locale)
        toastService.show(
            ToastPayload(
                message: message,
                actions: [
                    ToastAction(
                        title: localized("Retry Transcription", locale: locale),
                        role: .primary
                    ) { [weak self] in
                        Task { @MainActor [weak self] in
                            await self?.processRecoverableRecording(id: id, automatic: false)
                        }
                    }
                ],
                duration: nil
            )
        )
    }

    private func processRecoverableRecording(id: UUID, automatic: Bool) async {
        guard !isRecording, !isProcessing, activeOperationTask == nil else {
            if !automatic {
                toastService.show(
                    ToastPayload(
                        message: localized(
                            "Finish the active recording or transcription before retrying.",
                            locale: settingsStore.selectedAppLocale.locale
                        ),
                        style: .error
                    )
                )
            }
            return
        }
        guard activeModelName != nil else {
            showRecoverableRecordingToast(id: id, wasExplicitlyCanceled: false)
            return
        }

        let token = operationController.begin()
        activeDictationRecoveryID = id
        let operationTask = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performRecoverableRecordingProcessing(id: id, token: token)
        }
        activeOperationTask = operationTask

        defer {
            if activeOperationTask == operationTask {
                activeOperationTask = nil
            }
        }

        do {
            try await operationTask.value
        } catch {
            if Self.isTaskCancellation(error) {
                Log.audio.info("Recovered transcription canceled; audio remains safe")
                return
            }
            _ = try? dictationRecoveryStore.markFailed(id: id, message: error.localizedDescription)
            if activeDictationRecoveryID == id { activeDictationRecoveryID = nil }
            resetProcessingState()
            toastService.show(ToastPayload(message: error.localizedDescription, style: .error))
        }
    }

    private func performRecoverableRecordingProcessing(
        id: UUID,
        token: DictationOperationToken
    ) async throws {
        try dictationRecoveryStore.markProcessing(id: id)
        let session = try dictationRecoveryStore.session(id: id)
        let pcmURL = dictationRecoveryStore.audioURL(for: id)
        let audioData = try dictationRecoveryStore.audioData(id: id)
        let duration = Double(audioData.count) / Double(16_000 * MemoryLayout<Float>.size)

        isProcessing = true
        statusBarController.setProcessingState()
        startProcessingIndicatorSession()
        defer {
            if operationController.isCurrent(token) {
                resetProcessingState()
            }
        }

        let output = try await transcriptionService.transcribe(
            audioData: audioData,
            diarizationEnabled: false,
            options: makeTranscriptionOptions(),
            diarizationOptions: .init(),
            diarizationFailurePolicy: .bestEffort,
            progressHandler: makeTranscriptionProgressHandler()
        )
        try ensureOperationCurrent(token)

        var (text, replacements) = try dictionaryStore.applyReplacements(to: output.text)
        text = normalizedTranscriptionText(text)
        guard !isTranscriptionEffectivelyEmpty(text) else {
            throw TranscriptionService.TranscriptionError.transcriptionFailed("No speech was detected in the recovered audio.")
        }
        lastAppliedReplacements = replacements

        let recoveryMediaDirectory = ManagedMediaLibrary.dictationAudioDirectoryURL
        let encodeTask = Task.detached(priority: .utility) {
            try DictationAudioRetentionService.encodeFileAndWritePeaks(
                pcmFloatFileURL: pcmURL,
                sampleRate: 16_000,
                recordID: id,
                directoryURL: recoveryMediaDirectory
            )
        }
        let audioURL = try await withTaskCancellationHandler {
            try await encodeTask.value
        } onCancel: {
            encodeTask.cancel()
        }
        do {
            try ensureOperationCurrent(token)
        } catch {
            DictationAudioRetentionService.removeUnlinkedMedia(at: audioURL)
            throw error
        }

        do {
            _ = try historyStore.save(
                text: text,
                duration: duration,
                modelUsed: settingsStore.selectedModel,
                sourceKind: .voiceRecording,
                sourceDisplayName: localized("Recovered recording", locale: settingsStore.selectedAppLocale.locale),
                managedMediaPath: audioURL.path
            )
        } catch {
            DictationAudioRetentionService.removeUnlinkedMedia(at: audioURL)
            throw error
        }
        try dictationRecoveryStore.complete(id: session.id)
        if activeDictationRecoveryID == id { activeDictationRecoveryID = nil }
        updateRecentTranscriptsMenu()
        toastService.show(
            ToastPayload(
                message: localized(
                    "Recovered recording transcribed and saved to History.",
                    locale: settingsStore.selectedAppLocale.locale
                )
            )
        )
    }

    // MARK: - Floating Indicator Actions

    private func handleHideFloatingIndicatorForOneHour() {
        let hideDuration: TimeInterval = 60 * 60
        floatingIndicatorHiddenUntil = Date().addingTimeInterval(hideDuration)

        hideAllFloatingIndicators()
        syncFloatingIndicatorFocusTracking()

        floatingIndicatorHiddenTask?.cancel()
        floatingIndicatorHiddenTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(hideDuration * 1_000_000_000))
            } catch {
                return
            }

            await MainActor.run {
                guard let self = self else { return }
                self.floatingIndicatorHiddenUntil = nil
                self.updateFloatingIndicatorVisibility()
            }
        }

        Log.ui.info("Floating indicator hidden for one hour")
    }

    @discardableResult
    private func applyPreferredInputDeviceUID(_ uid: String) -> Bool {
        do {
            try audioRecorder.setPreferredInputDeviceUID(uid)
            return true
        } catch {
            self.error = error
            Log.audio.error("Failed to switch input device: \(error.localizedDescription)")
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Could not switch microphone: %@", locale: locale), locale: locale, error.localizedDescription),
                    style: .error
                )
            )
            // The recorder reverted to the device actually capturing; snap the
            // stored selection back so Settings doesn't show a mic that isn't
            // recording (silent wrong-device recordings otherwise).
            let actualUID = audioRecorder.currentPreferredInputDeviceUID ?? ""
            if settingsStore.selectedInputDeviceUID != actualUID {
                settingsStore.selectedInputDeviceUID = actualUID
                inputMuteMonitor?.setPreferredDeviceUID(actualUID)
            }
            return false
        }
    }

    private func handleSelectInputDeviceUID(_ uid: String) {
        settingsStore.selectedInputDeviceUID = uid
        guard applyPreferredInputDeviceUID(uid) else { return }
        inputMuteMonitor?.setPreferredDeviceUID(uid)

        if uid.isEmpty {
            Log.audio.info("Selected input device: system default")
        } else {
            Log.audio.info("Selected input device UID: \(uid)")
        }
    }

    private func setupInputDeviceMonitoring() {
        let monitor = AudioDeviceListMonitor()
        monitor.onChange = { [weak self] in
            self?.validateSelectedInputDeviceAvailability()
        }
        monitor.start()
        inputDeviceListMonitor = monitor
        validateSelectedInputDeviceAvailability()
        setupInputMuteMonitoring()
    }

    private func setupInputMuteMonitoring() {
        let muteMonitor = InputMuteMonitor(
            preferredDeviceUID: settingsStore.selectedInputDeviceUID
        )
        muteMonitor.onMuteStateChange = { [weak self] muted in
            self?.floatingIndicatorState.isInputMuted = muted
        }
        muteMonitor.start()
        floatingIndicatorState.isInputMuted = muteMonitor.isMuted
        inputMuteMonitor = muteMonitor
    }

    /// If the explicitly selected input device is no longer attached, fall back to the
    /// system default so capture and the device pickers don't stay pinned to a device
    /// that isn't there anymore.
    private func validateSelectedInputDeviceAvailability() {
        let uid = settingsStore.selectedInputDeviceUID
        guard !uid.isEmpty else { return }
        guard !AudioDeviceManager.inputDevices().contains(where: { $0.uid == uid }) else { return }

        Log.audio.info(
            "Selected input device is no longer available (uid=\(uid)); falling back to system default"
        )
        handleSelectInputDeviceUID("")
    }

    private func handleSelectLanguage(_ language: AppLanguage) {
        settingsStore.selectedAppLanguage = language
        Log.ui.info("Selected app language: \(language.rawValue)")
    }

    // MARK: - Copy Last Transcript

    private func handleCopyLastTranscript() async {
        do {
            let records = try historyStore.fetch(limit: 1)
            guard let lastRecord = records.first else {
                Log.app.warning("No transcripts to copy")
                return
            }

            copyTextWithUndo(lastRecord.text)
            Log.app.info("Copied last transcript to clipboard")
        } catch {
            Log.app.error("Failed to copy last transcript: \(error)")
        }
    }

    /// Snapshots the pasteboard, writes text, and shows a "Copied — Undo" toast.
    func copyTextWithUndo(_ text: String) {
        guard !text.isEmpty else { return }
        do {
            let snapshot = try outputManager.copyReplacingClipboard(text)
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: localized("Copied to clipboard", locale: locale),
                    actions: [
                        ToastAction(title: localized("Undo", locale: locale), role: .primary) { [weak self] in
                            let restored = self?.outputManager.restoreClipboardSnapshot(snapshot) ?? false
                            if restored {
                                Log.output.info("Restored clipboard after copy undo")
                            } else {
                                Log.output.error("Failed to restore clipboard after copy undo")
                            }
                        }
                    ],
                    variant: .copied
                )
            )
        } catch {
            Log.output.error("Failed to copy text with undo: \(error)")
        }
    }

    @objc private func handleCopyTextWithUndoNotification(_ notification: Notification) {
        guard let text = notification.userInfo?["text"] as? String else { return }
        copyTextWithUndo(text)
    }

    private func handlePasteLastTranscript() async {
        do {
            let records = try historyStore.fetch(limit: 1)
            guard let lastRecord = records.first else {
                Log.app.warning("No transcripts to paste")
                return
            }

            if permissionManager.checkAccessibilityPermission() {
                do {
                    try await outputManager.pasteText(lastRecord.text)
                    Log.output.info("Pasted last transcript into active app")
                    return
                } catch {
                    Log.output.error("Failed to paste last transcript directly: \(error)")
                }
            }

            try outputManager.copyToClipboard(lastRecord.text)
            Log.output.info("Copied last transcript to clipboard (paste fallback)")
        } catch {
            Log.output.error("Failed to prepare last transcript for paste: \(error)")
        }
    }

    // MARK: - Export Last Transcript

    private func handleExportLastTranscript() async {
        do {
            let records = try historyStore.fetch(limit: 1)
            guard let lastRecord = records.first else {
                Log.app.warning("No transcripts to export")
                return
            }

            await MainActor.run {
                let savePanel = NSSavePanel()
                savePanel.allowedContentTypes = [.plainText]
                savePanel.nameFieldStringValue = "transcript.txt"
                savePanel.title = "Export Transcript"

                guard savePanel.runModal() == .OK, let url = savePanel.url else { return }

                do {
                    try lastRecord.text.write(to: url, atomically: true, encoding: .utf8)
                    Log.app.info("Exported transcript to \(url.lastPathComponent)")
                } catch {
                    Log.app.error("Failed to export transcript: \(error)")
                }
            }
        } catch {
            Log.app.error("Failed to fetch transcript for export: \(error)")
        }
    }

    // MARK: - Media Transcription
    static func mediaTranscriptionProvider(
        named modelName: String,
        availableModels: [ModelManager.WhisperModel]
    ) -> ModelManager.ModelProvider {
        availableModels.first(where: { $0.name == modelName })?.provider ?? .whisperKit
    }

    private func handleImportMediaFiles(_ urls: [URL], options: TranscriptionJobOptions) {
        for url in urls {
            let job = MediaTranscriptionJobState(request: .file(url), options: options)
            enqueueOrStart(job)
        }
    }

    private func handleSubmitMediaLink(_ link: String, options: TranscriptionJobOptions) {
        let job = MediaTranscriptionJobState(request: .link(link), options: options)
        enqueueOrStart(job)
    }

    private func enqueueOrStart(_ job: MediaTranscriptionJobState) {
        if mediaTranscriptionTask == nil {
            startMediaTranscriptionTask(for: job)
        } else {
            mediaTranscriptionState.enqueue(job)
        }
    }

    private func clearTranscriptionQueue() {
        mediaTranscriptionGeneration &+= 1
        mediaQueueRestoreRequested =
            mediaQueueRestoreRequested || queueOriginalModelName != nil
        mediaQueueNeedsProcessingReset = mediaQueueNeedsProcessingReset || isProcessing
        mediaQueueDeferredUntilIdle = false
        mediaTranscriptionTask?.cancel()
        mediaTranscriptionState.clearAllJobs()
        if mediaTranscriptionTask == nil {
            startMediaQueueContinuationIfNeeded()
        }
    }

    private func handleDownloadDiarizationModel() {
        guard !mediaTranscriptionState.isDiarizationModelDownloading,
              !recordingState.isDiarizationModelDownloading else {
            return
        }

        mediaTranscriptionState.isDiarizationModelDownloading = true
        mediaTranscriptionState.diarizationModelDownloadProgress = 0.0
        recordingState.isDiarizationModelDownloading = true
        recordingState.diarizationModelDownloadProgress = 0.0

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.mediaTranscriptionState.isDiarizationModelDownloading = false
                self.recordingState.isDiarizationModelDownloading = false
            }

            do {
                let readiness = self.modelManager.offlineDiarizationReadiness(
                    at: self.modelManager.fluidAudioModelsRootURL
                )
                let progressHandler: (Double) -> Void = { [weak self] progress in
                    guard let self else { return }
                    self.mediaTranscriptionState.diarizationModelDownloadProgress = progress
                    self.recordingState.diarizationModelDownloadProgress = progress
                }
                if readiness.requiresRepair {
                    try await self.modelManager.repairOfflineDiarizationModel(onProgress: progressHandler)
                } else {
                    try await self.modelManager.downloadFeatureModel(.diarization, onProgress: progressHandler)
                }
                await self.modelManager.refreshDownloadedFeatureModels()
                self.settingsStore.diarizationFeatureEnabled = true
                self.mediaTranscriptionState.setupIssue = nil
                self.mediaTranscriptionState.diarizationIssueNeedsRepair = false
                self.toastService.show(ToastPayload(message: localized("Speaker diarization is ready.", locale: self.settingsStore.selectedAppLocale.locale)))
                self.recordingState.setupIssue = nil
                self.recordingState.diarizationIssueNeedsRepair = false
                self.recordingState.message = localized("Speaker diarization is ready.", locale: self.settingsStore.selectedAppLocale.locale)
            } catch {
                self.mediaTranscriptionState.diarizationModelDownloadProgress = 0.0
                self.recordingState.diarizationModelDownloadProgress = 0.0
                self.mediaTranscriptionState.setSetupIssue(error.localizedDescription)
                self.recordingState.setSetupIssue(error.localizedDescription)
            }
        }
    }

    private func handleStartMeetingCapture(expectedSpeakerCount: Int?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.startManualTranscriptionRecording(
                    mode: .microphoneAndSystemAudio,
                    expectedSpeakerCount: expectedSpeakerCount
                )
            } catch {
                self.error = error
                self.audioRecorder.resetAudioEngine()
                self.isRecordingFeatureCaptureActive = false
                self.recordingState.endRecording(message: error.localizedDescription)
                Log.app.error("Failed to start meeting capture: \(error)")
            }
        }
    }

    /// One-gesture meeting control used by the dedicated global shortcut.
    /// It only stops a meeting it owns; it never turns an unrelated dictation
    /// into a meeting or interrupts another processing job.
    private func handleMeetingCaptureToggle() async {
        if isRecording {
            guard isRecordingFeatureCaptureActive else {
                recordingState.message = localized(
                    "Finish the active transcription before starting another one.",
                    locale: settingsStore.selectedAppLocale.locale
                )
                return
            }

            do {
                try await dispatchRecordingStop()
            } catch {
                self.error = error
                audioRecorder.resetAudioEngine()
                Log.app.error("Failed to stop meeting capture: \(error)")
            }
            return
        }

        guard !isProcessing else {
            recordingState.message = localized(
                "Finish the active transcription before starting another one.",
                locale: settingsStore.selectedAppLocale.locale
            )
            return
        }

        do {
            try await startManualTranscriptionRecording(
                mode: .microphoneAndSystemAudio,
                expectedSpeakerCount: nil
            )
        } catch {
            self.error = error
            audioRecorder.resetAudioEngine()
            isRecordingFeatureCaptureActive = false
            recordingState.endRecording(message: error.localizedDescription)
            Log.app.error("Failed to start meeting capture: \(error)")
        }
    }

    private func startManualTranscriptionRecording(
        mode: AudioRecordingMode,
        expectedSpeakerCount: Int? = nil,
        existingOccurrenceID: UUID? = nil
    ) async throws {
        guard !isRecording && !isProcessing else {
            recordingState.message = "Finish the active transcription before starting another one."
            return
        }

        let preflight = MeetingPreflightService(
            permissionProvider: permissionManager,
            modelManager: modelManager,
            diarizationLoader: {
                let diarizer = FluidSpeakerDiarizer()
                try await diarizer.loadModels()
                await diarizer.unloadModels()
            }
        )
        let report = await preflight.run(selectedTranscriptionModel: settingsStore.selectedModel)
        guard report.isReady else {
            if let issue = report.primaryIssue {
                recordingState.setSetupIssue(
                    issue.localizedMessage(locale: settingsStore.selectedAppLocale.locale),
                    requiresRepair: issue.requiresDiarizationRepair
                )
            }
            return
        }

        let occurrence: MeetingOccurrence
        if let existingOccurrenceID,
           let existing = try meetingStore.occurrence(id: existingOccurrenceID) {
            occurrence = existing
            try meetingStore.transition(id: existing.id, to: .preparing)
        } else {
            occurrence = try meetingStore.createManualOccurrence(
                expectedSpeakerCount: expectedSpeakerCount
            )
        }
        activeMeetingOccurrenceID = occurrence.id
        audioRecorder.persistentSpoolDirectoryURL = occurrence.workspaceURL

        let didStartRecording: Bool
        do {
            didStartRecording = try await audioRecorder.startRecording(
                configuration: AudioRecordingConfiguration(mode: mode)
            )
        } catch {
            try? meetingStore.markFailedPreservingWorkspace(
                id: occurrence.id,
                message: error.localizedDescription
            )
            activeMeetingOccurrenceID = nil
            throw error
        }
        guard didStartRecording else {
            try meetingStore.markFailedPreservingWorkspace(
                id: occurrence.id,
                message: "Meeting capture did not start."
            )
            activeMeetingOccurrenceID = nil
            return
        }
        try meetingStore.transition(id: occurrence.id, to: .recording)
        manualExpectedSpeakerCount = expectedSpeakerCount

        isRecording = true
        isRecordingFeatureCaptureActive = true
        recordingStartTime = Date()
        recordingState.beginRecording(mode: mode, startedAt: recordingStartTime ?? Date())
        statusBarController.setRecordingState(isMeetingCapture: true)
        statusBarController.updateMenuState()
        startRecordingIndicatorSession()
    }


    private func stopManualTranscriptionRecording(token: DictationOperationToken) async throws {
        guard isRecordingFeatureCaptureActive else {
            throw AudioRecorderError.notRecording
        }

        let mode = recordingState.selectedCaptureMode
        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        let occurrenceID = activeMeetingOccurrenceID
        let adoptedRecoveryID = activeDictationRecoveryID
        let audioData: Data
        do {
            audioData = try await audioRecorder.stopRecording()
        } catch {
            if let occurrenceID {
                try? meetingStore.markFailedPreservingWorkspace(
                    id: occurrenceID,
                    message: error.localizedDescription
                )
            }
            activeMeetingOccurrenceID = nil
            throw error
        }
        // Ownership check immediately after the first await — before any global
        // mutation/store that would clobber a newer session started after cancel.
        try ensureOperationCurrent(token)

        isRecording = false
        isRecordingFeatureCaptureActive = false
        recordingState.endRecording()
        statusBarController.setProcessingState()
        statusBarController.updateMenuState()
        transitionRecordingIndicatorToProcessing()
        isProcessing = true
        let expectedSpeakerCount = manualExpectedSpeakerCount
        manualExpectedSpeakerCount = nil
        if let occurrenceID {
            try meetingStore.transition(id: occurrenceID, to: .processing)
        }

        let job = MediaTranscriptionJobState(
            request: .manualCapture(mode),
            options: TranscriptionJobOptions(
                modelName: settingsStore.selectedModel,
                language: settingsStore.selectedAppLanguage,
                outputFormat: .plainText,
                diarizationEnabled: true,
                expectedSpeakerCount: expectedSpeakerCount
            ),
            destinationFolderID: nil,
            stage: .preparingAudio,
            progress: nil,
            detail: "Preparing captured audio"
        )

        recordingState.beginJob(job)

        var didResetProcessingState = false
        defer {
            if Self.shouldResetProcessingStateOnExit(
                didResetProcessingState: didResetProcessingState,
                isOperationCurrent: operationController.isCurrent(token)
            ) {
                resetProcessingState()
            }
        }

        do {
            let managedAsset = try mediaIngestionService.storeRecordedAudio(
                audioData,
                jobID: occurrenceID ?? job.id,
                displayName: mode.libraryDisplayName,
                sourceKind: .manualCapture
            )
            if let occurrenceID,
               let occurrence = try meetingStore.occurrence(id: occurrenceID) {
                var recoveryAudioURLs = (try? FileManager.default.contentsOfDirectory(
                    at: occurrence.workspaceURL,
                    includingPropertiesForKeys: nil
                ))?.filter { $0.pathExtension.lowercased() == "pcm" } ?? []
                if let adoptedRecoveryID,
                   dictationRecoveryStore.hasAudio(id: adoptedRecoveryID) {
                    recoveryAudioURLs.append(dictationRecoveryStore.audioURL(for: adoptedRecoveryID))
                }
                let sourceHealth = audioRecorder.lastMeetingSourceHealth
                try meetingStore.preserveAudio(
                    id: occurrenceID,
                    managedAudioURL: managedAsset.mediaURL,
                    recoveryAudioURLs: recoveryAudioURLs,
                    microphoneHealth: sourceHealth?.microphone,
                    systemAudioHealth: sourceHealth?.systemAudio,
                    warning: sourceHealth?.warning
                )
                if let warning = sourceHealth?.warning {
                    recordingState.message = localized(
                        warning,
                        locale: settingsStore.selectedAppLocale.locale
                    )
                }
                if sourceHealth?.bothEmpty == true {
                    throw MediaPreparationError.readFailed(
                        "No speech was detected in either microphone or system audio. The audio was preserved for retry."
                    )
                }
            }
            try ensureOperationCurrent(token)

            recordingState.updateJob(
                stage: .transcribing,
                progress: nil,
                detail: job.options.diarizationEnabled ? "Running diarization and transcription" : "Running transcription",
                errorMessage: nil
            )

            let transcriptionOutput = try await transcriptionService.transcribe(
                audioData: audioData,
                diarizationEnabled: job.options.diarizationEnabled,
                options: makeTranscriptionOptions(),
                diarizationOptions: .init(expectedSpeakerCount: job.options.expectedSpeakerCount),
                diarizationFailurePolicy: .required,
                progressHandler: makeTranscriptionProgressHandler()
            )
            try ensureOperationCurrent(token)
            let diarizationSegmentsJSON = encodeDiarizationSegmentsJSON(transcriptionOutput.diarizedSegments)

            recordingState.updateJob(
                stage: .saving,
                progress: nil,
                detail: "Saving transcript to history",
                errorMessage: nil
            )

            let finalText = normalizedTranscriptionText(transcriptionOutput.text)
            guard !isTranscriptionEffectivelyEmpty(finalText) else {
                throw MediaPreparationError.readFailed("No speech could be transcribed from this recording.")
            }

            let workspaceTitle: String?
            if let occurrenceID {
                workspaceTitle = try meetingStore.occurrence(id: occurrenceID)?.calendarTitle
            } else {
                workspaceTitle = nil
            }

            let record = try historyStore.save(
                text: finalText,
                originalText: nil,
                duration: duration,
                modelUsed: settingsStore.selectedModel,
                enhancedWith: nil,
                diarizationSegmentsJSON: diarizationSegmentsJSON,
                sourceKind: managedAsset.sourceKind,
                sourceDisplayName: workspaceTitle ?? managedAsset.displayName,
                generatedTitle: nil,
                aiSummary: nil,
                sourceTitleOrigin: managedAsset.hasSourceMetadataTitle ? .sourceMetadata : .fallback,
                originalSourceURL: managedAsset.originalSourceURL,
                managedMediaPath: managedAsset.mediaURL.path,
                thumbnailPath: managedAsset.thumbnailURL?.path,
                folderID: job.destinationFolderID
            )
            if let occurrenceID {
                try meetingStore.attachTranscript(id: occurrenceID, transcript: record)
                try meetingStore.transition(id: occurrenceID, to: .ready)
                await generateMeetingInsightsIfAllowed(
                    occurrenceID: occurrenceID,
                    transcript: finalText,
                    reportErrorsInRecordingState: false
                )
            }
            if let adoptedRecoveryID {
                try dictationRecoveryStore.complete(id: adoptedRecoveryID)
                if activeDictationRecoveryID == adoptedRecoveryID {
                    activeDictationRecoveryID = nil
                }
            }
            activeMeetingOccurrenceID = nil
            updateRecentTranscriptsMenu()

            if operationController.isCurrent(token) {
                resetProcessingState()
                didResetProcessingState = true
            }
            recordingState.completeCurrentJob(with: record.id, message: "Meeting recording transcribed successfully.")
            let meetingRecordID = record.id
            mainWindowController.showHistory()
            // Post after nav so HistoryView is mounted and listening.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                NotificationCenter.default.post(
                    name: .openHistoryRecord,
                    object: nil,
                    userInfo: ["recordID": meetingRecordID.uuidString]
                )
            }
        } catch is CancellationError {
            // Only the current operation may mutate shared RecordingState after cancel.
            guard operationController.isCurrent(token) else { return }
            resetProcessingState()
            didResetProcessingState = true
            recordingState.clearCurrentJob()
            recordingState.message = localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale)
            if let occurrenceID {
                try? meetingStore.markFailedPreservingWorkspace(
                    id: occurrenceID,
                    message: "Meeting processing was canceled. Retry processing from the saved audio."
                )
            }
            activeMeetingOccurrenceID = nil
        } catch {
            // Stale cancelled work completing after a newer session started: no state mutation.
            guard operationController.isCurrent(token), !Self.isTaskCancellation(error) else { return }
            Log.app.error("Manual media transcription failed: \(error)")
            resetProcessingState()
            didResetProcessingState = true
            recordingState.failCurrentJob(error.localizedDescription)
            if let occurrenceID {
                try? meetingStore.markFailedPreservingWorkspace(
                    id: occurrenceID,
                    message: error.localizedDescription
                )
            }
            if let adoptedRecoveryID {
                _ = try? dictationRecoveryStore.markFailed(id: adoptedRecoveryID, message: error.localizedDescription)
                if activeDictationRecoveryID == adoptedRecoveryID {
                    activeDictationRecoveryID = nil
                }
            }
            activeMeetingOccurrenceID = nil
        }
    }

    func retryMeetingProcessing(_ occurrenceID: UUID) {
        guard !isRecording && !isProcessing else {
            meetingsState.errorMessage = "Finish the active recording or transcription before retrying this meeting."
            return
        }
        Task { @MainActor [weak self] in
            await self?.processPreservedMeeting(occurrenceID)
        }
    }

    func regenerateMeetingInsights(_ occurrenceID: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard self.settingsStore.onDeviceMeetingAIAllowed else {
                    throw LocalMeetingModelError.missingWeights
                }
                guard let transcript = try self.meetingStore.occurrence(id: occurrenceID)?.transcript?.text,
                      !transcript.isEmpty else {
                    throw MediaPreparationError.readFailed("This meeting does not have a transcript yet.")
                }
                try await self.generateAndSaveMeetingInsights(
                    occurrenceID: occurrenceID,
                    transcript: transcript
                )
            } catch {
                self.meetingsState.errorMessage = error.localizedDescription
            }
        }
    }

    private func processPreservedMeeting(_ occurrenceID: UUID) async {
        do {
            guard let occurrence = try meetingStore.occurrence(id: occurrenceID) else {
                throw MeetingStore.StoreError.occurrenceNotFound
            }
            let candidates = [occurrence.managedAudioURL].compactMap { $0 } + occurrence.recoveryAudioURLs
            guard let sourceURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                throw MediaPreparationError.readFailed("No recoverable meeting audio was found.")
            }
            try meetingStore.transition(id: occurrenceID, to: .processing)
            isProcessing = true
            statusBarController.setProcessingState()
            statusBarController.updateMenuState()
            transitionRecordingIndicatorToProcessing()

            let prepared: PreparedMediaAudio
            if sourceURL.pathExtension.lowercased() == "pcm" {
                let data = try Data(contentsOf: sourceURL)
                prepared = PreparedMediaAudio(
                    audioData: data,
                    duration: Double(data.count) / Double(MemoryLayout<Float>.size * 16_000)
                )
            } else {
                prepared = try await mediaPreparationService.prepareAudio(from: sourceURL)
            }

            let output = try await transcriptionService.transcribe(
                audioData: prepared.audioData,
                diarizationEnabled: true,
                options: makeTranscriptionOptions(),
                diarizationOptions: .init(expectedSpeakerCount: occurrence.expectedSpeakerCount),
                diarizationFailurePolicy: .required,
                progressHandler: makeTranscriptionProgressHandler()
            )
            let text = normalizedTranscriptionText(output.text)
            guard !isTranscriptionEffectivelyEmpty(text) else {
                throw MediaPreparationError.readFailed("No speech could be transcribed from the preserved audio.")
            }

            let record = try historyStore.save(
                text: text,
                originalText: nil,
                duration: prepared.duration,
                modelUsed: settingsStore.selectedModel,
                enhancedWith: nil,
                diarizationSegmentsJSON: encodeDiarizationSegmentsJSON(output.diarizedSegments),
                sourceKind: .manualCapture,
                sourceDisplayName: occurrence.calendarTitle ?? occurrence.series?.displayName,
                generatedTitle: nil,
                aiSummary: nil,
                sourceTitleOrigin: .fallback,
                originalSourceURL: nil,
                managedMediaPath: occurrence.managedAudioPath,
                thumbnailPath: nil,
                folderID: nil
            )
            try meetingStore.attachTranscript(id: occurrenceID, transcript: record)
            try meetingStore.transition(id: occurrenceID, to: .ready)
            await generateMeetingInsightsIfAllowed(
                occurrenceID: occurrenceID,
                transcript: text,
                reportErrorsInRecordingState: false
            )
            updateRecentTranscriptsMenu()
            meetingsState.errorMessage = nil
        } catch {
            try? meetingStore.markFailedPreservingWorkspace(
                id: occurrenceID,
                message: error.localizedDescription
            )
            meetingsState.errorMessage = error.localizedDescription
        }
        resetProcessingState()
    }

    private func generateMeetingInsightsIfAllowed(
        occurrenceID: UUID,
        transcript: String,
        reportErrorsInRecordingState: Bool
    ) async {
        guard settingsStore.onDeviceMeetingAIAllowed else { return }
        do {
            try await generateAndSaveMeetingInsights(
                occurrenceID: occurrenceID,
                transcript: transcript
            )
        } catch {
            Log.aiEnhancement.error("On-device meeting insights failed: \(error.localizedDescription)")
            if reportErrorsInRecordingState {
                recordingState.message = error.localizedDescription
            }
        }
    }

    private func generateAndSaveMeetingInsights(
        occurrenceID: UUID,
        transcript: String
    ) async throws {
        guard case .ready = await modelManager.localMeetingModelService.readiness() else {
            throw LocalMeetingModelError.missingWeights
        }
        let insights = try await meetingInsightGenerator.generate(from: transcript)
        try meetingStore.saveInsights(id: occurrenceID, insights: insights)
    }

    private func startMediaTranscriptionTask(for job: MediaTranscriptionJobState) {
        guard mediaTranscriptionTask == nil, !isShutdown else {
            if !isShutdown {
                mediaTranscriptionState.enqueue(job)
            }
            return
        }

        mediaTranscriptionGeneration &+= 1
        let generation = mediaTranscriptionGeneration
        mediaTranscriptionTaskGeneration = generation
        mediaTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performMediaTranscription(job, generation: generation)
            await self.finishMediaTranscriptionTask(generation: generation)
        }
    }

    private func restoreOriginalModelAfterQueueIfNeeded(generation: UInt64) async {
        guard isMediaTranscriptionOwnerCurrent(generation),
              let original = queueOriginalModelName else {
            return
        }

        do {
            try await loadAndActivateModel(
                named: original,
                provider: Self.mediaTranscriptionProvider(
                    named: original,
                    availableModels: modelManager.availableModels
                )
            )
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            queueOriginalModelName = nil
            let restoredName = modelManager.availableModels.first(where: { $0.name == original })?.displayName ?? original
            let locale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Queue complete — restored %@", locale: locale), locale: locale, restoredName),
                    style: .standard
                )
            )
        } catch {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            queueOriginalModelName = nil
            Log.model.error("Failed to restore original model after queue: \(error)")
        }
    }
    
    private func finishMediaTranscriptionTask(generation: UInt64) async {
        guard mediaTranscriptionTaskGeneration == generation else { return }
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaQueueContinuationIfNeeded()
            return
        }

        await continueMediaQueueAsOwner(generation: generation)
    }

    private func startMediaQueueContinuationIfNeeded() {
        guard !isShutdown, mediaTranscriptionTask == nil else { return }
        guard !mediaQueueDeferredUntilIdle else { return }
        guard mediaQueueRestoreRequested
                || mediaQueueNeedsProcessingReset
                || queueOriginalModelName != nil
                || !mediaTranscriptionState.pendingJobs.isEmpty else {
            return
        }

        let generation = mediaTranscriptionGeneration
        mediaTranscriptionTaskGeneration = generation
        mediaTranscriptionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.continueMediaQueueAsOwner(generation: generation)
        }
    }

    private func continueMediaQueueAsOwner(generation: UInt64) async {
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaQueueContinuationIfNeeded()
            return
        }

        // A job just yielded to an active dictation session; park the queue until
        // the session ends (resumeDeferredMediaQueueIfIdle restarts it).
        if mediaQueueDeferredUntilIdle {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            return
        }

        if mediaQueueNeedsProcessingReset {
            resetProcessingState()
            mediaQueueNeedsProcessingReset = false
        }

        if mediaQueueRestoreRequested {
            await restoreOriginalModelAfterQueueIfNeeded(generation: generation)
            guard isMediaTranscriptionOwnerCurrent(generation) else {
                releaseMediaTranscriptionTaskOwnership(generation: generation)
                startMediaQueueContinuationIfNeeded()
                return
            }
            mediaQueueRestoreRequested = false
        }

        if let next = mediaTranscriptionState.dequeueNextJob() {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaTranscriptionTask(for: next)
            return
        }

        await restoreOriginalModelAfterQueueIfNeeded(generation: generation)
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            releaseMediaTranscriptionTaskOwnership(generation: generation)
            startMediaQueueContinuationIfNeeded()
            return
        }
        releaseMediaTranscriptionTaskOwnership(generation: generation)
    }

    private func releaseMediaTranscriptionTaskOwnership(generation: UInt64) {
        guard mediaTranscriptionTaskGeneration == generation else { return }
        mediaTranscriptionTask = nil
        mediaTranscriptionTaskGeneration = nil
    }

    /// Restarts a queue that was paused because a job yielded to a dictation
    /// session. Driven from the isRecording/isProcessing didSets so every path
    /// that returns the pipeline to idle resumes the queue.
    private func resumeDeferredMediaQueueIfIdle() {
        guard mediaQueueDeferredUntilIdle, !isRecording, !isProcessing else { return }
        mediaQueueDeferredUntilIdle = false
        startMediaQueueContinuationIfNeeded()
    }

    private func isMediaTranscriptionOwnerCurrent(_ generation: UInt64) -> Bool {
        !isShutdown
            && mediaTranscriptionGeneration == generation
            && mediaTranscriptionTaskGeneration == generation
    }

    private func ensureMediaTranscriptionOwnerCurrent(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard isMediaTranscriptionOwnerCurrent(generation) else {
            throw CancellationError()
        }
    }

    private func performMediaTranscription(
        _ jobIn: MediaTranscriptionJobState,
        generation: UInt64
    ) async {
        guard isMediaTranscriptionOwnerCurrent(generation) else { return }
        guard !isRecording && !isProcessing else {
            // A dictation session owns the pipeline right now. Put the job back at
            // the head of the queue and pause the queue until the session ends —
            // a bare return here silently lost the dequeued job.
            mediaTranscriptionState.pendingJobs.insert(jobIn, at: 0)
            mediaQueueDeferredUntilIdle = true
            toastService.show(
                ToastPayload(
                    message: localized(
                        "Recording in progress — transcription will start when it finishes.",
                        locale: settingsStore.selectedAppLocale.locale
                    ),
                    style: .standard
                )
            )
            return
        }

        let request = jobIn.request
        let options = jobIn.options

        await modelManager.refreshDownloadedFeatureModels()
        guard isMediaTranscriptionOwnerCurrent(generation), !Task.isCancelled else { return }
        guard !options.diarizationEnabled || modelManager.isFeatureModelDownloaded(.diarization) else {
            let message = localized("Download the speaker diarization model before starting media transcription.", locale: settingsStore.selectedAppLocale.locale)
            // Record the job as failed so it doesn't just vanish from the queue,
            // then surface the setup guidance banner.
            mediaTranscriptionState.beginJob(jobIn)
            mediaTranscriptionState.failCurrentJob(message, returnToLibrary: true)
            mediaTranscriptionState.setSetupIssue(message)
            return
        }

        let job = MediaTranscriptionJobState(
            id: jobIn.id,
            request: request,
            options: options,
            destinationFolderID: mediaTranscriptionState.selectedFolderID ?? jobIn.destinationFolderID,
            stage: request.sourceKind == .webLink ? .preflight : .importing,
            progress: nil,
            detail: request.sourceKind == .webLink ? "Checking yt-dlp and ffmpeg" : "Importing local media"
        )

        mediaTranscriptionState.beginJob(job)
        mainWindowController.showTranscribe()

        isProcessing = true
        statusBarController.setProcessingState()
        statusBarController.updateMenuState()
        startProcessingIndicatorSession()

        var didResetProcessingState = false

        defer {
            if !didResetProcessingState,
               isMediaTranscriptionOwnerCurrent(generation) {
                resetProcessingState()
            }
        }

        do {
            // --- Model preparation ---
            let requestedModel = options.modelName.isEmpty ? settingsStore.selectedModel : options.modelName
            if requestedModel != activeModelName {
                if queueOriginalModelName == nil {
                    queueOriginalModelName = activeModelName
                    let displayName = modelManager.availableModels.first(where: { $0.name == requestedModel })?.displayName ?? requestedModel
                    let locale = settingsStore.selectedAppLocale.locale
                    toastService.show(
                        ToastPayload(
                            message: String(format: localized("Switching to %@ for this queue", locale: locale), locale: locale, displayName),
                            style: .standard
                        )
                    )
                }
                mediaTranscriptionState.updateJob(
                    stage: .preparingModel,
                    progress: nil,
                    detail: "Loading \(requestedModel)…",
                    errorMessage: nil
                )
                try await loadAndActivateModel(
                    named: requestedModel,
                    provider: Self.mediaTranscriptionProvider(
                        named: requestedModel,
                        availableModels: modelManager.availableModels
                    )
                )
            }

            try ensureMediaTranscriptionOwnerCurrent(generation)

            let managedAsset = try await mediaIngestionService.ingest(
                request: request,
                jobID: job.id,
                progressHandler: { [weak self] progress, detail in
                    guard let self,
                          self.isMediaTranscriptionOwnerCurrent(generation) else {
                        return
                    }
                    let stage: MediaTranscriptionStage = request.sourceKind == .webLink ? .downloading : .importing
                    self.mediaTranscriptionState.updateJob(
                        stage: stage,
                        progress: progress,
                        detail: detail,
                        errorMessage: nil
                    )
                }
            )

            try ensureMediaTranscriptionOwnerCurrent(generation)

            mediaTranscriptionState.updateJob(
                stage: .preparingAudio,
                progress: nil,
                detail: "Preparing audio for transcription",
                errorMessage: nil
            )
            let tooling = await mediaIngestionService.checkTooling()
            try ensureMediaTranscriptionOwnerCurrent(generation)
            let preparedAudio = try await mediaPreparationService.prepareAudio(
                from: managedAsset.mediaURL,
                ffmpegPath: tooling.ffmpegPath
            )

            try ensureMediaTranscriptionOwnerCurrent(generation)

            mediaTranscriptionState.updateJob(
                stage: .transcribing,
                progress: nil,
                detail: options.diarizationEnabled ? "Running diarization and transcription" : "Running transcription",
                errorMessage: nil
            )

            let transcriptionOutput = try await transcriptionService.transcribe(
                audioData: preparedAudio.audioData,
                diarizationEnabled: options.diarizationEnabled,
                options: makeTranscriptionOptions(language: options.language),
                diarizationOptions: .init(expectedSpeakerCount: options.expectedSpeakerCount),
                diarizationFailurePolicy: options.diarizationEnabled ? .required : .bestEffort
            )
            try ensureMediaTranscriptionOwnerCurrent(generation)
            let diarizationSegmentsJSON = encodeDiarizationSegmentsJSON(transcriptionOutput.diarizedSegments)

            mediaTranscriptionState.updateJob(
                stage: .saving,
                progress: nil,
                detail: "Saving transcript to history",
                errorMessage: nil
            )

            let renderedText = renderTranscriptionOutput(transcriptionOutput, format: options.outputFormat)
            let finalText = normalizedTranscriptionText(renderedText)
            guard !isTranscriptionEffectivelyEmpty(finalText) else {
                throw MediaPreparationError.readFailed("No speech could be transcribed from this media.")
            }

            let transcriptionMetadata = await generateTranscriptionMetadataIfNeeded(
                from: finalText,
                managedAsset: managedAsset
            )
            try ensureMediaTranscriptionOwnerCurrent(generation)

            let record = try historyStore.save(
                text: finalText,
                originalText: nil,
                duration: preparedAudio.duration,
                modelUsed: activeModelName ?? settingsStore.selectedModel,
                enhancedWith: nil,
                diarizationSegmentsJSON: diarizationSegmentsJSON,
                sourceKind: managedAsset.sourceKind,
                sourceDisplayName: managedAsset.displayName,
                generatedTitle: transcriptionMetadata.generatedTitle,
                aiSummary: transcriptionMetadata.summary,
                sourceTitleOrigin: managedAsset.hasSourceMetadataTitle ? .sourceMetadata : .fallback,
                originalSourceURL: managedAsset.originalSourceURL,
                managedMediaPath: managedAsset.mediaURL.path,
                thumbnailPath: managedAsset.thumbnailURL?.path,
                folderID: job.destinationFolderID
            )
            updateRecentTranscriptsMenu()

            let shouldNavigateToDetail = mediaTranscriptionState.route == .processing(job.id)
            resetProcessingState()
            didResetProcessingState = true
            let completionLocale = settingsStore.selectedAppLocale.locale
            toastService.show(
                ToastPayload(
                    message: String(format: localized("Transcribed: %@", locale: completionLocale), locale: completionLocale, managedAsset.displayName)
                )
            )
            mediaTranscriptionState.completeCurrentJob(with: record.id, shouldNavigateToDetail: shouldNavigateToDetail)
        } catch is CancellationError {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            resetProcessingState()
            didResetProcessingState = true
            mediaTranscriptionState.showLibrary()
            mediaTranscriptionState.clearCurrentJob()
        } catch let error as MediaIngestionError {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            Log.app.error("Media ingestion failed: \(error.localizedDescription)")
            resetProcessingState()
            didResetProcessingState = true
            mediaTranscriptionState.clearCurrentJob()
            if case .toolingUnavailable(let message) = error {
                mediaTranscriptionState.setSetupIssue(message)
            } else {
                toastService.show(ToastPayload(message: error.localizedDescription, style: .error))
            }
        } catch {
            guard isMediaTranscriptionOwnerCurrent(generation) else { return }
            Log.app.error("Media transcription failed: \(error)")
            resetProcessingState()
            didResetProcessingState = true
            let shouldReturnToLibrary = mediaTranscriptionState.route != .processing(job.id)
            mediaTranscriptionState.failCurrentJob(error.localizedDescription, returnToLibrary: shouldReturnToLibrary)
        }
    }

    // MARK: - Output format rendering

    private func renderTranscriptionOutput(_ output: TranscriptionOutput, format: TranscribeOutputFormat) -> String {
        switch format {
        case .plainText:
            return output.text
        case .subtitles:
            guard let segments = output.diarizedSegments, !segments.isEmpty else {
                return output.text
            }
            return TranscriptExportService.formatAsSRT(segments)
        case .timestamps:
            guard let segments = output.diarizedSegments, !segments.isEmpty else {
                return output.text
            }
            return TranscriptExportService.formatAsTimestampedJSON(segments, plainText: output.text)
        }
    }

    private func generateTranscriptionMetadataIfNeeded(
        from transcription: String,
        managedAsset: ManagedMediaAsset
    ) async -> (generatedTitle: String?, summary: String?) {
        guard LocalOnlySecurityPolicy.allowsExternalAI else {
            return (nil, nil)
        }
        guard let assignment = settingsStore.resolveAssignment(for: .transcriptionMetadata) else {
            return (nil, nil)
        }

        do {
            let metadata = try await aiEnhancementService.generateTranscriptionMetadata(
                transcription: transcription,
                assignment: assignment,
                includeTitle: !managedAsset.hasSourceMetadataTitle
            )
            let trimmedSummary = metadata.summary.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            return (
                managedAsset.hasSourceMetadataTitle ? nil : metadata.title,
                trimmedSummary.isEmpty ? nil : trimmedSummary
            )
        } catch {
            Log.aiEnhancement.warning("Transcription metadata generation failed: \(error.localizedDescription)")
            return (nil, nil)
        }
    }

    // MARK: - Clear Audio Buffer

    private func handleClearAudioBuffer() async {
        guard isRecording else {
            finishIndicatorSession()
            return
        }

        guard AlertManager.shared.confirmCancelOperation(isRecording: true) else {
            Log.app.info("Clear audio buffer declined; recording will continue")
            return
        }

        Log.app.info("Clearing audio buffer")
        let recoveryID = activeDictationRecoveryID
        if let recoveryID {
            _ = try? dictationRecoveryStore.markCanceled(id: recoveryID)
            activeDictationRecoveryID = nil
        }
        // Mirror cancel's teardown: invalidate any in-flight operation and stop
        // admission so a half-dispatched stop can't run against the cleared audio.
        operationController.cancel()
        activeOperationTask?.cancel()
        activeOperationTask = nil
        recordingStopAdmission.invalidateCurrentClaim()

        audioRecorder.cancelRecording()
        markActiveMeetingFailed(
            "Meeting capture was canceled. Recoverable audio remains available for retry."
        )
        if streamingSession.isSessionActive {
            await streamingSession.cancel()
        } else {
            streamingSession.deactivate()
        }
        recordingState.endRecording(message: localized("Recording canceled.", locale: settingsStore.selectedAppLocale.locale))
        recordingState.clearCurrentJob()
        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        // Capture modes must not survive a cleared buffer: a lingering note-append
        // mode blocks global dictation (NoteAppendGate) and leaves sticky listening UI.
        isRecordingFeatureCaptureActive = false
        isQuickCaptureMode = false
        clearNoteAppendMode()
        recordingStartTime = nil
        manualExpectedSpeakerCount = nil
        capturedContext = nil
        capturedSnapshot = nil
        capturedAdapterCapabilities = nil
        capturedRoutingSignal = nil
        stopLiveContextSession()
        updateVibeRuntimeStateFromSettings()
        error = nil

        statusBarController.setIdleState()
        statusBarController.updateMenuState()

        finishIndicatorSession()

        if let recoveryID, dictationRecoveryStore.hasAudio(id: recoveryID) {
            showRecoverableRecordingToast(id: recoveryID, wasExplicitlyCanceled: true)
        }
    }

    // MARK: - Cancel Operation

    private func handleCancelOperation() async {
        requestCancelCurrentOperation(source: "hotkey-or-menu")
    }

    // MARK: - Toggle Output Mode

    private func handleToggleOutputMode() {
        let newMode = settingsStore.outputMode == "clipboard" ? "directInsert" : "clipboard"
        settingsStore.outputMode = newMode
        Log.app.info("Output mode changed to: \(newMode)")
    }

    private func ensureAccessibilityPermissionForDirectInsert(trigger: String, showFallbackAlert: Bool) {
        guard outputManager.outputMode == .directInsert else { return }

        let hasPermission = permissionManager.checkAccessibilityPermission()
        if hasPermission {
            hasShownAccessibilityFallbackAlertThisLaunch = false
            ensureGlobalKeyMonitorsIfPossible()
            return
        }

        if !hasRequestedAccessibilityPermissionThisLaunch {
            hasRequestedAccessibilityPermissionThisLaunch = true

            let grantedImmediately = permissionManager.requestAccessibilityPermission(showPrompt: true)
            Log.app.info("Requested Accessibility permission (trigger=\(trigger), grantedImmediately=\(grantedImmediately))")

            permissionManager.refreshAccessibilityPermissionStatus()
        }

        let hasPermissionAfterRequest = permissionManager.checkAccessibilityPermission()
        if hasPermissionAfterRequest {
            hasShownAccessibilityFallbackAlertThisLaunch = false
            ensureGlobalKeyMonitorsIfPossible()
            return
        }

        Log.app.info("Accessibility permission not granted - direct insert will use clipboard fallback")

        if showFallbackAlert && !hasShownAccessibilityFallbackAlertThisLaunch {
            hasShownAccessibilityFallbackAlertThisLaunch = true
            let action = AlertManager.shared.showAccessibilityPermissionAlert()
            if action == .repairPermission {
                repairAccessibilityPermission()
            }
        }

    }

    private func repairAccessibilityPermission() {
        do {
            try permissionManager.repairAccessibilityPermission()
            hasRequestedAccessibilityPermissionThisLaunch = true
            hasShownAccessibilityFallbackAlertThisLaunch = false

            let grantedImmediately = permissionManager.requestAccessibilityPermission(showPrompt: true)
            Log.app.info(
                "Reset stale Accessibility permission and requested a fresh grant "
                    + "(grantedImmediately=\(grantedImmediately))"
            )

            if !grantedImmediately {
                AlertManager.shared.revealAppInFinder()
                AlertManager.shared.openAccessibilitySettings()
            }
        } catch {
            Log.app.error("Failed to repair Accessibility permission: \(error.localizedDescription)")
            AlertManager.shared.showGenericErrorAlert(
                title: localized(
                    "Accessibility Permission Required",
                    locale: settingsStore.selectedAppLocale.locale
                ),
                message: error.localizedDescription
            )
        }
    }

    private func ensureGlobalKeyMonitorsIfPossible() {
        guard permissionManager.checkAccessibilityPermission() else { return }

        setupEscapeKeyMonitor()
        setupModifierKeyMonitor()
    }

    // MARK: - Toggle AI Enhancement

    /// Stashed assignment from the last "disable" toggle. Lives in-memory only so that the
    /// hotkey and menu toggle keep a friendly on/off semantic under v2 — removing the
    /// transcriptionEnhancement assignment effectively disables enhancement, but we hold on
    /// to the configuration so the user can flip it back without re-entering everything.
    /// Not persisted: a fresh launch re-reads whatever assignment exists in settings.
    private var transcriptionEnhancementStash: ModelAssignment?

    private func handleToggleAIEnhancement() {
        if let current = settingsStore.assignment(for: .transcriptionEnhancement) {
            transcriptionEnhancementStash = current
            settingsStore.setAssignment(nil, for: .transcriptionEnhancement)
            Log.app.info("AI enhancement disabled (transcriptionEnhancement assignment removed)")
            stopLiveContextSession()
        } else if let stashed = transcriptionEnhancementStash {
            settingsStore.setAssignment(stashed, for: .transcriptionEnhancement)
            Log.app.info("AI enhancement re-enabled from stashed assignment")
            if isRecording, shouldRunLiveContextSession() {
                startLiveContextSessionIfNeeded(initialSnapshot: capturedSnapshot)
            }
        } else {
            toastService.show(
                ToastPayload(
                    message:
                        "No AI provider configured for transcription enhancement. Open Superduper Dictation Settings → AI Enhancement.",
                    style: .error
                )
            )
        }
        updateVibeRuntimeStateFromSettings()
    }

    // MARK: - Select Prompt Preset

    static func applyPromptPresetSelection(
        _ option: StatusBarController.PromptPresetOption,
        to settingsStore: SettingsStore
    ) -> Bool {
        guard settingsStore.assignment(for: .transcriptionEnhancement) != nil else {
            return false
        }

        // The legacy pointer stores the SwiftData row UUID, while v2 assignments use
        // stable built-in identifiers when available.
        settingsStore.enhanceTranscriptsPresetID = option.assignmentID
        settingsStore.selectedPresetId = option.id
        return true
    }

    private func handleSelectPromptPreset(_ option: StatusBarController.PromptPresetOption) {
        guard Self.applyPromptPresetSelection(option, to: settingsStore) else {
            Log.app.warning("Ignored prompt preset selection while AI enhancement is disabled")
            return
        }

        Log.app.info("Prompt preset changed to: \(option.name)")
        statusBarController.updateDynamicItems()
    }

    // MARK: - Toggle Launch at Login

    private func handleToggleLaunchAtLogin() {
        let newValue = !settingsStore.launchAtLogin
        do {
            try launchAtLoginManager.setEnabled(newValue)
            settingsStore.launchAtLogin = newValue
            let status = newValue ? "enabled" : "disabled"
            Log.app.info("Launch at login \(status)")
        } catch {
            Log.app.error("Failed to toggle launch at login: \(error)")
        }
    }

    private func handleCheckForUpdates() {
        if updateService.shouldDeferUpdate(isRecording: isRecording || isProcessing) {
            AlertManager.shared.showGenericErrorAlert(
                title: "Update Deferred",
                message: "Finish recording or processing before checking for updates."
            )
            return
        }

        updateService.checkForUpdates()
    }

    // MARK: - Open History

    private func handleOpenHistory() {
        mainWindowController.showHistory()
    }

    // MARK: - Show App

    private func handleShowApp() {
        mainWindowController.show()
    }

    // MARK: - Main Menu Actions

    func openNewNoteFromMenu() {
        noteEditorWindowController.show(note: nil, isNewNote: true)
    }

    func exportLastTranscriptFromMenu() async {
        await handleExportLastTranscript()
    }

    func switchToModel(named modelName: String) async {
        guard modelName != activeModelName else {
            Log.app.info("Model \(modelName) is already active")
            return
        }
        
        guard !isRecording && !isProcessing else {
            Log.app.warning("Cannot switch model while recording or processing")
            return
        }
        
        Log.app.info("Switching to model: \(modelName)")
        
        await modelManager.refreshDownloadedModels()
        guard let model = modelManager.availableModels.first(where: { $0.name == modelName }) else {
            Log.app.error("Cannot switch to model \(modelName): not found")
            return
        }
        
        if !modelManager.isModelDownloaded(modelName) {
            Log.app.error("Cannot switch to model \(modelName): not downloaded")
            return
        }
        
        splashController.setLoading("Switching to \(model.displayName)...")
        
        do {
            try await loadAndActivateModel(named: modelName, provider: model.provider)
            settingsStore.selectedModel = modelName
            statusBarController.updateDynamicItems()
            Log.model.info("Switched to model \(modelName) successfully")
        } catch {
            if model.provider == .whisperKit {
                do {
                    try await attemptWhisperModelRepairAndReload(
                        modelName: modelName,
                        displayName: model.displayName,
                        loadError: error
                    )
                    settingsStore.selectedModel = modelName
                    statusBarController.updateDynamicItems()
                    Log.model.info("Model repaired and switched successfully: \(modelName)")
                    return
                } catch {
                    handleModelLoadError(error, context: "Failed to repair switched model")
                    AlertManager.shared.showModelLoadErrorAlert(error: error)
                    return
                }
            }

            handleModelLoadError(error, context: "Failed to switch model")
            AlertManager.shared.showModelLoadErrorAlert(error: error)
        }
    }
    
    // MARK: - Update Recent Transcripts

    private func updateRecentTranscriptsMenu() {
        Task {
            do {
                let records = try historyStore.fetch(limit: 5)
                let transcripts = records.map { (id: $0.id, text: $0.text, timestamp: $0.timestamp) }
                await MainActor.run {
                    statusBarController.updateRecentTranscripts(transcripts)
                }
            } catch {
                Log.app.error("Failed to update recent transcripts: \(error)")
            }
        }
    }

    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true

        // Stop Carbon callbacks first. The sources must be disabled and detached on
        // their owning run loop before the pass-unretained coordinator refcon can die.
        liveContextKeyRefreshGate.setEnabled(false)
        escapeEventState.setShouldSuppress(false)
        teardownEscapeKeyMonitor()
        teardownModifierKeyMonitor()
        removeEscapeGlobalMonitorFallbackIfNeeded()
        removeModifierGlobalMonitorFallbackIfNeeded()
        eventTapRunLoopThread.stopIfNeeded()

        notificationResources.tearDown()
        cancellables.removeAll()

        floatingIndicatorHiddenTask?.cancel()
        floatingIndicatorHiddenTask = nil
        escapeEventTapRecoveryTask?.cancel()
        escapeEventTapRecoveryTask = nil
        modifierEventTapRecoveryTask?.cancel()
        modifierEventTapRecoveryTask = nil

        stopLiveContextSession()
        operationController.cancel()
        recordingStopAdmission.invalidateCurrentClaim()
        activeOperationTask?.cancel()
        activeOperationTask = nil

        mediaTranscriptionGeneration &+= 1
        mediaTranscriptionTask?.cancel()
        mediaQueueRestoreRequested = false
        mediaQueueNeedsProcessingReset = false
        mediaQueueDeferredUntilIdle = false
        mediaTranscriptionState.clearAllJobs()

        streamingSession.cancelDetached()
        audioRecorder.resetAudioEngine()
        mediaPauseService.endRecordingSession()
        isRecording = false
        isProcessing = false
        isRecordingFeatureCaptureActive = false
        automaticDictionaryLearningService.cancelObservation()

        inputMuteMonitor?.stop()
        inputMuteMonitor = nil
        inputDeviceListMonitor?.stop()
        inputDeviceListMonitor = nil
        floatingIndicatorFocusTracker.stop()

        hotkeyManager.unregisterAll()
        stopMCPServerIfRunning()
        dictationAudioRetentionService.stopPeriodicSweep()
    }
}
