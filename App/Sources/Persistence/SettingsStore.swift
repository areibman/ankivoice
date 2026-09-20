import Foundation
import Observation

/// Global (non-deck) application settings, persisted in UserDefaults.
///
/// Every property is computed over `UserDefaults`, which the `@Observable`
/// macro cannot instrument on its own (it only tracks stored properties).
/// Each accessor therefore goes through `read`/`write`, which register the
/// access and mutation with the observation registrar by hand. Without that,
/// SwiftUI never re-renders after a setting changes: the voice picker's
/// checkmark stays put, the Settings summary keeps showing the old voice and
/// steppers appear to ignore taps — even though the value was saved.
@MainActor
@Observable
public final class SettingsStore {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public static var defaults: SettingsStore {
        SettingsStore(defaults: .standard)
    }

    // MARK: Observation plumbing

    /// Registers an observed read of `keyPath`, then returns the value.
    private func read<T>(_ keyPath: KeyPath<SettingsStore, T>, _ value: () -> T) -> T {
        access(keyPath: keyPath)
        return value()
    }

    /// Performs `body` inside a tracked mutation of `keyPath`, so every view
    /// that read the property re-renders.
    private func write<T>(_ keyPath: KeyPath<SettingsStore, T>, _ body: () -> Void) {
        withMutation(keyPath: keyPath, body)
    }

    // MARK: Keys

    private enum Key {
        static let onboardingComplete = "onboardingComplete"
        static let endpointProfile = "endpointProfile"
        static let answerTimeoutSeconds = "answerTimeoutSeconds"
        static let requireSpokenAnswer = "requireSpokenAnswer"
        static let allowRevealCommand = "allowRevealCommand"
        static let announceRatingConfirmation = "announceRatingConfirmation"
        static let announceNextInterval = "announceNextInterval"
        static let autoStartNextCard = "autoStartNextCard"
        static let pauseWhenHeadphonesDisconnect = "pauseWhenHeadphonesDisconnect"
        static let simplifiedRatings = "simplifiedRatings"
        static let commandLocale = "commandLocale"
        static let sampleContentSeeded = "sampleContentSeeded"
        static let speechRate = "speechRate"
        static let defaultVoices = "defaultVoices"
        static let ankiConnectHost = "ankiConnectHost"
        static let ankiConnectPort = "ankiConnectPort"
        static let ankiConnectKey = "ankiConnectKey"
        static let fsrsParameters = "fsrsParameters"
    }

    // MARK: Properties

    public var onboardingComplete: Bool {
        get { read(\.onboardingComplete) { defaults.bool(forKey: Key.onboardingComplete) } }
        set { write(\.onboardingComplete) { defaults.set(newValue, forKey: Key.onboardingComplete) } }
    }

    /// Whether the Tutorial and Starter decks have been created once. Set
    /// after the first seed so deleting them doesn't bring them back.
    public var sampleContentSeeded: Bool {
        get { read(\.sampleContentSeeded) { defaults.bool(forKey: Key.sampleContentSeeded) } }
        set { write(\.sampleContentSeeded) { defaults.set(newValue, forKey: Key.sampleContentSeeded) } }
    }

    /// Endpoint silence profile (PRD §14): fast ≈ 500 ms, normal ≈ 700 ms, patient ≈ 900 ms.
    public enum EndpointProfile: String, CaseIterable, Sendable, Identifiable {
        case fast
        case normal
        case patient

        public var id: String { rawValue }

        public var silenceMs: Int {
            switch self {
            case .fast: return 500
            case .normal: return 700
            case .patient: return 900
            }
        }

        public var title: String {
            switch self {
            case .fast: return "Fast response"
            case .normal: return "Normal"
            case .patient: return "Patient"
            }
        }
    }

    public var endpointProfile: EndpointProfile {
        get { read(\.endpointProfile) { EndpointProfile(rawValue: defaults.string(forKey: Key.endpointProfile) ?? "") ?? .normal } }
        set { write(\.endpointProfile) { defaults.set(newValue.rawValue, forKey: Key.endpointProfile) } }
    }

    /// Seconds of silence while awaiting an answer before the app offers help (0 = never).
    public var answerTimeoutSeconds: Int {
        get {
            read(\.answerTimeoutSeconds) {
                let v = defaults.integer(forKey: Key.answerTimeoutSeconds)
                return v == 0 ? 60 : v
            }
        }
        set { write(\.answerTimeoutSeconds) { defaults.set(newValue, forKey: Key.answerTimeoutSeconds) } }
    }

    public var requireSpokenAnswer: Bool {
        get { read(\.requireSpokenAnswer) { bool(Key.requireSpokenAnswer, default: true) } }
        set { write(\.requireSpokenAnswer) { defaults.set(newValue, forKey: Key.requireSpokenAnswer) } }
    }

    public var allowRevealCommand: Bool {
        get { read(\.allowRevealCommand) { bool(Key.allowRevealCommand, default: true) } }
        set { write(\.allowRevealCommand) { defaults.set(newValue, forKey: Key.allowRevealCommand) } }
    }

    public var announceRatingConfirmation: Bool {
        get { read(\.announceRatingConfirmation) { defaults.bool(forKey: Key.announceRatingConfirmation) } }
        set { write(\.announceRatingConfirmation) { defaults.set(newValue, forKey: Key.announceRatingConfirmation) } }
    }

    public var announceNextInterval: Bool {
        get { read(\.announceNextInterval) { defaults.bool(forKey: Key.announceNextInterval) } }
        set { write(\.announceNextInterval) { defaults.set(newValue, forKey: Key.announceNextInterval) } }
    }

    public var autoStartNextCard: Bool {
        get { read(\.autoStartNextCard) { bool(Key.autoStartNextCard, default: true) } }
        set { write(\.autoStartNextCard) { defaults.set(newValue, forKey: Key.autoStartNextCard) } }
    }

    public var pauseWhenHeadphonesDisconnect: Bool {
        get { read(\.pauseWhenHeadphonesDisconnect) { bool(Key.pauseWhenHeadphonesDisconnect, default: true) } }
        set { write(\.pauseWhenHeadphonesDisconnect) { defaults.set(newValue, forKey: Key.pauseWhenHeadphonesDisconnect) } }
    }

    /// When enabled, only Again/Good are accepted (Hard/Good/Easy collapse into Good).
    public var simplifiedRatings: Bool {
        get { read(\.simplifiedRatings) { defaults.bool(forKey: Key.simplifiedRatings) } }
        set { write(\.simplifiedRatings) { defaults.set(newValue, forKey: Key.simplifiedRatings) } }
    }

    /// Locale used for recognizing spoken commands/ratings.
    public var commandLocale: String {
        get { read(\.commandLocale) { defaults.string(forKey: Key.commandLocale) ?? "en-US" } }
        set { write(\.commandLocale) { defaults.set(newValue, forKey: Key.commandLocale) } }
    }

    /// Global speaking-speed multiplier (1.0 = the system default rate).
    /// Decks use this unless they set their own rate.
    public var speechRate: Double {
        get {
            read(\.speechRate) {
                let stored = defaults.double(forKey: Key.speechRate)
                return stored == 0 ? 1.0 : min(max(stored, 0.5), 2.0)
            }
        }
        set { write(\.speechRate) { defaults.set(min(max(newValue, 0.5), 2.0), forKey: Key.speechRate) } }
    }

    /// The user's chosen default voice identifier per language.
    ///
    /// Keys are lowercase BCP-47 language codes (`"en"`, `"ja"`), so one
    /// choice covers every regional variant of that language. Decks that
    /// don't pick an explicit voice fall back to these.
    public var defaultVoices: [String: String] {
        get { read(\.defaultVoices) { defaults.dictionary(forKey: Key.defaultVoices) as? [String: String] ?? [:] } }
        set { write(\.defaultVoices) { defaults.set(newValue, forKey: Key.defaultVoices) } }
    }

    /// Returns the default voice identifier for a BCP-47 locale, if the user
    /// picked one for that language.
    public func defaultVoice(forLocale locale: String) -> String? {
        defaultVoices[Self.languageKey(for: locale)]
    }

    /// The voice this side should use when the user hasn't pinned one.
    ///
    /// A pick for this language wins. Otherwise a Supertonic speaker already
    /// chosen for any language carries over: those ten voices are the same
    /// person in every language, so changing the front from English to
    /// Japanese must not hop to a different Apple voice.
    public func effectiveDefaultVoice(forLocale locale: String) -> String? {
        if let chosen = defaultVoice(forLocale: locale) { return chosen }
        let key = Self.languageKey(for: locale)
        guard SupertonicVoiceCatalog.supports(languageKey: key) else { return nil }
        return defaultVoices.values
            .filter(SupertonicVoiceCatalog.isSupertonic)
            .sorted()
            .first
    }

    /// Records (or clears, when `identifier` is nil) the default voice for
    /// the language of `locale`.
    public func setDefaultVoice(_ identifier: String?, forLocale locale: String) {
        var voices = defaultVoices
        let key = Self.languageKey(for: locale)
        if let identifier {
            voices[key] = identifier
        } else {
            voices.removeValue(forKey: key)
        }
        defaultVoices = voices
    }

    /// Lowercase language component of a BCP-47 tag: "en-US" → "en".
    public nonisolated static func languageKey(for locale: String) -> String {
        let normalized = locale.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map { String($0).lowercased() } ?? normalized.lowercased()
    }

    // MARK: AnkiConnect

    /// Host name or IP of the computer running Anki desktop with AnkiConnect.
    public var ankiConnectHost: String {
        get { read(\.ankiConnectHost) { defaults.string(forKey: Key.ankiConnectHost) ?? "" } }
        set { write(\.ankiConnectHost) { defaults.set(newValue, forKey: Key.ankiConnectHost) } }
    }

    /// AnkiConnect port (8765 by default).
    public var ankiConnectPort: Int {
        get {
            read(\.ankiConnectPort) {
                let stored = defaults.integer(forKey: Key.ankiConnectPort)
                return stored == 0 ? 8765 : stored
            }
        }
        set { write(\.ankiConnectPort) { defaults.set(newValue, forKey: Key.ankiConnectPort) } }
    }

    /// Optional AnkiConnect API key (set in the add-on's config).
    public var ankiConnectKey: String {
        get { read(\.ankiConnectKey) { defaults.string(forKey: Key.ankiConnectKey) ?? "" } }
        set { write(\.ankiConnectKey) { defaults.set(newValue, forKey: Key.ankiConnectKey) } }
    }

    /// Collection-wide FSRS-6 weights from Optimize. Deck settings override this.
    public var fsrsParameters: [Double]? {
        get {
            read(\.fsrsParameters) {
                guard let data = defaults.data(forKey: Key.fsrsParameters) else { return nil }
                let values = try? JSONDecoder().decode([Double].self, from: data)
                return values?.count == 21 ? values : nil
            }
        }
        set {
            write(\.fsrsParameters) {
                if let newValue, newValue.count == 21, let data = try? JSONEncoder().encode(newValue) {
                    defaults.set(data, forKey: Key.fsrsParameters)
                } else {
                    defaults.removeObject(forKey: Key.fsrsParameters)
                }
            }
        }
    }

    // MARK: Helpers

    /// `UserDefaults.bool(forKey:)` with a real default for unset keys.
    private func bool(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }
}
