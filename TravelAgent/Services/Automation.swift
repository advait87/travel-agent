import Foundation
import ActivityKit
import CoreLocation
import UIKit
import UserNotifications

/// How the user answered a nudge (notification, Live Activity or geofence).
enum NudgeAnswer {
    case done, stillHere, reply(String), arrived(String), left(String)
}

/// Turns any answer into context for the agent and triggers a check-in.
@MainActor
enum ActivityResponder {
    static func handle(_ answer: NudgeAnswer, blockTitle: String? = nil,
                       source: ProactiveAgent.Source = .notification, agent: ProactiveAgent = .shared) async {
        let block = blockTitle ?? currentBlockTitle() ?? "this stop"
        let text: String
        switch answer {
        case .done: text = "Done with \(block), moving on."
        case .stillHere: text = "Still at \(block), staying longer than planned."
        case .reply(let reply): text = "About \(block): \(reply)"
        case .arrived(let place): text = "Arrived at \(place) (detected by location)."
        case .left(let place): text = "Left \(place) (detected by location)."
        }
        switch answer {
        case .arrived, .left: await agent.handle(text, source: .geofence)
        default: await agent.handle(text, source: source)
        }
    }

    private static func currentBlockTitle() -> String? {
        guard let day = ActiveTrip.current(in: SharedModel.container.mainContext)?.today else { return nil }
        let now = ProactiveAgent.minutesNow()
        let blocks = day.activities.sorted { $0.start < $1.start }
        return (blocks.first { $0.start <= now && now < $0.end } ?? blocks.last { $0.end <= now })?.title
    }
}

// MARK: - A. Scheduled questions

/// Pre-schedules "Done with X?" at the end of each block in the next 48 hours (iOS keeps at most 64
/// pending notifications; the window is topped up every day). Any answer wakes the app in the background.
enum NudgeScheduler {
    static let category = "BLOCK_CHECK"
    static let doneAction = "DONE"
    static let stillAction = "STILL"
    static let replyAction = "REPLY"
    private static let idPrefix = "block-"

    static func registerCategory() {
        let done = UNNotificationAction(identifier: doneAction, title: "✅ Done")
        let still = UNNotificationAction(identifier: stillAction, title: "⏳ Still here")
        let reply = UNTextInputNotificationAction(identifier: replyAction, title: "💬 Reply",
                                                  textInputButtonTitle: "Send",
                                                  textInputPlaceholder: "What are you up to?")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [done, still, reply], intentIdentifiers: []),
        ])
    }

    static func schedule(for trip: Trip) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)

        for day in trip.days {
            let dayStart = Calendar.current.startOfDay(for: trip.startDate).addingTimeInterval(Double(day.dayNumber - 1) * 86_400)
            let blocks = day.activities.sorted { $0.start < $1.start }
            for (index, block) in blocks.enumerated() {
                let fireDate = dayStart.addingTimeInterval(Double(block.end) * 60)
                guard fireDate > .now, fireDate < .now.addingTimeInterval(48 * 3600) else { continue }
                let next = blocks.indices.contains(index + 1) ? blocks[index + 1] : nil
                try? await center.add(request(id: "\(idPrefix)\(block.id)", block: block, next: next,
                                              trigger: UNCalendarNotificationTrigger(
                                                dateMatching: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                                                repeats: false)))
            }
        }
    }

    /// Debug: ask about the current block in a few seconds.
    static func sendTestQuestion(for trip: Trip) async {
        guard let day = trip.today ?? trip.displayDay else { return }
        let now = ProactiveAgent.minutesNow()
        let blocks = day.activities.sorted { $0.start < $1.start }
        guard let index = blocks.firstIndex(where: { $0.end > now }) ?? blocks.indices.last else { return }
        let next = blocks.indices.contains(index + 1) ? blocks[index + 1] : nil
        try? await UNUserNotificationCenter.current().add(
            request(id: "test-\(UUID())", block: blocks[index], next: next,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)))
    }

    private static func request(id: String, block: Activity, next: Activity?, trigger: UNNotificationTrigger) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Done with \(block.title)?"
        content.body = next.map { "Next up: \($0.title) at \(Activity.clock($0.start)). Long-press to answer." }
            ?? "That was the last stop today. Long-press to answer."
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["blockTitle": block.title]
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}

/// Receives notification answers, even when the app was closed (iOS relaunches it in the background).
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NudgeScheduler.registerCategory()
        Task { @MainActor in GeofenceManager.shared.activate() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        // The app is open, so the screen already shows it: no banner (except the debug test question).
        notification.request.identifier.hasPrefix("test-") ? [.banner, .sound, .list] : [.list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let blockTitle = response.notification.request.content.userInfo["blockTitle"] as? String
        let answer: NudgeAnswer?
        switch response.actionIdentifier {
        case NudgeScheduler.doneAction: answer = .done
        case NudgeScheduler.stillAction: answer = .stillHere
        case NudgeScheduler.replyAction: answer = .reply((response as? UNTextInputNotificationResponse)?.userText ?? "")
        default: answer = nil  // plain tap just opens the app
        }
        guard let answer else { return }
        await ActivityResponder.handle(answer, blockTitle: blockTitle)
    }
}

// MARK: - B. Live Activity

@MainActor
enum LiveActivityManager {
    static func endAll() async {
        for activity in ActivityKit.Activity<TripActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    static func update(trip: Trip, headline: String, status: String) async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, let day = trip.today else { return }
        let now = ProactiveAgent.minutesNow()
        let blocks = day.activities.sorted { $0.start < $1.start }
        let dayStart = Calendar.current.startOfDay(for: .now)
        func date(_ minutes: Int) -> Date { dayStart.addingTimeInterval(Double(minutes) * 60) }

        guard let current = blocks.first(where: { $0.end > now }) else {
            for activity in ActivityKit.Activity<TripActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let next = blocks.first { $0.start > current.start }
        let state = TripActivityAttributes.ContentState(
            blockTitle: current.title, location: current.location, blockEnd: date(current.end),
            nextTitle: next?.title, nextStart: next.map { date($0.start) }, headline: headline, status: status)
        let content = ActivityContent(state: state, staleDate: date(current.end).addingTimeInterval(1800))

        if let activity = ActivityKit.Activity<TripActivityAttributes>.activities.first {
            await activity.update(content)
        } else {
            _ = try? ActivityKit.Activity.request(attributes: TripActivityAttributes(destination: trip.destination),
                                      content: content, pushType: nil)
        }
    }
}

// MARK: - C. Location triggers

/// Geofences around each of today's places: arriving or leaving wakes the agent (even if the app is closed).
@MainActor
final class GeofenceManager: NSObject, CLLocationManagerDelegate {
    static let shared = GeofenceManager()
    private let manager = CLLocationManager()
    private var names: [String: String] = [:]

    func activate() {
        manager.delegate = self
        names = UserDefaults.standard.dictionary(forKey: "geofenceNames") as? [String: String] ?? [:]
    }

    func refresh(for trip: Trip) async {
        manager.requestAlwaysAuthorization()
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        names = [:]
        let geocoder = CLGeocoder()
        // iOS allows 20 regions per app; geocode today's places one by one.
        for block in (trip.today?.activities ?? []).prefix(20) where !block.location.isEmpty {
            guard let location = try? await geocoder.geocodeAddressString("\(block.location), \(trip.destination)").first?.location
            else { continue }
            let region = CLCircularRegion(center: location.coordinate, radius: 150, identifier: block.id.uuidString)
            region.notifyOnEntry = true
            region.notifyOnExit = true
            manager.startMonitoring(for: region)
            names[block.id.uuidString] = block.title
        }
        UserDefaults.standard.set(names, forKey: "geofenceNames")
    }

    var monitoredCount: Int { manager.monitoredRegions.count }

    func clear() {
        for region in manager.monitoredRegions { manager.stopMonitoring(for: region) }
        names = [:]
        UserDefaults.standard.removeObject(forKey: "geofenceNames")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        Task { @MainActor in
            await ActivityResponder.handle(.arrived(names[region.identifier] ?? "a planned stop"))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        Task { @MainActor in
            await ActivityResponder.handle(.left(names[region.identifier] ?? "a planned stop"))
        }
    }
}
