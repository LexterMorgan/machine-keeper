import AppKit
import MkBarCore
import SwiftUI

/// The "All Rules" window. It shows the complete report grouped by what the
/// user can do with each rule: clean it now, quit the owning app first, or
/// opt in explicitly. Every value comes from `ReportStore.report` or the clean
/// result; ids and paths are only forwarded, never constructed.
struct RulesView: View {
    let store: ReportStore

    @Environment(\.dismissWindow) private var dismissWindow
    @State private var pendingOptIn: RuleRow?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            notices
            Divider()
            ScrollView {
                content
                    .padding(.horizontal, RulesLayout.padding)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
        }
        .frame(width: RulesLayout.width)
        .frame(minHeight: 420, idealHeight: 620)
        .onAppear {
            Task { await store.refreshIfStale() }
        }
        .onChange(of: store.isCleaning) { _, isCleaning in
            if isCleaning {
                pendingOptIn = nil
            }
        }
        .alert(
            alertTitle,
            isPresented: optInAlertPresented,
            presenting: pendingOptIn
        ) { row in
            // Cancel is the default action: a stray Return must not delete.
            Button("Cancel", role: .cancel) {
                pendingOptIn = nil
            }
            .keyboardShortcut(.defaultAction)

            Button("Clean", role: .destructive) {
                pendingOptIn = nil
                let id = row.id
                Task { await store.cleanOptIn(ruleIDs: [id]) }
            }
        } message: { row in
            alertMessage(for: row)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("All Rules")
                    .font(.title3.weight(.semibold))

                HStack(spacing: 6) {
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                    }
                    Text(UpdatedLabel.string(for: store.lastUpdated))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }

            Spacer(minLength: 8)

            Button {
                Task { await store.refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Refresh disk and rule measurements")
            .accessibilityLabel("Refresh rules")
            .disabled(store.isBusy)
            .keyboardShortcut("r", modifiers: .command)

            Button("Close") {
                dismissWindow(id: "rules")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("Close this window")
            .accessibilityLabel("Close All Rules")
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, RulesLayout.padding)
        .padding(.vertical, 12)
    }

    // MARK: - Errors and clean feedback

    @ViewBuilder
    private var notices: some View {
        if hasNotices {
            VStack(alignment: .leading, spacing: 8) {
                if let message = store.errorMessage {
                    notice(
                        icon: "exclamationmark.triangle.fill",
                        tint: .orange,
                        title: message,
                        body: errorDetail
                    )
                } else if let hint = store.setupHint, !hint.isEmpty {
                    notice(
                        icon: "info.circle",
                        tint: .secondary,
                        title: hint,
                        body: nil
                    )
                }

                if store.isCleaning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityHidden(true)
                        Text(store.cleanOutcome == nil && store.cleanError == nil
                            ? "Cleaning…"
                            : "Cleaning again…")
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let cleanError = store.cleanError {
                    notice(
                        icon: "exclamationmark.octagon.fill",
                        tint: .red,
                        title: cleanError,
                        body: nil
                    )
                }

                if let cleanOutcome = store.cleanOutcome {
                    notice(
                        icon: store.cleanOutcomeIsSuccess
                            ? "checkmark.circle.fill"
                            : "info.circle",
                        tint: store.cleanOutcomeIsSuccess ? .green : .secondary,
                        title: cleanOutcome,
                        body: store.cleanOutcomeDetail
                    )
                }
            }
            .padding(.horizontal, RulesLayout.padding)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
    }

    private var hasNotices: Bool {
        store.errorMessage != nil
            || (store.setupHint?.isEmpty == false)
            || store.isCleaning
            || store.cleanError != nil
            || store.cleanOutcome != nil
    }

    private var errorDetail: String? {
        let stale = store.report == nil
            ? nil
            : "Numbers below are from the last successful reading."
        guard let hint = store.setupHint, !hint.isEmpty else { return stale }
        guard let stale else { return hint }
        return "\(hint)\n\(stale)"
    }

    private func notice(
        icon: String,
        tint: Color,
        title: String,
        body: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let body, !body.isEmpty {
                    Text(body)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let report = store.report {
            VStack(alignment: .leading, spacing: 22) {
                ruleSections(report)
                startupSection(report.startup)
            }
        } else if store.errorMessage == nil {
            readingState
        } else {
            unavailableState
        }
    }

    @ViewBuilder
    private func ruleSections(_ report: Report) -> some View {
        let safe = report.rows
            .filter { !$0.optIn && !$0.appRunning && $0.bytes > 0 }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes {
                    return lhs.bytes > rhs.bytes
                }
                return lhs.id < rhs.id
            }
        let blocked = report.rows
            .filter { !$0.optIn && $0.appRunning && $0.bytes > 0 }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes {
                    return lhs.bytes > rhs.bytes
                }
                return lhs.id < rhs.id
            }
        let optIn = report.rows
            .filter { $0.optIn && $0.bytes > 0 }
            .sorted { lhs, rhs in
                if lhs.bytes != rhs.bytes {
                    return lhs.bytes > rhs.bytes
                }
                return lhs.id < rhs.id
            }

        if !safe.isEmpty {
            section("Safe", detail: countAndSize(safe)) {
                ForEach(safe) { row in
                    safeRow(row)
                    if row.id != safe.last?.id {
                        Divider()
                    }
                }
            }
        }

        if !blocked.isEmpty {
            section("Blocked", detail: countAndSize(blocked)) {
                ForEach(blocked) { row in
                    blockedRow(row)
                    if row.id != blocked.last?.id {
                        Divider()
                    }
                }
            }
        }

        if !optIn.isEmpty {
            section("Opt-in", detail: countAndSize(optIn)) {
                ForEach(optIn) { row in
                    optInRow(row)
                    if row.id != optIn.last?.id {
                        Divider()
                    }
                }
            }
        }

        if safe.isEmpty, blocked.isEmpty, optIn.isEmpty {
            Text("No rules with a measured footprint right now.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func section<Content: View>(
        _ title: String,
        detail: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.headline)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
        }
    }

    private func safeRow(_ row: RuleRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(row.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(ByteFormat.string(row.bytes))
                .font(.subheadline.monospacedDigit())
                .lineLimit(1)
        }
        .padding(.vertical, 8)
        .help(row.reclaim.isEmpty ? row.title : row.reclaim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.title), \(ByteFormat.string(row.bytes)), safe to clean"
        )
        .accessibilityHint(row.reclaim)
    }

    private func blockedRow(_ row: RuleRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Text(ByteFormat.string(row.bytes))
                    .font(.subheadline.monospacedDigit())
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(quitFirstText(row))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 8)
        .help(row.reclaim.isEmpty ? quitFirstText(row) : row.reclaim)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(row.title), \(ByteFormat.string(row.bytes)), blocked. \(quitFirstText(row))."
        )
        .accessibilityHint(row.reclaim)
    }

    private func optInRow(_ row: RuleRow) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    Text(row.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Risk: \(row.risk)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if !row.reclaim.isEmpty {
                    Text(row.reclaim)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if row.appRunning {
                    Text(quitFirstText(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(optInAccessibilityLabel(row))
            .accessibilityHint(row.reclaim)

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                Text(ByteFormat.string(row.bytes))
                    .font(.subheadline.monospacedDigit())
                    .lineLimit(1)

                Button("Clean…") {
                    pendingOptIn = row
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.isCleaning || row.appRunning)
                .help(optInHelp(row))
                .accessibilityLabel("Clean \(row.title)")
                .accessibilityHint(
                    "Asks for confirmation. \(ByteFormat.string(row.bytes)), risk \(row.risk)."
                )
            }
            .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func startupSection(_ startup: StartupInfo?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Startup")
                    .font(.headline)
                Spacer(minLength: 8)
                if let startup, !startup.orphans.isEmpty {
                    Text(
                        startup.orphans.count == 1
                            ? "1 orphaned"
                            : "\(startup.orphans.count) orphaned"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            if let startup {
                if startup.orphans.isEmpty {
                    Text("No orphaned startup items.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        let items = indexedOrphans(startup.orphans)
                        ForEach(items) { item in
                            orphanRow(item.entry)
                            if item.id != items.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            } else {
                Text("Startup items not checked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help("The report did not include startup items.")
            }
        }
    }

    private func orphanRow(_ entry: StartupEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)

                Text(entry.program ?? "Program path not reported")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !entry.file.isEmpty {
                    Text(entry.file)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(orphanAccessibilityLabel(entry))

            Spacer(minLength: 8)

            Button("Reveal") {
                reveal(entry)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(revealTarget(for: entry) == nil)
            .help(revealHelp(entry))
            .accessibilityLabel("Reveal \(entry.label) in Finder")
        }
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private var readingState: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text("Reading disk and caches…")
                    .font(.subheadline)
            }
            .accessibilityElement(children: .combine)

            Text("The first read can take a few seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Refresh") {
                Task { await store.refresh() }
            }
            .buttonStyle(.bordered)
            .disabled(store.isBusy)
        }
    }

    private var unavailableState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No report yet.")
                .font(.subheadline)
            Text("Refresh to try again.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Refresh") {
                Task { await store.refresh() }
            }
            .buttonStyle(.bordered)
            .disabled(store.isBusy)
        }
    }

    // MARK: - Confirmation

    private var alertTitle: String {
        guard let pendingOptIn else { return "Clean this rule?" }
        return "Clean \(pendingOptIn.title)?"
    }

    private var optInAlertPresented: Binding<Bool> {
        Binding(
            get: { pendingOptIn != nil },
            set: { presented in
                if !presented {
                    pendingOptIn = nil
                }
            }
        )
    }

    private func alertMessage(for row: RuleRow) -> Text {
        // SwiftUI alert messages render a single Text; a VStack silently drops
        // everything after the first line, including the destructive warning.
        var lines = ["\(ByteFormat.string(row.bytes)) · risk \(row.risk)"]
        if !row.reclaim.isEmpty {
            lines.append(row.reclaim)
        }
        lines.append(
            "This removes user-visible data and cannot be undone. "
                + "Running apps are skipped."
        )
        return Text(lines.joined(separator: "\n"))
    }

    // MARK: - Helpers

    private func countAndSize(_ rows: [RuleRow]) -> String {
        let count = rows.count == 1 ? "1 rule" : "\(rows.count) rules"
        let bytes = rows.reduce(Int64(0)) { $0 + $1.bytes }
        return "\(count) · \(ByteFormat.string(bytes))"
    }

    private func quitFirstText(_ row: RuleRow) -> String {
        let app = row.app?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return app.isEmpty ? "Quit the app first" : "Quit \(app) first"
    }

    private func optInAccessibilityLabel(_ row: RuleRow) -> String {
        var parts = [
            row.title,
            ByteFormat.string(row.bytes),
            "risk \(row.risk)",
            "opt-in",
        ]
        if row.appRunning {
            parts.append(quitFirstText(row))
        }
        return parts.joined(separator: ", ")
    }

    private func orphanAccessibilityLabel(_ entry: StartupEntry) -> String {
        var parts = [entry.label, "orphaned startup item"]
        if let program = entry.program, !program.isEmpty {
            parts.append("program \(program)")
        } else {
            parts.append("program path not reported")
        }
        if !entry.file.isEmpty {
            parts.append("file \(entry.file)")
        }
        return parts.joined(separator: ", ")
    }

    private func optInHelp(_ row: RuleRow) -> String {
        if row.appRunning {
            return "\(quitFirstText(row)); this rule is skipped while the app runs."
        }
        if store.isCleaning {
            return "A clean is already running."
        }
        return "Clean this opt-in rule after a confirmation."
    }

    private func indexedOrphans(_ orphans: [StartupEntry]) -> [IndexedOrphan] {
        orphans.enumerated().map { index, entry in
            IndexedOrphan(id: index, entry: entry)
        }
    }

    private func revealTarget(for entry: StartupEntry) -> URL? {
        let path = entry.file.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path.hasPrefix("/") else { return nil }

        let fileURL = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let parent = fileURL.deletingLastPathComponent()
        guard parent.path != fileURL.path,
              FileManager.default.fileExists(atPath: parent.path) else {
            return nil
        }
        return parent
    }

    private func revealHelp(_ entry: StartupEntry) -> String {
        guard let target = revealTarget(for: entry) else {
            return "The startup item's file and folder were not found."
        }
        let fileURL = URL(fileURLWithPath: entry.file)
        return target.path == fileURL.path
            ? "Show the startup item in Finder"
            : "Show the containing folder in Finder"
    }

    private func reveal(_ entry: StartupEntry) {
        guard let target = revealTarget(for: entry) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

private enum RulesLayout {
    static let width: CGFloat = 560
    static let padding: CGFloat = 16
}

private struct IndexedOrphan: Identifiable {
    let id: Int
    let entry: StartupEntry
}
