import SwiftUI

@main
struct AnkivoiceApp: App {
    @State private var appServices = AppServices.live

    init() {
        // Subscribe to MetricKit before any work that could crash or hang.
        CrashReporter.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appServices)
        }
    }
}
