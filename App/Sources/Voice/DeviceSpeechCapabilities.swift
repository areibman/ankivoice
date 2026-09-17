import Foundation
import Speech
import AVFAudio

/// Describes what's actually installed on the user's device so the app can
/// give actionable, specific diagnostics instead of "Recognition stopped:
/// RecogRejected" — the user's actual pain.
///
/// Speech recognition assets are separate from TTS voices:
/// - **Speech assets** are downloaded via Apple's `AssetInventory` (or via
///   Settings → General → Keyboard → Dictation which downloads the same
///   assets for free).
/// - **TTS voices** are installed via Settings → Accessibility → Read &
///   Speak → Voices (called Spoken Content before iOS 26). Siri voices are
///   not available to third-party apps.
public struct DeviceSpeechReport: Sendable, Equatable {
    public var commandLocale: String
    public var speechRecognitionSupported: Bool
    public var speechAssetsInstalled: Bool
    public var ttsVoicesForLocale: [VoiceSummary]
    public var highestAvailableTTSQuality: VoiceQualityTier?

    public struct VoiceSummary: Sendable, Equatable {
        public let identifier: String
        public let name: String
        public let language: String
        public let quality: VoiceQualityTier
    }

    /// Plain-language next-steps for the user, derived from the report.
    /// Includes a "you need to do this" instruction when something is missing.
    public var nextSteps: [String] {
        var steps: [String] = []
        if !speechRecognitionSupported {
            steps.append("Speech recognition isn't available on this device. Try a newer iPhone or iOS version.")
        } else if !speechAssetsInstalled {
            steps.append(
                "Speech recognition assets aren't installed for \(commandLocale). " +
                "Open Settings → General → Keyboard → Dictation → turn it on. " +
                "This downloads the English (US) model that AnkiVoice needs. " +
                "Stay on Wi-Fi — the download is ~500 MB."
            )
        }
        let premium = ttsVoicesForLocale.first { $0.quality == .premium }
        if premium == nil {
            let hasEnhanced = ttsVoicesForLocale.contains { $0.quality == .enhanced }
            if !hasEnhanced {
                steps.append(
                    "The voices installed for \(commandLocale) are all compact " +
                    "(they sound robotic). Open Settings → Accessibility → " +
                    "Read & Speak → Voices → \(Self.languageName(commandLocale)) and download a " +
                    "Premium voice (e.g. Ava or Evan). Siri voices can't be used by apps."
                )
            } else {
                steps.append(
                    "For the most natural speech, open Settings → Accessibility → " +
                    "Read & Speak → Voices → \(Self.languageName(commandLocale)) and download a Premium " +
                    "voice. AnkiVoice prefers Premium when available."
                )
            }
        }
        return steps
    }

    static func languageName(_ locale: String) -> String {
        let code = String(locale.replacingOccurrences(of: "_", with: "-").split(separator: "-").first ?? "")
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? locale
    }

    public var readyForVoiceLoop: Bool {
        speechRecognitionSupported && speechAssetsInstalled
    }

    public var recommendedTTSVoiceIdentifier: String? {
        ttsVoicesForLocale
            .first { $0.quality == .premium }?.identifier
            ?? ttsVoicesForLocale.first { $0.quality == .enhanced }?.identifier
            ?? ttsVoicesForLocale.first?.identifier
    }
}

/// Abstractable so the engine + UI + tests can inject deterministic data.
public protocol DeviceSpeechCapabilitiesProtocol: Sendable {
    func report(commandLocale: String) async -> DeviceSpeechReport
}

/// Real implementation: queries Apple's `Speech` and `AVFAudio` frameworks.
public struct LiveDeviceSpeechCapabilities: DeviceSpeechCapabilitiesProtocol {
    public init() {}

    public func report(commandLocale: String) async -> DeviceSpeechReport {
        let supported = SpeechTranscriber.isAvailable
        let locale = Locale(identifier: commandLocale)
        let supportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) != nil
        let assetsInstalled: Bool
        if supportedLocale {
            let probe = SpeechTranscriber(locale: locale, preset: .transcription)
            let status = await AssetInventory.status(forModules: [probe])
            assetsInstalled = (status == .installed)
        } else {
            assetsInstalled = false
        }
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == commandLocale || $0.language.hasPrefix(String(commandLocale.prefix(2))) }
            .map { v in
                let tier: VoiceQualityTier
                switch v.quality {
                case .premium: tier = .premium
                case .enhanced: tier = .enhanced
                default: tier = .compact
                }
                return DeviceSpeechReport.VoiceSummary(
                    identifier: v.identifier,
                    name: v.name,
                    language: v.language,
                    quality: tier
                )
            }
        let highest = voices.map(\.quality).max()
        return DeviceSpeechReport(
            commandLocale: commandLocale,
            speechRecognitionSupported: supported && supportedLocale,
            speechAssetsInstalled: assetsInstalled,
            ttsVoicesForLocale: voices,
            highestAvailableTTSQuality: highest
        )
    }
}
