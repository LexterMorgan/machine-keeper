import Foundation
import MkBarCore
import Observation
@preconcurrency import UserNotifications

/// Posts the two alerts the app can honestly produce from a report: critical
/// memory pressure and low free disk space. Authorization is only requested
/// from Settings after the user asks for notifications; startup merely reads
/// the current status.
@MainActor
@Observable
final class NotificationManager {
    static let shared = NotificationManager()

    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?

    private static let cooldown: TimeInterval = 6 * 60 * 60
    private static let bytesPerGB: Int64 = 1024 * 1024 * 1024

    @ObservationIgnored private var previousPressureLevel: Int?
    @ObservationIgnored private var previousFreeBytes: Int64?
    @ObservationIgnored private var lastPressureNotification: Date?
    @ObservationIgnored private var lastLowDiskNotification: Date?

    /// `UNUserNotificationCenter.current()` raises an Objective-C exception
    /// when the process has no app bundle (for example `swift run`).
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    private init() {}

    func refreshAuthorization() async {
        guard let center else {
            authorizationStatus = .notDetermined
            return
        }

        // Use the async API: the completion-handler form is called on a
        // UserNotifications queue and would trip MainActor's executor check
        // when this method is isolated to the main actor.
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Requests permission. Only Settings calls this, and only after the user
    /// switches notifications on.
    func requestAuthorization() async -> Bool {
        guard let center else {
            lastError = "Notifications need the Machine Keeper app bundle; this build is not running from one."
            return false
        }

        lastError = nil

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            await refreshAuthorization()
            return granted
        } catch {
            lastError = "Could not request notification permission. \(error.localizedDescription)"
            await refreshAuthorization()
            return false
        }
    }

    /// Called after every successful report. State is tracked even while
    /// notifications are off so a toggle change cannot turn one poll into an
    /// alert; only true crossings schedule anything.
    func evaluate(report: Report, settings: AppSettings) {
        let now = Date()

        let pressureLevel = report.memory?.pressureLevel
        let previousPressure = previousPressureLevel
        previousPressureLevel = pressureLevel

        let thresholdBytes = Int64(settings.lowDiskThresholdGB) * Self.bytesPerGB
        let freeBytes = report.disk?.freeBytes
        let wasBelowThreshold = previousFreeBytes.map { $0 < thresholdBytes }
        let isBelowThreshold = freeBytes.map { $0 < thresholdBytes }
        previousFreeBytes = freeBytes

        guard settings.notificationsEnabled, isAuthorized else { return }

        if settings.notifyCriticalPressure,
           let pressureLevel,
           pressureLevel == 4,
           previousPressure != 4,
           canNotify(since: lastPressureNotification, now: now),
           let memory = report.memory {
            lastPressureNotification = now
            schedule(
                title: "Memory pressure is critical",
                body: "macOS reports critical memory pressure. Swap in use: "
                    + "\(ByteFormat.string(memory.swap.usedBytes)) of "
                    + "\(ByteFormat.string(memory.swap.totalBytes)).",
                identifier: "mk.notify.pressure"
            )
        }

        if isBelowThreshold == true,
           wasBelowThreshold != true,
           canNotify(since: lastLowDiskNotification, now: now),
           let freeBytes {
            lastLowDiskNotification = now
            schedule(
                title: "Low disk space",
                body: "\(ByteFormat.string(freeBytes)) free — below your "
                    + "\(settings.lowDiskThresholdGB) GB warning threshold.",
                identifier: "mk.notify.low-disk"
            )
        }
    }

    private func canNotify(since last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= Self.cooldown
    }

    private func schedule(title: String, body: String, identifier: String) {
        guard let center else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
                lastError = nil
            } catch {
                // A failed delivery is worth showing in Settings, but it must
                // never take down a poll.
                lastError = "Could not deliver a notification. \(error.localizedDescription)"
            }
        }
    }
}
