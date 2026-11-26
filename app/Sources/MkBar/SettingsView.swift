import AppKit
import SwiftUI

/// The Settings scene. It presents preferences only: every clean and every
/// rule still goes through `ReportStore` and `mk`.
struct SettingsView: View {
    @State private var settings = AppSettings.shared
    @State private var notifications = NotificationManager.shared
    @State private var notificationMessage: String?
    @State private var isRequestingNotifications = false

    var body: some View {
        Form {
            refreshSection
            menuBarSection
            loginSection
            notificationsSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .frame(minHeight: 620)
        .onAppear {
            // LSUIElement apps have no Dock icon to click, so bring the
            // Settings window forward explicitly when it opens.
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        .task {
            await notifications.refreshAuthorization()
            // A stored "enabled" value without permission is a lie. Reconcile
            // it once on open; the user can turn the toggle on again to ask.
            if settings.notificationsEnabled, !notifications.isAuthorized {
                settings.notificationsEnabled = false
                notificationMessage = notifications.authorizationStatus == .denied
                    ? "macOS blocked notifications. Enable Machine Keeper in System Settings › Notifications."
                    : "Enable notifications again to ask macOS for permission."
            }
        }
        .onChange(of: settings.refreshInterval) { _, _ in
            ReportStore.shared.restartPolling()
        }
        .onChange(of: settings.pauseRefresh) { _, _ in
            ReportStore.shared.restartPolling()
        }
    }

    // MARK: - Refresh

    private var refreshSection: some View {
        Section("Refresh") {
            Picker("Update every", selection: $settings.refreshInterval) {
                ForEach(RefreshInterval.allCases) { interval in
                    Text(interval.label).tag(interval)
                }
            }

            Toggle("Pause automatic refresh", isOn: $settings.pauseRefresh)

            Text("Manual only refreshes when you open the panel or press Refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Menu bar

    private var menuBarSection: some View {
        Section("Menu bar") {
            Picker("Label", selection: $settings.menuBarStyle) {
                ForEach(MenuBarLabelStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }

            if settings.menuBarStyle == .iconAndFreeSpace {
                Text("macOS may hide a wide menu-bar item when space is tight, for example on a notched Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Login

    private var loginSection: some View {
        Section("Login") {
            Toggle("Launch at login", isOn: $settings.launchAtLogin)

            if let error = settings.launchAtLoginError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("macOS may ask you to approve Machine Keeper in Login Items.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle("Enable notifications", isOn: notificationsEnabledBinding)
                .disabled(isRequestingNotifications)

            Toggle("Notify when memory pressure is critical", isOn: $settings.notifyCriticalPressure)
                .disabled(!notificationsActive)

            Stepper(value: $settings.lowDiskThresholdGB, in: 5...100, step: 5) {
                Text("Warn below \(settings.lowDiskThresholdGB) GB free")
                    .monospacedDigit()
            }
            .disabled(!notificationsActive)

            notificationStatus
        }
    }

    private var notificationsActive: Bool {
        settings.notificationsEnabled && !isRequestingNotifications
    }

    private var notificationsEnabledBinding: Binding<Bool> {
        Binding(
            get: { settings.notificationsEnabled },
            set: { enabled in
                Task { @MainActor in
                    await setNotificationsEnabled(enabled)
                }
            }
        )
    }

    private func setNotificationsEnabled(_ enabled: Bool) async {
        guard !isRequestingNotifications else { return }

        guard enabled else {
            settings.notificationsEnabled = false
            notificationMessage = nil
            return
        }

        // Turn the toggle on immediately; it is reverted below if macOS says
        // no. This is the only place the app ever requests permission.
        settings.notificationsEnabled = true
        notificationMessage = nil

        guard !notifications.isAuthorized else { return }

        isRequestingNotifications = true
        defer { isRequestingNotifications = false }

        let granted = await notifications.requestAuthorization()
        guard !granted else { return }

        settings.notificationsEnabled = false
        if notifications.authorizationStatus == .denied {
            notificationMessage = "macOS blocked notifications. Enable Machine Keeper in "
                + "System Settings › Notifications."
        } else {
            notificationMessage = "Notifications were not enabled."
        }
    }

    @ViewBuilder
    private var notificationStatus: some View {
        if isRequestingNotifications {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Waiting for macOS permission…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text(notificationStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let message = notificationMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let error = notifications.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notificationStatusText: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional:
            return "Notifications are allowed."
        case .denied:
            return "Notifications are turned off in System Settings."
        case .notDetermined:
            return "macOS has not been asked for notification permission yet."
        @unknown default:
            return "Notification permission status is unknown."
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: version)

            Text("Machine Keeper includes mk and needs Node.js 20+. Set MK_NODE if Node is elsewhere; MK_BIN overrides with an external mk.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var version: String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !value.isEmpty else {
            return "dev"
        }
        return value
    }
}
