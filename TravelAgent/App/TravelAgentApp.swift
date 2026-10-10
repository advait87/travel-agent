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
                .onOpenURL { url in AppRouter.shared.open(url) }
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

/// Deep links: travelagent://tell (widget) plus demo remote-control links, e.g.
/// travelagent://say?text=…, /apply, /ignore, /undo, /check, /map, /chat, /close, /scroll?to=feed.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()
    var composeRequested = false
    /// Text to type into the agent box and send (shown being typed, like dictation).
    var say: String?
    var showMap = false
    var showChat = false
    var scrollTarget: String?

    func open(_ url: URL) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        let agent = ProactiveAgent.shared
        let context = SharedModel.container.mainContext
        let proposals = (try? context.fetch(FetchDescriptor<PlanProposal>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]))) ?? []
        switch url.host() {
        case "tell": composeRequested = true
        case "say": say = query?.first { $0.name == "text" }?.value
        case "apply": if let p = proposals.first(where: { $0.state == .pending }) { withAnimation { agent.apply(p) } }
        case "ignore": if let p = proposals.first(where: { $0.state == .pending }) { withAnimation { agent.dismiss(p) } }
        case "undo": if let p = proposals.first(where: { $0.canUndo }) { withAnimation { agent.undo(p) } }
        case "check": Task { await agent.checkNow() }
        case "map": showChat = false; showMap = true
        case "chat": showMap = false; showChat = true
        case "close", "home": showMap = false; showChat = false
        case "scroll": scrollTarget = query?.first { $0.name == "to" }?.value
        default: break
        }
    }
}
