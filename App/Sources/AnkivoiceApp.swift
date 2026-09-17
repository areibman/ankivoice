import SwiftUI
import UIKit
import AVFAudio

/// Application delegate owning the audio session lifecycle for background study.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Keep the audio session alive across scene transitions; study sessions
        // rely on `playAndRecord` + background audio to continue while locked.
        CrashReporter.shared.start()
        return true
    }
}

@main
struct AnkivoiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appServices = AppServices.live

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appServices)
        }
    }
}
