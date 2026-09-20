import SwiftUI

/// Banner shown in the session screen when the app has fallen back to
/// touch-only mode because speech recognition isn't set up.
struct VoiceSetupBanner: View {
    @Environment(AppServices.self) private var services
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Voice mode unavailable", systemImage: "waveform.badge.exclamationmark")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Speech recognition isn't ready, so this session works by touch. Ratings and reveal are the buttons below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    showDetails = true
                } label: {
                    Label("Fix voice setup", systemImage: "wrench.and.screwdriver")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("session.fixVoice")

                Button {
                    services.retryVoiceSetup()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("session.retryVoice")
            }
        }
        .padding()
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $showDetails) {
            NavigationStack {
                VoiceSetupView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showDetails = false }
                        }
                    }
            }
        }
    }
}
