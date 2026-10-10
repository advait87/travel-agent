import SwiftUI
import SwiftData
import ActivityKit
import CoreLocation
import UserNotifications

@main
struct TravelAgentApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Launching with -resetData starts from scratch (used for clean demo runs): trips, agent feed,
        // scheduled questions, geofences and the Live Activity. API keys and settings are kept.
        if ProcessInfo.processInfo.arguments.contains("-resetData") {
            let store = URL.applicationSupportDirectory.appending(path: "default.store")
            for suffix in ["", "-shm", "-wal"] {
                try? FileManager.default.removeItem(at: URL(filePath: store.path(percentEncoded: false) + suffix))
            }
            let center = UNUserNotificationCenter.current()
            center.removeAllPendingNotificationRequests()
            center.removeAllDeliveredNotifications()
            let locationManager = CLLocationManager()
            locationManager.monitoredRegions.forEach(locationManager.stopMonitoring(for:))
            UserDefaults.standard.removeObject(forKey: "geofenceNames")
            Task {
                for activity in ActivityKit.Activity<TripActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        DemoData.insertIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .tint(Theme.accent)
                .onAppear {
                    // Unit tests run inside the app; keep the real agent loop out of their way.
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                        ProactiveAgent.shared.start()
                    }
                }
                // travelagent://tell (from the widget) opens straight into "tell your agent".
                .onOpenURL { url in
                    if url.host() == "tell" { AppRouter.shared.composeRequested = true }
                }
        }
        .modelContainer(SharedModel.container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { ProactiveAgent.scheduleBackgroundCheckIn() }
        }
        .backgroundTask(.appRefresh(ProactiveAgent.backgroundTaskID)) {
            await ProactiveAgent.shared.rearmIfNewDay()
            await ProactiveAgent.shared.handle(nil, source: .background)
        }
    }
}

@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var composeRequested = false
}
