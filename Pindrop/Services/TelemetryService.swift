//
//  TelemetryService.swift
//  Pindrop
//
//  Created on 2026-07-14.
//
//  Telemetry compatibility seam retained from upstream. This fork ships without a
//  telemetry SDK or app identifier, so the production sink never sends data.
//

import Foundation

@MainActor
protocol TelemetrySink: AnyObject {
    func initialize(appID: String)
    func send(_ signalName: String, parameters: [String: String])
}

@MainActor
final class LiveTelemetrySink: TelemetrySink {
    func initialize(appID _: String) {}

    func send(_: String, parameters _: [String: String]) {}
}

@MainActor
final class TelemetryService {
    /// Deliberately empty in the local-only build. Telemetry is therefore disabled
    /// before a sink can initialize and the consent prompt never appears.
    nonisolated static let telemetryDeckAppID = ""

    /// Retained for compatibility with the upstream coordinator and unit tests.
    nonisolated static let successSampleRate: Double = 1.0

    private let settingsStore: SettingsStore
    private let sink: TelemetrySink
    private let appID: String
    private let isSuppressed: () -> Bool
    private let randomUnit: () -> Double
    private var didInitializeSink = false

    init(
        settingsStore: SettingsStore,
        sink: TelemetrySink? = nil,
        appID: String = TelemetryService.telemetryDeckAppID,
        isSuppressed: @escaping () -> Bool = { AppTestMode.isRunningAnyTests },
        randomUnit: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.settingsStore = settingsStore
        self.sink = sink ?? LiveTelemetrySink()
        self.appID = appID
        self.isSuppressed = isSuppressed
        self.randomUnit = randomUnit
    }

    var isConfigured: Bool {
        !appID.isEmpty
    }

    private var isEnabled: Bool {
        isConfigured && !isSuppressed() && settingsStore.telemetryEnabled
    }

    /// Sends one signal when telemetry is enabled. `sampleRate` below 1.0 drops the
    /// signal probabilistically — use only for high-volume success events.
    func send(
        _ event: TelemetryEvent,
        parameters: [String: String] = [:],
        sampleRate: Double = 1.0
    ) {
        guard isEnabled else { return }
        if sampleRate < 1.0, randomUnit() >= sampleRate {
            return
        }
        if !didInitializeSink {
            didInitializeSink = true
            sink.initialize(appID: appID)
            Log.telemetry.info("Telemetry sink initialized")
        }
        sink.send(event.rawValue, parameters: parameters)
        Log.telemetry.debug("Signal sent: \(event.rawValue)")
    }

    // MARK: - Sanitizers

    /// Reduces an error to `TypeName.caseLabel` with associated values stripped —
    /// they routinely carry file paths, URLs, and provider messages that must not
    /// leave the device. Non-enum errors are reduced to their bare type name.
    nonisolated static func errorCaseName(_ error: Error) -> String {
        let typeName = String(describing: type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else {
            return typeName
        }
        if let caseLabel = mirror.children.first?.label {
            return "\(typeName).\(caseLabel)"
        }
        // A case without associated values has no children; its description is the
        // bare case name.
        return "\(typeName).\(String(describing: error))"
    }

    nonisolated static func durationBucket(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<5: return "<5s"
        case ..<15: return "5-15s"
        case ..<60: return "15-60s"
        case ..<300: return "1-5m"
        default: return ">5m"
        }
    }

    /// Buckets pipeline stage latencies. Finer-grained than `durationBucket`
    /// because the interesting range for stop→paste latency is seconds, not minutes.
    nonisolated static func latencyBucket(_ seconds: Double) -> String {
        switch seconds {
        case ..<0.5: return "<0.5s"
        case ..<1: return "0.5-1s"
        case ..<2: return "1-2s"
        case ..<5: return "2-5s"
        case ..<10: return "5-10s"
        default: return ">10s"
        }
    }

    nonisolated static func wordCountBucket(_ count: Int) -> String {
        switch count {
        case ..<1: return "0"
        case ..<11: return "1-10"
        case ..<51: return "11-50"
        case ..<201: return "51-200"
        default: return ">200"
        }
    }
}
