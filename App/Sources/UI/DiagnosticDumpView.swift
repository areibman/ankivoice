import SwiftUI
import Speech
import AVFoundation
import UIKit

/// Shows the exact, raw state of Apple's speech frameworks on this device.
/// Designed so the user can copy-paste the output back to the developer.
struct DiagnosticDumpView: View {
    @State private var report: String = "Loading..."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AnkiVoice \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))")
                    .font(.headline)
                Text("Bundle: \(Bundle.main.bundleIdentifier ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("iOS \(UIDevice.current.systemVersion) · \(UIDevice.current.model)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = report
                } label: {
                    Label("Copy diagnostic report", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .navigationTitle("Diagnostic dump")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refresh() }
    }

    @MainActor
    private func refresh() async {
        var output = ""

        // Speech Recognition
        let available = SpeechTranscriber.isAvailable
        output += "SpeechTranscriber.isAvailable: \(available)\n"
        let supported = await SpeechTranscriber.supportedLocales
        output += "Supported locales: \(supported.count) (en-US: \(supported.contains { $0.identifier == "en-US" }))\n"
        let installed = await SpeechTranscriber.installedLocales
        output += "Installed locales: \(installed.map { $0.identifier }.joined(separator: ", "))\n"

        let enUS = Locale(identifier: "en-US")
        let probe = SpeechTranscriber(locale: enUS, preset: .transcription)
        let assetStatus = await AssetInventory.status(forModules: [probe])
        output += "en-US asset status: \(String(describing: assetStatus))\n"
        let max = AssetInventory.maximumReservedLocales
        output += "max reserved locales: \(max)\n"
        let reserved = (try? await AssetInventory.reservedLocales) ?? []
        output += "currently reserved: \(reserved.map { $0.identifier }.joined(separator: ", "))\n"

        do {
            let r = try await AssetInventory.reserve(locale: enUS)
            output += "AssetInventory.reserve(en-US) returned: \(r)\n"
        } catch {
            output += "AssetInventory.reserve threw: \(error)\n"
        }

        // Crash / hang reports (MetricKit)
        output += "\nCrash reports:\n"
        output += CrashReporter.summary()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n") + "\n"

        // TTS Voices — the full list, so voice-selection problems can be
        // diagnosed from a pasted report.
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .sorted { ($0.language, $0.name) < ($1.language, $1.name) }
        output += "\nInstalled voices (\(voices.count)):\n"
        for v in voices {
            let q = v.quality == .premium ? "premium" : v.quality == .enhanced ? "enhanced" : "compact"
            let personal = v.voiceTraits.contains(.isPersonalVoice) ? " personal" : ""
            let novelty = v.voiceTraits.contains(.isNoveltyVoice) ? " novelty" : ""
            output += "  \(v.name) | \(v.language) | \(q)\(personal)\(novelty) | \(v.identifier)\n"
        }

        // Audio Session
        output += "\nAudio session:\n"
        output += "  category: \(AVAudioSession.sharedInstance().category.rawValue)\n"
        output += "  mode: \(AVAudioSession.sharedInstance().mode.rawValue)\n"
        output += "  sample rate: \(AVAudioSession.sharedInstance().sampleRate)\n"

        // Info.plist verification
        if let dict = Bundle.main.infoDictionary {
            output += "\nInfo.plist:\n"
            output += "  NSMicrophoneUsageDescription: \((dict["NSMicrophoneUsageDescription"] as? String) != nil ? "present" : "MISSING")\n"
            output += "  NSSpeechRecognitionUsageDescription: \((dict["NSSpeechRecognitionUsageDescription"] as? String) != nil ? "present" : "MISSING")\n"
        }

        report = output
    }
}
