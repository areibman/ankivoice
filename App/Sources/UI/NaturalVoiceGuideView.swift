import SwiftUI

/// Step-by-step guide to installing a natural-sounding voice.
///
/// The single most common complaint about the app is "the voice sounds
/// robotic". iOS ships only the compact voice for each language; the
/// natural Enhanced/Premium voices are a free download buried in
/// Accessibility settings — and the Siri voices people usually download
/// first are off-limits to third-party apps. This sheet says exactly that,
/// walks through the download, and confirms live when the voice arrives.
struct NaturalVoiceGuideView: View {
    /// BCP-47 locale the guide is about, e.g. "en-US".
    let locale: String

    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var inventory = VoiceInventory.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statusCard
                    steps
                    siriNote
                }
                .padding()
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Get a natural voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 6) {
                    Button {
                        SystemSettingsLinks.openAppSettings()
                    } label: {
                        Label("Open the Settings app", systemImage: "gear")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text("Opens on AnkiVoice's page — tap **‹ Back** until you see the main Settings list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
            }
        }
    }

    // MARK: Pieces

    private var status: VoiceQualityStatus {
        VoiceQualityStatus(locale: locale, inventory: inventory, settings: services.settings)
    }

    private var languageName: String { VoicePickerView.languageName(languageKey) }
    private var languageKey: String { SettingsStore.languageKey(for: locale) }

    @ViewBuilder
    private var statusCard: some View {
        let status = self.status
        if let better = status.betterInstalled, let current = status.voice {
            // Nothing to download: a natural voice is installed but the
            // user's explicit pick is overriding it.
            card(
                tint: .orange, icon: "arrow.up.circle.fill",
                title: "\(better.name) is installed but not selected",
                body: "\(languageName) cards are read by \(current.name), the voice you picked. \(better.name) (\(better.qualityTitle)) sounds far more natural and is ready to use."
            ) {
                Button {
                    services.settings.setDefaultVoice(nil, forLocale: locale)
                } label: {
                    Label("Use \(better.name)", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("guide.useBetter")
            }
        } else if let voice = status.voice {
            if voice.kind == .supertonic3 {
                card(
                    tint: .green, icon: "checkmark.seal.fill",
                    title: "\(voice.name) is ready",
                    body: "Supertonic 3 will read \(languageName) cards on this iPhone. The model downloads once, then everything stays on device."
                )
            } else {
                switch voice.quality {
                case .premium:
                    card(
                        tint: .green, icon: "checkmark.seal.fill",
                        title: "\(voice.name) is ready",
                        body: "A Premium \(languageName) voice is installed and will read your cards. Nothing else to do."
                    )
                case .enhanced:
                    card(
                        tint: .green, icon: "checkmark.circle.fill",
                        title: "\(voice.name) is ready",
                        body: "An Enhanced \(languageName) voice is installed. A Premium voice sounds even more natural if you'd like to go further."
                    )
                case .compact:
                    card(
                        tint: .orange, icon: "waveform.badge.exclamationmark",
                        title: "Only the built-in voice is installed",
                        body: "\(languageName) cards are currently read by \(voice.name), the basic iOS voice. Natural iOS voices are a free download — follow the steps below. You can also pick a Supertonic 3 voice in Voices."
                    ) {
                        Button {
                            services.settings.setDefaultVoice(
                                SupertonicVoiceCatalog.identifier(for: "F1"),
                                forLocale: locale
                            )
                        } label: {
                            Label("Use Supertonic 3", systemImage: "waveform")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("guide.useSupertonic")
                    }
                }
            }
        } else {
            card(
                tint: .orange, icon: "speaker.slash",
                title: "No \(languageName) voice installed",
                body: "Follow the steps below to download one; the app switches to it automatically."
            )
        }
    }

    private func card<Extra: View>(
        tint: Color, icon: String, title: String, body: String,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(body).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            extra()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.default, value: status)
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("In the Settings app")
                .font(.headline)
            step(1, "From the main Settings list, tap **Accessibility**, then **Read & Speak**.")
            step(2, "Tap **Voices**, then **\(languageName)**.")
            step(3, "Pick a voice marked **Premium** (or **Enhanced**) and tap the download button next to it. Downloads are a few hundred MB, so Wi-Fi is best.")
            step(4, "Come back to AnkiVoice. The new voice appears in the list and, with Automatic selected, is used right away — no restart needed.")
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func step(_ number: Int, _ markdown: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Color.accentColor, in: Circle())
            Text(.init(markdown))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var siriNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text("Siri's voices — including any you downloaded under Settings → Siri, or listed under **Siri** on the Voices screen — are reserved for Siri. Apple doesn't let other apps use them, so they never show up here. Pick from the named voices (Ava, Zoe, Evan…) instead.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
