import SwiftUI

struct RootView: View {
    @Environment(AppServices.self) private var services
    @State private var showOnboarding = (!UserDefaults.standard.bool(forKey: "onboardingComplete")
            || ProcessInfo.processInfo.arguments.contains("-uiTestForceOnboarding"))
        && !ProcessInfo.processInfo.arguments.contains("-uiTestSkipOnboarding")
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DeckListView()
                .tabItem { Label("Decks", systemImage: "square.stack.3d.up") }
                .tag(0)
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                UserDefaults.standard.set(true, forKey: "onboardingComplete")
                showOnboarding = false
            }
        }
    }
}

#Preview {
    RootView()
}
