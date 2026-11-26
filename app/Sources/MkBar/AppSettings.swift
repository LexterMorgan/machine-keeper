import Foundation
import Observation
import ServiceManagement

enum RefreshInterval: String, CaseIterable, Identifiable, Sendable {
    case sixty
    case fiveMinutes
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sixty:
            return "Every 60 seconds"
        case .fiveMinutes:
            return "Every 5 minutes"
        case .manual:
            return "Manual only"
        }
    }

    /// The automatic polling period, or `nil` when only manual refreshes run.
    var seconds: TimeInterval? {
        switch self {
        case .sixty:
            return 60
        case .fiveMinutes:
            return 300
        case .manual:
            return nil
        }
    }
}

enum MenuBarLabelStyle: String, CaseIterable, Identifiable, Sendable {
    case icon
    case iconAndFreeSpace

    var id: String { rawValue }

    var label: String {
        switch self {
        case .icon:
            return "Icon only"
        case .iconAndFreeSpace:
            return "Icon and free space"
        }
    }
}

/// User preferences, backed by `UserDefaults` and written as soon as a value
/// changes. The menu-bar app is a face; these settings only change how it
/// presents `mk`'s output, never what gets cleaned.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let refreshInterval = "mk.settings.refreshInterval"
        static let pauseRefresh = "mk.settings.pauseRefresh"
        static let menuBarStyle = "mk.settings.menuBarStyle"
        static let notificationsEnabled = "mk.settings.notificationsEnabled"
        static let lowDiskThresholdGB = "mk.settings.lowDiskThresholdGB"
        static let notifyCriticalPressure = "mk.settings.notifyCriticalPressure"
    }

    private let defaults: UserDefaults

    // Property observers also run while the initializer assigns the values
    // below (all stored properties have defaults). Nothing should be written
    // back, and no login item should be touched, until init has finished.
    @ObservationIgnored private var isReady = false
    @ObservationIgnored private var isUpdatingLaunchAtLogin = false

    var refreshInterval: RefreshInterval = .sixty {
        didSet {
            guard isReady, refreshInterval != oldValue else { return }
            defaults.set(refreshInterval.rawValue, forKey: Key.refreshInterval)
        }
    }

    var pauseRefresh: Bool = false {
        didSet {
            guard isReady, pauseRefresh != oldValue else { return }
            defaults.set(pauseRefresh, forKey: Key.pauseRefresh)
        }
    }

    var menuBarStyle: MenuBarLabelStyle = .icon {
        didSet {
            guard isReady, menuBarStyle != oldValue else { return }
            defaults.set(menuBarStyle.rawValue, forKey: Key.menuBarStyle)
        }
    }

    var notificationsEnabled: Bool = false {
        didSet {
            guard isReady, notificationsEnabled != oldValue else { return }
            defaults.set(notificationsEnabled, forKey: Key.notificationsEnabled)
        }
    }

    var lowDiskThresholdGB: Int = 10 {
        didSet {
            let clamped = min(max(lowDiskThresholdGB, 5), 100)
            if clamped != lowDiskThresholdGB {
                lowDiskThresholdGB = clamped
                return
            }
            guard isReady, lowDiskThresholdGB != oldValue else { return }
            defaults.set(lowDiskThresholdGB, forKey: Key.lowDiskThresholdGB)
        }
    }

    var notifyCriticalPressure: Bool = true {
        didSet {
            guard isReady, notifyCriticalPressure != oldValue else { return }
            defaults.set(notifyCriticalPressure, forKey: Key.notifyCriticalPressure)
        }
    }

    /// Reflects the real login-item registration. Reading it does not register
    /// anything; only setting it to a new value does, from an explicit user
    /// action in Settings.
    var launchAtLogin: Bool = false {
        didSet {
            guard isReady,
                  !isUpdatingLaunchAtLogin,
                  launchAtLogin != oldValue else { return }
            updateLaunchAtLogin(from: oldValue)
        }
    }

    private(set) var launchAtLoginError: String?

    private init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults

        refreshInterval = defaults.string(forKey: Key.refreshInterval)
            .flatMap(RefreshInterval.init(rawValue:)) ?? .sixty
        pauseRefresh = defaults.bool(forKey: Key.pauseRefresh)
        menuBarStyle = defaults.string(forKey: Key.menuBarStyle)
            .flatMap(MenuBarLabelStyle.init(rawValue:)) ?? .icon
        notificationsEnabled = defaults.bool(forKey: Key.notificationsEnabled)
        notifyCriticalPressure = defaults.object(forKey: Key.notifyCriticalPressure) as? Bool ?? true

        let storedThreshold = defaults.object(forKey: Key.lowDiskThresholdGB) as? Int ?? 10
        lowDiskThresholdGB = min(max(storedThreshold, 5), 100)

        launchAtLogin = SMAppService.mainApp.status == .enabled
        isReady = true
    }

    private func updateLaunchAtLogin(from previous: Bool) {
        isUpdatingLaunchAtLogin = true
        defer { isUpdatingLaunchAtLogin = false }

        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = "Could not update the login item. \(error.localizedDescription)"
            // Revert without re-entering the observer, which would try the
            // same system call again.
            launchAtLogin = previous
        }
    }
}
