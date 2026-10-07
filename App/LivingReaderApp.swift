import SwiftUI
import UIKit

@main
struct LivingReaderApp: App {
    @UIApplicationDelegateAdaptor(LivingReaderAppDelegate.self) private var appDelegate
    @StateObject private var settings = ReaderSettingsStore()
    @StateObject private var modelPrefs = AIModelPreferenceStore()

    init() {
        // UI tests pass -uitesting to cut animation latency and reduce simulator jank.
        if ProcessInfo.processInfo.arguments.contains("-uitesting") || UIAccessibility.isReduceMotionEnabled {
            UIView.setAnimationsEnabled(false)
        }
    }

    var body: some Scene {
        WindowGroup {
            RootShellView()
                .environmentObject(settings)
                .environmentObject(modelPrefs)
                .preferredColorScheme(settings.swiftUIColorScheme)
        }
    }
}
