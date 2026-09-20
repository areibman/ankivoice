import Foundation
import AVFAudio
import os

private let audioLog = Logger(subsystem: "local.ankivoice", category: "audio-session")

/// Configures and observes the shared AVAudioSession for hands-free study
/// (PRD §15, §33, §34).
///
/// - `playAndRecord` + background audio: TTS and microphone both work while
///   the screen is locked.
/// - Bluetooth (AirPods/HFP), wired, and speaker routes supported.
/// - Interruptions (calls, Siri, alarms) and route changes are surfaced to
///   the session controller, which pauses safely.
@MainActor
public final class AudioSessionController {

    public static let shared = AudioSessionController()

    /// Callbacks are invoked on the main actor; they're `@Sendable` so they
    /// may freely hand off to other contexts (e.g. an AsyncStream).
    public var onInterruptionBegan: (@Sendable () -> Void)?
    public var onInterruptionEnded: (@Sendable () -> Void)?
    public var onRouteChanged: (@Sendable (_ old: String, _ new: String) -> Void)?
    public var onMediaServicesLost: (@Sendable () -> Void)?

    private var observers: [NSObjectProtocol] = []

    private init() {}

    /// Category and options used for every activation. `playAndRecord` plus
    /// the `audio` background mode is what keeps the microphone and TTS alive
    /// while the screen is locked.
    private static let options: AVAudioSession.CategoryOptions =
        [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]

    /// Activates the shared session for combined playback and recording.
    public func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: Self.options)
        try session.setActive(true, options: [])
        startObserving()
    }

    /// Re-asserts the category and activates, reporting failure instead of
    /// throwing.
    ///
    /// Activation is routinely refused for a moment when it happens outside
    /// the foreground — the tail of a call or Siri turn, or the instant the
    /// screen locks — with `!int` (cannot interrupt others) or `!rec` (cannot
    /// start recording). Those clear on their own once the other client lets
    /// go of the route, so retry briefly before treating it as a real failure.
    @discardableResult
    public func activateForRecording(attempts: Int = 4) async -> Bool {
        for attempt in 0..<max(attempts, 1) {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(120 * attempt))
            }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, mode: .spokenAudio, options: Self.options)
                try session.setActive(true, options: [])
                startObserving()
                return true
            } catch {
                audioLog.error(
                    "[AUDIO] activation attempt \(attempt + 1) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        return false
    }

    public func deactivate() {
        stopObserving()
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    /// Current human-readable output route, e.g. "AirPods Pro Headphones".
    private nonisolated static func currentRouteDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        return route.outputs.first?.portName ?? "Unknown"
    }

    // MARK: - Observation


    private nonisolated static func previousRoutePortName(from notification: Notification) -> String? {
        guard let route = notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription else {
            return nil
        }
        return route.outputs.first?.portName
    }

    /// Sendable digest of an AVAudioSession notification, extracted on the
    /// posting thread so nothing non-Sendable crosses onto the main actor.
    private enum Event: Sendable {
        case interruptionBegan
        case interruptionEnded
        case routeChanged(previous: String, current: String)
        case mediaServicesLost
        case mediaServicesReset
    }

    private nonisolated static func event(for name: Notification.Name, _ notification: Notification) -> Event? {
        switch name {
        case AVAudioSession.interruptionNotification:
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return nil }
            switch type {
            case .began: return .interruptionBegan
            // Whether or not the system suggests resuming, surface the end so
            // the session controller can decide (explicit resume is required
            // either way).
            case .ended: return .interruptionEnded
            @unknown default: return nil
            }
        case AVAudioSession.routeChangeNotification:
            return .routeChanged(
                previous: previousRoutePortName(from: notification) ?? "Unknown",
                current: currentRouteDescription()
            )
        case AVAudioSession.mediaServicesWereLostNotification:
            return .mediaServicesLost
        case AVAudioSession.mediaServicesWereResetNotification:
            return .mediaServicesReset
        default:
            return nil
        }
    }

    /// AVAudioSession posts from its own threads. Touching the callback
    /// properties (main-actor state) there is a data race — and under Swift 6
    /// an "incorrect actor executor" trap — so the notification is digested
    /// off-actor and handled on the main queue.
    private func observe(_ name: Notification.Name) {
        let observer = NotificationCenter.default.addObserver(
            forName: name,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let event = Self.event(for: name, notification) else { return }
            MainActor.assumeIsolated {
                self?.handle(event)
            }
        }
        observers.append(observer)
    }

    private func handle(_ event: Event) {
        switch event {
        case .interruptionBegan:
            onInterruptionBegan?()
        case .interruptionEnded:
            onInterruptionEnded?()
        case .routeChanged(let previous, let current):
            onRouteChanged?(previous, current)
        case .mediaServicesLost:
            onMediaServicesLost?()
        case .mediaServicesReset:
            // The session died and was reset; re-activate and notify.
            let notify = onMediaServicesLost
            Task { [weak self] in
                await self?.activateForRecording()
                notify?()
            }
        }
    }

    private func startObserving() {
        guard observers.isEmpty else { return }
        observe(AVAudioSession.interruptionNotification)
        observe(AVAudioSession.routeChangeNotification)
        observe(AVAudioSession.mediaServicesWereLostNotification)
        observe(AVAudioSession.mediaServicesWereResetNotification)
    }

    private func stopObserving() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
