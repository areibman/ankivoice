import Foundation
import Speech

/// What this device can do for hands-free study, checked against the same
/// `SFSpeechRecognizer` the session engine uses.
///
/// Speech recognition assets are separate from TTS voices:
/// - **Speech assets** arrive when the user turns on Dictation for the
///   language (Settings → General → Keyboard → Dictation). AnkiVoice
///   requires on-device recognition, so without them voice mode is off.
/// - **TTS voices** are installed via Settings → Accessibility → Read &
///   Speak → Voices (Spoken Content before iOS 26); see `VoiceInventory`.
public struct DeviceSpeechReport: Sendable, Equatable {
    public var commandLocale: String
    /// iOS offers speech recognition for the locale at all.
    public var speechRecognitionSupported: Bool
    /// The on-device model for the locale is installed and usable right now.
    public var speechAssetsInstalled: Bool
}

public enum DeviceSpeechCapabilities {
    @MainActor
    public static func report(commandLocale: String) -> DeviceSpeechReport {
        let locale = SpeechVoiceEngine.supportedCommandLocale(commandLocale)
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            return DeviceSpeechReport(commandLocale: locale, speechRecognitionSupported: false, speechAssetsInstalled: false)
        }
        return DeviceSpeechReport(
            commandLocale: locale,
            speechRecognitionSupported: true,
            speechAssetsInstalled: recognizer.isAvailable && recognizer.supportsOnDeviceRecognition
        )
    }
}
