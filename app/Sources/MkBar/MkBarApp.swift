import AppKit
import MkBarCore
import SwiftUI

@main
struct MkBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: ReportStore

    init() {
        _store = State(initialValue: ReportStore.shared)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // LSUIElement in Info.plist already hides the Dock icon; this keeps a
        // bare `swift run` from showing one either.
        NSApplication.shared.setActivationPolicy(.accessory)
        ReportStore.shared.startPolling()
    }
}

private struct MenuBarLabel: View {
    let store: ReportStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName)
                .accessibilityHidden(true)
            if let freeDiskText {
                Text(freeDiskText).monospacedDigit()
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
