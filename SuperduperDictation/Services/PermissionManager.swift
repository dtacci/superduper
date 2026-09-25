//
//  PermissionManager.swift
//  SuperduperDictation
//
//  Created on 2026-01-25.
//

import Foundation
import AVFoundation
import ApplicationServices
import AppKit
import Observation

/// Protocol for permission checking, enabling mock-based testing.
protocol PermissionProviding: AnyObject {
    func requestPermission() async -> Bool
    func requestSystemAudioPermission() async -> Bool
}

extension PermissionProviding {
    func requestSystemAudioPermission() async -> Bool { true }
}

extension PermissionManager: PermissionProviding {}

protocol AccessibilityPermissionResetting {
    func reset(bundleIdentifier: String) throws
}

enum AccessibilityPermissionRepairError: Error, LocalizedError {
    case missingBundleIdentifier
    case resetUnavailable(String)
    case resetFailed(status: Int32, detail: String)

    var errorDescription: String? {
        switch self {
        case .missingBundleIdentifier:
            return "The app bundle identifier is unavailable, "
                + "so Accessibility permission could not be repaired."
        case .resetUnavailable(let detail):
            return "The macOS Accessibility repair tool could not be started. \(detail)"
        case .resetFailed(let status, let detail):
            let suffix = detail.isEmpty ? "" : " \(detail)"
            return "macOS could not reset Accessibility permission (status \(status)).\(suffix)"
        }
    }
}

final class TCCAccessibilityPermissionResetter: AccessibilityPermissionResetting {
    func reset(bundleIdentifier: String) throws {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", bundleIdentifier]
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            throw AccessibilityPermissionRepairError.resetUnavailable(error.localizedDescription)
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw AccessibilityPermissionRepairError.resetFailed(
                status: process.terminationStatus,
                detail: detail
            )
        }
    }
}

@MainActor
@Observable
final class PermissionManager {

    struct MicrophoneAuthorizationSnapshot {
        let resolvedStatus: AVAuthorizationStatus
        let audioApplicationStatus: String
        let captureDeviceStatus: String
        let hasRequestedThisLaunch: Bool
        let cachedDecision: Bool?
    }
    
    // MARK: - Microphone Permission
    
    private(set) var permissionStatus: AVAuthorizationStatus
    private var pendingMicrophonePermissionRequest: Task<Bool, Never>?
    private var hasRequestedMicrophonePermissionThisLaunch = false
    private var cachedMicrophonePermissionDecision: Bool?
    
    var isAuthorized: Bool {
        permissionStatus == .authorized
    }
    
    var isDenied: Bool {
        permissionStatus == .denied || permissionStatus == .restricted
    }
    
    // MARK: - Accessibility Permission

    private(set) var accessibilityPermissionGranted: Bool

    var isAccessibilityAuthorized: Bool {
        accessibilityPermissionGranted
    }

    private static var isPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["SUPERDUPER_TEST_MODE"] == "1"
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static var shouldSuppressSystemPermissionPrompts: Bool {
        isPreview || isRunningTests
    }

    private static var hasRequestedAccessibilityPermissionPromptThisLaunch = false

    private let accessibilityPermissionResetter: any AccessibilityPermissionResetting
    private let bundleIdentifierProvider: () -> String?
    
    init(
        accessibilityPermissionResetter: any AccessibilityPermissionResetting =
            TCCAccessibilityPermissionResetter(),
        bundleIdentifierProvider: @escaping () -> String? = { Bundle.main.bundleIdentifier }
    ) {
        self.accessibilityPermissionResetter = accessibilityPermissionResetter
        self.bundleIdentifierProvider = bundleIdentifierProvider

        if Self.isPreview {
            self.permissionStatus = .notDetermined
            self.accessibilityPermissionGranted = false
        } else {
            self.permissionStatus = Self.resolveMicrophonePermissionStatus(
                audioPermission: AVAudioApplication.shared.recordPermission,
                capturePermission: AVCaptureDevice.authorizationStatus(for: .audio)
            )
            self.accessibilityPermissionGranted = AXIsProcessTrusted()
        }
    }
    
    // MARK: - Microphone Permission Methods
    
    func checkPermissionStatus() -> AVAuthorizationStatus {
        let status = currentMicrophonePermissionStatus()

        if status == .notDetermined,
           hasRequestedMicrophonePermissionThisLaunch,
           let cachedDecision = cachedMicrophonePermissionDecision {
            permissionStatus = cachedDecision ? .authorized : .denied
            return permissionStatus
        }

        permissionStatus = status
        return status
    }
    
    func requestPermission() async -> Bool {
        let status = currentMicrophonePermissionStatus()
        permissionStatus = status

        switch status {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            if Self.shouldSuppressSystemPermissionPrompts {
                hasRequestedMicrophonePermissionThisLaunch = true
                let simulatedDecision = cachedMicrophonePermissionDecision ?? false
                cachedMicrophonePermissionDecision = simulatedDecision
                permissionStatus = simulatedDecision ? .authorized : .denied
                return simulatedDecision
            }

            if let pendingRequest = pendingMicrophonePermissionRequest {
                return await pendingRequest.value
            }

            if hasRequestedMicrophonePermissionThisLaunch,
               let cachedDecision = cachedMicrophonePermissionDecision {
                permissionStatus = cachedDecision ? .authorized : .denied
                return cachedDecision
            }

            hasRequestedMicrophonePermissionThisLaunch = true

            let requestTask = Task { () -> Bool in
                await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }
            pendingMicrophonePermissionRequest = requestTask

            let granted = await requestTask.value
            pendingMicrophonePermissionRequest = nil
            cachedMicrophonePermissionDecision = granted

            await refreshPermissionStatus()

            if permissionStatus == .notDetermined {
                permissionStatus = granted ? .authorized : .denied
            }

            return granted
        @unknown default:
            return false
        }
    }
    
    func refreshPermissionStatus() async {
        let status = currentMicrophonePermissionStatus()

        if status == .notDetermined,
           hasRequestedMicrophonePermissionThisLaunch,
           let cachedDecision = cachedMicrophonePermissionDecision {
            permissionStatus = cachedDecision ? .authorized : .denied
            return
        }

        permissionStatus = status
    }

    func requestSystemAudioPermission() async -> Bool {
        guard #available(macOS 14.2, *) else {
            return false
        }

        if Self.shouldSuppressSystemPermissionPrompts {
            return true
        }

        // Creating a process tap succeeds even without the system-audio TCC grant
        // (the tap then delivers pure silence), so ask TCC directly first.
        switch SystemAudioRecordingPermission.status() {
        case .authorized:
            return true
        case .denied:
            Log.audio.warning("System audio recording permission is denied for this app")
            return false
        case .undetermined:
            if let granted = await SystemAudioRecordingPermission.request() {
                Log.audio.info("System audio recording permission request answered: granted=\(granted)")
                return granted
            }
        }

        // TCC SPI unavailable: fall back to the tap probe, which can only detect
        // hard failures. Silent capture is still caught live during the meeting.
        return await Task.detached(priority: .userInitiated) {
            SystemAudioTapCaptureBackend.probeSystemAudioTapAccess()
        }.value
    }

    func openSystemAudioRecordingPreferences() {
        guard !Self.shouldSuppressSystemPermissionPrompts else { return }

        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func microphoneAuthorizationSnapshot() -> MicrophoneAuthorizationSnapshot {
        let audioStatus = AVAudioApplication.shared.recordPermission
        let captureStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        return MicrophoneAuthorizationSnapshot(
            resolvedStatus: Self.resolveMicrophonePermissionStatus(
                audioPermission: audioStatus,
                capturePermission: captureStatus
            ),
            audioApplicationStatus: Self.describeAudioApplicationPermission(audioStatus),
            captureDeviceStatus: Self.describeCapturePermission(captureStatus),
            hasRequestedThisLaunch: hasRequestedMicrophonePermissionThisLaunch,
            cachedDecision: cachedMicrophonePermissionDecision
        )
    }

    private func currentMicrophonePermissionStatus() -> AVAuthorizationStatus {
        Self.resolveMicrophonePermissionStatus(
            audioPermission: AVAudioApplication.shared.recordPermission,
            capturePermission: AVCaptureDevice.authorizationStatus(for: .audio)
        )
    }

    private static func resolveMicrophonePermissionStatus(
        audioPermission: AVAudioApplication.recordPermission,
        capturePermission: AVAuthorizationStatus
    ) -> AVAuthorizationStatus {
        let audioStatus: AVAuthorizationStatus
        switch audioPermission {
        case .granted:
            audioStatus = .authorized
        case .denied:
            audioStatus = .denied
        case .undetermined:
            audioStatus = .notDetermined
        @unknown default:
            audioStatus = .notDetermined
        }

        if audioStatus == .authorized || capturePermission == .authorized {
            return .authorized
        }

        if capturePermission == .restricted {
            return .restricted
        }

        if audioStatus == .denied || capturePermission == .denied {
            return .denied
        }

        return .notDetermined
    }

    private static func describeAudioApplicationPermission(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .granted:
            return "granted"
        case .denied:
            return "denied"
        case .undetermined:
            return "undetermined"
        @unknown default:
            return "unknown"
        }
    }

    private static func describeCapturePermission(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized:
            return "authorized"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .notDetermined:
            return "notDetermined"
        @unknown default:
            return "unknown"
        }
    }
    
    // MARK: - Accessibility Permission Methods
    
    func checkAccessibilityPermission() -> Bool {
        let trusted = AXIsProcessTrusted()
        accessibilityPermissionGranted = trusted
        return trusted
    }
    
    func requestAccessibilityPermission(showPrompt: Bool = true) -> Bool {
        let currentlyTrusted = AXIsProcessTrusted()
        accessibilityPermissionGranted = currentlyTrusted

        guard !currentlyTrusted else {
            return true
        }

        let shouldPrompt = showPrompt
            && !Self.shouldSuppressSystemPermissionPrompts
            && !Self.hasRequestedAccessibilityPermissionPromptThisLaunch

        if shouldPrompt {
            Self.hasRequestedAccessibilityPermissionPromptThisLaunch = true
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: shouldPrompt] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityPermissionGranted = trusted
        return trusted
    }
    
    func refreshAccessibilityPermissionStatus() {
        accessibilityPermissionGranted = AXIsProcessTrusted()
    }

    /// Removes only this app's stale Accessibility record. This is useful after a
    /// local build was replaced by another binary whose code-signing requirement no
    /// longer matches the entry displayed in System Settings. macOS still requires
    /// the user to approve the freshly requested grant.
    func repairAccessibilityPermission() throws {
        guard let bundleIdentifier = bundleIdentifierProvider()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleIdentifier.isEmpty else {
            throw AccessibilityPermissionRepairError.missingBundleIdentifier
        }

        try accessibilityPermissionResetter.reset(bundleIdentifier: bundleIdentifier)
        accessibilityPermissionGranted = false
        Self.hasRequestedAccessibilityPermissionPromptThisLaunch = false
    }
    
    func openAccessibilityPreferences() {
        guard !Self.shouldSuppressSystemPermissionPrompts else { return }

        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

}

/// System-audio capture ("Screen & System Audio Recording") has no public status or
/// request API: creating a Core Audio process tap succeeds without the grant and then
/// delivers pure silence. These TCC calls are the ones audio-capture tools such as
/// AudioCap use; every entry point degrades gracefully if the symbols are missing.
enum SystemAudioRecordingPermission {
    enum Status: Equatable {
        case authorized
        case denied
        case undetermined
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (
        CFString,
        CFDictionary?,
        @escaping @convention(block) (Bool) -> Void
    ) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let frameworkHandle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
        RTLD_NOW
    )

    static func status() -> Status {
        guard let frameworkHandle,
              let symbol = dlsym(frameworkHandle, "TCCAccessPreflight") else {
            return .undetermined
        }
        let preflight = unsafeBitCast(symbol, to: PreflightFunction.self)
        return status(fromPreflightResult: preflight(service, nil))
    }

    /// Shows the system consent prompt when the decision is still open. Returns nil
    /// when the request API is unavailable.
    static func request() async -> Bool? {
        guard let frameworkHandle,
              let symbol = dlsym(frameworkHandle, "TCCAccessRequest") else {
            return nil
        }
        let request = unsafeBitCast(symbol, to: RequestFunction.self)
        return await withCheckedContinuation { continuation in
            request(service, nil) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static func status(fromPreflightResult result: Int) -> Status {
        switch result {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }
}
