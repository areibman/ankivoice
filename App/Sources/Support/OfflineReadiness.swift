import Foundation
import Speech
import AVFAudio

/// Checks whether a deck's study sessions can run fully offline (PRD §18):
/// recognition assets installed for the command locale, TTS voices present
/// for the deck's question/answer locales.
public enum OfflineReadiness {

    public struct Check: Identifiable, Sendable, Equatable {
        public var id: String { label }
        public let label: String
        public let passed: Bool
    }

    public struct Result: Sendable, Equatable {
        public let checks: [Check]
        public var isReady: Bool { checks.allSatisfy(\.passed) }
    }

    public static func check(voiceConfig: VoiceConfig, commandLocale: String = "en-US") async -> Result {
        var checks: [Check] = []

        // Recognition assets: is the locale installed on-device?
        let target = Locale(identifier: commandLocale)
        let installed = await SpeechTranscriber.installedLocales
        let recognitionInstalled = installed.contains {
            $0.language.languageCode == target.language.languageCode
        } || installed.contains(target)
        checks.append(
            Check(
                label: "Speech recognition (\(commandLocale))",
                passed: recognitionInstalled
            )
        )

        // TTS voices for both sides of the card.
        let available = AVSpeechSynthesisVoice.speechVoices()
        func hasVoice(for locale: String) -> Bool {
            let languageCode = String(locale.prefix(2))
            return available.contains { $0.language.hasPrefix(languageCode) }
        }
        checks.append(Check(label: "Question voice (\(voiceConfig.questionLocale))", passed: hasVoice(for: voiceConfig.questionLocale)))
        checks.append(Check(label: "Answer voice (\(voiceConfig.answerLocale))", passed: hasVoice(for: voiceConfig.answerLocale)))

        return Result(checks: checks)
    }
}
