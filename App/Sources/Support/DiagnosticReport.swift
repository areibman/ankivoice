import AVFoundation
import Foundation
import Speech
import UIKit

/// Plain-text snapshot of everything that matters for a voice bug report:
/// build, device, the speech recognizer the engine uses, installed voices,
/// audio session and any MetricKit crash/hang reports.
enum DiagnosticReport {
    @MainActor
    static func generate(commandLocale: String) -> String {
        let info = Bundle.main.infoDictionary
        var out = "AnkiVoice \(SettingsView.versionString) · \(Bundle.main.bundleIdentifier ?? "?")\n"
        out += "iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)\n"

        let report = DeviceSpeechCapabilities.report(commandLocale: commandLocale)
        out += "\nSpeech recognition (\(report.commandLocale)):\n"
        out += "  supported: \(report.speechRecognitionSupported)\n"
        out += "  on-device model installed: \(report.speechAssetsInstalled)\n"
        out += "  authorization: \(describe(SFSpeechRecognizer.authorizationStatus()))\n"
        out += "  microphone: \(describe(AVAudioApplication.shared.recordPermission))\n"

        let voices = AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        out += "\nInstalled voices (\(voices.count)):\n"
        for voice in voices {
            let quality = voice.quality == .premium ? "premium" : voice.quality == .enhanced ? "enhanced" : "compact"
            let personal = voice.voiceTraits.contains(.isPersonalVoice) ? " personal" : ""
            let novelty = voice.voiceTraits.contains(.isNoveltyVoice) ? " novelty" : ""
            out += "  \(voice.name) | \(voice.language) | \(quality)\(personal)\(novelty) | \(voice.identifier)\n"
        }

        out += "\nSupertonic 3:\n"
        out += "  phase: \(describe(SupertonicTTS.shared.phase))\n"
        out += "  languages: \(SupertonicVoiceCatalog.languages.map(\.key).joined(separator: ", "))\n"

        let session = AVAudioSession.sharedInstance()
        out += "\nAudio session: \(session.category.rawValue) / \(session.mode.rawValue) @ \(session.sampleRate) Hz\n"
        out += "Output route: \(session.currentRoute.outputs.first?.portName ?? "none")\n"

        out += "\nInfo.plist usage strings: microphone \(info?["NSMicrophoneUsageDescription"] == nil ? "MISSING" : "present"), "
        out += "speech \(info?["NSSpeechRecognitionUsageDescription"] == nil ? "MISSING" : "present")\n"

        out += "\nCrash reports:\n"
        out += CrashReporter.summary()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
        return out
    }

    private static func describe(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ permission: AVAudioApplication.recordPermission) -> String {
        switch permission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "not determined"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ phase: SupertonicTTS.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .downloading: return "downloading"
        case .ready: return "ready"
        case .failed(let message): return "failed (\(message))"
        }
    }
}
