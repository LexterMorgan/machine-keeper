import AppKit
import MkBarCore
import SwiftUI

struct MenuBarPanel: View {
    let store: ReportStore

    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var confirmingClean = false

    var body: some View {
        VStack(alignment: .leading, spacing: PanelLayout.blockSpacing) {
            header

            if let message = store.errorMessage {
                errorBlock(message: message)
            }

            content

            if store.report != nil {
                Divider()
                actions
                statusFeedback
                previewSection
            } else {
                // First launch or a failed first read: keep Quit reachable.
                actions
            }
        }
        .padding(PanelLayout.padding)
        .frame(width: PanelLayout.width)
        .onAppear {
            Task { await store.refreshIfStale() }
        }
        .onDisappear {
            confirmingClean = false
        }
        .onChange(of: store.hasSafeRules) { _, hasSafeRules in
            if !hasSafeRules {
                confirmingClean = false
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("Machine Keeper")
                    .font(.headline)

                Spacer(minLength: 4)

                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }

                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
                .accessibilityLabel("Refresh now")
                .disabled(store.isBusy)
                .keyboardShortcut("r", modifiers: .command)

                headerMenu
            }

            Text(headerStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var headerStatus: String {
        if store.isLoading, store.report != nil {
            return "Updating…"
        }
        return UpdatedLabel.string(for: store.lastUpdated)
    }

    private var headerMenu: some View {
        Menu {
            Button("Refresh Now") {
                Task { await store.refresh() }
            }
            .disabled(store.isBusy)

            Button(store.cleanPreview == nil ? "Preview" : "Hide Preview") {
                Task { await store.previewClean() }
            }
            .disabled(!store.hasSafeRules || store.isBusy)

            Button("Clean Safe Caches…") {
                // The menu only opens the inline confirmation; it never
                // deletes on its own.
                confirmingClean = true
            }
            .disabled(!store.hasSafeRules || store.isBusy)

            Divider()

            Button("All Rules…") {
                openRulesWindow()
            }

            Button("Settings…") {
                openSettingsWindow()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Menu: refresh, preview, clean, all rules, settings, quit")
        .accessibilityLabel("Menu")
    }

    private func openRulesWindow() {
        openWindow(id: "rules")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func openSettingsWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openSettings()
    }

    // MARK: - Error

    private func errorBlock(message: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let hint = store.setupHint, !hint.isEmpty {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if store.report != nil {
                Text("Numbers below are from the last successful reading.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Try Again") {
                Task { await store.refresh() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(store.isBusy)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.10),
            in: RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = store.report, let summary = store.summary {
            ReclaimableHero(summary: summary)
            DiskSection(disk: report.disk)
            MemorySection(memory: report.memory)

            Divider()

            VStack(alignment: .leading, spacing: PanelLayout.tightSpacing) {
                if !summary.reclaimables.isEmpty {
                    RuleList(rows: summary.reclaimables)
                }
                StartupLine(
                    orphanCount: summary.orphanCount,
                    isChecked: report.startup != nil,
                    onShowAllRules: openRulesWindow
                )
            }
        } else if store.errorMessage == nil {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Reading disk and caches…")
                        .font(.subheadline)
                }
                Text("The first read can take a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Actions and confirmation

    @ViewBuilder
    private var actions: some View {
        if confirmingClean {
            confirmation
        } else {
            actionButtons
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            if store.report != nil {
                Button(previewButtonTitle) {
                    Task { await store.previewClean() }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help(previewHelp)
                .disabled(!store.hasSafeRules || store.isBusy)

                Button("Clean safe caches…") {
                    confirmingClean = true
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
                .help("Delete safe caches after a confirmation. Running apps are skipped and opt-in rules are never included.")
                .disabled(!store.hasSafeRules || store.isBusy)
            }

            Spacer(minLength: 0)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .help("Quit Machine Keeper")
            .accessibilityLabel("Quit Machine Keeper")
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(confirmationTitle)
                .font(.subheadline.weight(.semibold))

            Text(confirmationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Cancel") {
                    confirmingClean = false
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.defaultAction)

                Button("Clean", role: .destructive) {
                    confirmingClean = false
                    Task { await store.cleanSafe() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!store.hasSafeRules)

                Spacer(minLength: 0)
            }
            .controlSize(.regular)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
        )
        .accessibilityElement(children: .contain)
    }

    private var previewButtonTitle: String {
        store.cleanPreview == nil ? "Preview clean" : "Hide preview"
    }

    private var previewHelp: String {
        store.cleanPreview == nil
            ? "Dry run: list what Clean safe caches would remove"
            : "Hide the dry-run list"
    }

    private var confirmationTitle: String {
        let count = store.safeRuleCount
        return count == 1 ? "Clean 1 safe rule?" : "Clean \(count) safe rules?"
    }

    private var confirmationMessage: String {
        let bytes = ByteFormat.string(store.summary?.sweepableBytes ?? 0)
        return "Frees about \(bytes). Running apps are skipped, and opt-in rules are never included."
    }

    // MARK: - Feedback

    @ViewBuilder
    private var statusFeedback: some View {
        if store.isCleaning, store.cleanOutcome == nil, store.cleanError == nil {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Cleaning safe caches…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }

        if let cleanError = store.cleanError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text(cleanError)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }

        if let cleanOutcome = store.cleanOutcome {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: store.cleanOutcomeIsSuccess ? "checkmark.circle.fill" : "info.circle")
                    .font(.caption)
                    .foregroundStyle(store.cleanOutcomeIsSuccess ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(cleanOutcome)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = store.cleanOutcomeDetail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .help(detail)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Dry run

    @ViewBuilder
    private var previewSection: some View {
        if store.isPreviewing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Measuring what Clean safe caches would remove…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let previewError = store.previewError {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Preview failed: \(previewError)")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button("Dismiss") {
                    store.dismissPreview()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
        } else if let preview = store.cleanPreview {
            previewBody(preview)
        }
    }

    private func previewBody(_ preview: CleanResult) -> some View {
        let rows = preview.results.filter { !isMissing($0) }
        let bytes = wouldFree(preview)
        let heading = preview.dryRun ? "Dry run — nothing deleted" : "Clean result"
        let totalLabel = preview.dryRun ? "Would free" : "Freed"

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(heading)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if bytes > 0 {
                    Text("\(totalLabel) \(ByteFormat.string(bytes))")
                        .font(.caption.weight(.medium).monospacedDigit())
                }
            }

            if rows.isEmpty {
                Text("Nothing to remove — these caches are already empty.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            PreviewRow(row: row)
                        }
                    }
                }
                // A ScrollView has no intrinsic height. Without an explicit
                // height it collapses and the dry-run rows never appear.
                .frame(height: min(CGFloat(rows.count) * 34, 150))
                .scrollIndicators(.visible)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: PanelLayout.cornerRadius)
        )
    }

    private func isMissing(_ row: CleanRow) -> Bool {
        if let status = row.cleanStatus, case .missing = status { return true }
        return row.status == "missing"
    }

    private func wouldFree(_ preview: CleanResult) -> Int64 {
        preview.results.reduce(0) { total, row in
            if let status = row.cleanStatus {
                switch status {
                case .wouldRemove, .removed:
                    return total + row.bytes
                default:
                    return total
                }
            }
            return row.status == "would-remove" || row.status == "removed"
                ? total + row.bytes
                : total
        }
    }
}

private struct PreviewRow: View {
    let row: CleanRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.id)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(statusLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(ByteFormat.string(row.bytes))
                .font(.caption.monospacedDigit())
        }
        .help(row.error ?? statusLabel)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.title), \(statusLabel), \(ByteFormat.string(row.bytes))")
    }

    private var statusLabel: String {
        row.cleanStatus?.label ?? row.status
    }
}
