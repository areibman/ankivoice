import Foundation
import FluidAudio
import Observation
import os

private let log = Logger(subsystem: "local.ankivoice", category: "supertonic")

/// On-device Supertonic 3 (CoreML) — downloaded once, then fully local.
///
/// The picker lists the ten published speakers. Tapping one (or previewing)
/// triggers `prepare()`, which pulls ~400 MB of models from Hugging Face
/// into the shared FluidAudio cache. After that, synthesis stays on device.
@MainActor
@Observable
final class SupertonicTTS {

    static let shared = SupertonicTTS()

    enum Phase: Equatable {
        case idle
        case downloading
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Hugging Face download fraction in `[0, 1]`. Nil when we aren't downloading.
    private(set) var downloadFraction: Double?
    private let backend = Backend()

    var isReady: Bool { phase == .ready }

    /// Loads the CoreML pack if it isn't already in memory. Safe to call
    /// repeatedly; concurrent callers share one download.
    func prepare() async throws {
        if phase == .ready { return }
        phase = .downloading
        downloadFraction = 0
        do {
            try await backend.prepare { fraction in
                Task { @MainActor in
                    SupertonicTTS.shared.downloadFraction = fraction
                }
            }
            downloadFraction = 1
            phase = .ready
        } catch {
            let message = error.localizedDescription
            phase = .failed(message)
            downloadFraction = nil
            log.error("Supertonic 3 prepare failed: \(message, privacy: .public)")
            throw error
        }
    }

    func synthesize(
        text: String,
        locale: String,
        voiceIdentifier: String,
        speed: Double
    ) async throws -> (samples: [Float], sampleRate: Int) {
        guard let preset = SupertonicVoiceCatalog.presetID(from: voiceIdentifier) else {
            throw SupertonicTTSError.unknownVoice(voiceIdentifier)
        }
        try await prepare()
        let language = SupertonicVoiceCatalog.synthesisLanguage(for: locale)
        let clamped = Float(min(max(speed, 0.5), 2.0))
        return try await backend.synthesize(
            text: text,
            language: language,
            preset: preset,
            speed: clamped
        )
    }
}

enum SupertonicTTSError: LocalizedError {
    case unknownVoice(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .unknownVoice(let id):
            return "Unknown Supertonic voice: \(id)"
        case .notReady:
            return "Supertonic 3 isn't ready yet."
        }
    }
}

/// Actor so model load and inference never block the main thread.
private actor Backend {
    private var manager: Supertonic3Manager?
    private var styles: [String: Supertonic3VoiceStyle] = [:]

    func prepare(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if manager != nil { return }
        log.info("Loading Supertonic 3 models")
        try await Supertonic3ResourceDownloader.ensureModels { progress in
            onProgress(progress.fractionCompleted)
        }
        manager = try await Supertonic3Manager.downloadAndCreate()
        log.info("Supertonic 3 models ready")
    }

    func synthesize(
        text: String,
        language: String,
        preset: String,
        speed: Float
    ) async throws -> (samples: [Float], sampleRate: Int) {
        try await prepare { _ in }
        guard let manager else { throw SupertonicTTSError.notReady }
        let style = try await style(named: preset)
        let result = try await manager.synthesize(
            text: text,
            language: language,
            style: style,
            speed: speed
        )
        return (result.samples, Supertonic3Constants.sampleRate)
    }

    private func style(named preset: String) async throws -> Supertonic3VoiceStyle {
        if let cached = styles[preset] { return cached }
        guard let voice = Supertonic3Voice(name: preset) else {
            throw SupertonicTTSError.unknownVoice(preset)
        }
        let loaded = try await Supertonic3ResourceDownloader.loadVoiceStyle(voice)
        styles[preset] = loaded
        return loaded
    }
}
