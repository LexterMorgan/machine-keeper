import AppKit
import MkBarCore
import SwiftUI

@main
struct MkBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ReportStore
    @State private var settings: AppSettings

    init() {
        _store = State(initialValue: ReportStore.shared)
        _settings = State(initialValue: AppSettings.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(store: store)
        } label: {
            MenuBarLabel(store: store, settings: settings)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("All Rules", id: "rules") {
            RulesView(store: store)
        }
        .defaultSize(width: 560, height: 620)
        // The rules window is opened from the panel; it must not launch with
        // the app.
        .defaultLaunchBehavior(.suppressed)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already hides the Dock icon; this keeps a
        // bare `swift run` from showing one either.
        NSApplication.shared.setActivationPolicy(.accessory)

        // Read the current permission without prompting before the first
        // report can be evaluated; requesting it only happens from Settings
        // after an explicit toggle. Starting polling first would race the
        // first low-disk/pressure evaluation against this status.
        Task {
            await NotificationManager.shared.refreshAuthorization()
            ReportStore.shared.startPolling()
        }
    }
}

private struct MenuBarLabel: View {
    let store: ReportStore
    let settings: AppSettings

    var body: some View {
        // Icon-only by default: free-space text can make the status item wide
        // enough to be pushed under the notch. The user can opt into the text
        // in Settings; help and accessibility always speak the number.
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)

            if settings.menuBarStyle == .iconAndFreeSpace, let freeDiskText {
                Text(freeDiskText)
                    .monospacedDigit()
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var symbolName: String {
        if store.errorMessage != nil { return "exclamationmark.triangle" }
        if store.report == nil, store.isLoading { return "hourglass" }
        return "internaldrive"
    }

    private var freeDiskText: String? {
        guard store.errorMessage == nil, let free = store.report?.disk?.freeBytes else { return nil }
        return ByteFormat.string(free)
    }

    private var helpText: String {
        if store.errorMessage != nil {
            return "Machine Keeper — could not read the disk. Open the panel for details."
        }
        if let freeDiskText {
            return "Machine Keeper — \(freeDiskText) free"
        }
        if store.isLoading {
            return "Machine Keeper — reading disk…"
        }
        if store.report != nil {
            return "Machine Keeper — disk space unavailable"
        }
        return "Machine Keeper"
    }

    private var accessibilityText: String {
        if store.errorMessage != nil {
            return "Machine Keeper, error reading disk. Open the panel for details."
        }
        if let freeDiskText {
            let updating = store.isLoading ? ", updating" : ""
            return "Machine Keeper, \(freeDiskText) free\(updating)"
        }
        if store.isLoading {
            return "Machine Keeper, reading disk"
        }
        if store.report != nil {
            return "Machine Keeper, disk space unavailable"
        }
        return "Machine Keeper"
    }
}
