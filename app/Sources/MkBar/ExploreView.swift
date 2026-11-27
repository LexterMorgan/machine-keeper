import AppKit
import MkBarCore
import SwiftUI

/// The Explore window. It is deliberately separate from the cleanup registry:
/// results never become rules, report rows, or Clean Safe work.
struct ExploreView: View {
    @State private var model = ExploreModel.loadDefault()
    @State private var filename = ""
    @State private var extensionText = ""
    @State private var minimumSizeMB = 0
    @State private var modifiedAfterEnabled = false
    @State private var modifiedAfterDate = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                folderRow
                filters
                notices
                results
                Divider()
                trashControls
            }
            .padding(16)
        }
        .frame(minWidth: 780, idealWidth: 880, minHeight: 560, idealHeight: 700)
        .sheet(isPresented: confirmationBinding) {
            confirmationSheet
        }
        .onChange(of: filename) { _, _ in applyFilters() }
        .onChange(of: extensionText) { _, _ in applyFilters() }
        .onChange(of: minimumSizeMB) { _, _ in applyFilters() }
        .onChange(of: modifiedAfterEnabled) { _, _ in applyFilters() }
        .onChange(of: modifiedAfterDate) { _, _ in applyFilters() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Explore")
                    .font(.title2.weight(.semibold))
                Text(headerDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Button("Cancel") {
                    model.cancelScan()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Stop the current scan")
                .accessibilityLabel("Cancel scan")
            }

            Button {
                chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut("o", modifiers: .command)
            .disabled(!model.isPolicyLoaded || model.isTrashing)
            .help("Choose a folder inside your home folder")
            .accessibilityLabel("Choose folder to explore")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var headerDetail: String {
        if !model.isPolicyLoaded {
            return "Protection policy unavailable. Trash is disabled."
        }
        if let folder = model.selectedFolder {
            if model.isScanning {
                return "Scanning \(folder.path)…"
            }
            let count = model.results.count
            return "\(count) file\(count == 1 ? "" : "s") in \(folder.path)"
        }
        return "Inspect files and move selected ones to Trash. Explore does not add cleanup rules."
    }

    // MARK: - Folder

    private var folderRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            if let folder = model.selectedFolder {
                Text(folder.path)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(folder.path)
                    .accessibilityLabel("Selected folder, \(folder.path)")
            } else {
                Text("No folder chosen")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.selectedFolder != nil {
                Button("Choose Another…") {
                    chooseFolder()
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .disabled(!model.isPolicyLoaded || model.isTrashing)
            }
        }
    }

    private func chooseFolder() {
        guard model.isPolicyLoaded else { return }

        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Explore"
        panel.message = "Choose a folder inside your home folder. "
            + "Protected folders can be inspected, but files there cannot be moved to Trash."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = model.home
        panel.showsHiddenFiles = false
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.selectFolder(url)
    }

    // MARK: - Filters

    private var filters: some View {
        GroupBox {
            HStack(alignment: .bottom, spacing: 10) {
                filterField("Name contains") {
                    TextField("report", text: $filename)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyFilters(immediately: true) }
                        .accessibilityLabel("Filename contains")
                        .frame(minWidth: 150)
                }

                filterField("Extension") {
                    TextField("txt", text: $extensionText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyFilters(immediately: true) }
                        .accessibilityLabel("File extension")
                        .frame(width: 80)
                }

                filterField("Minimum size (MB)") {
                    TextField("0", value: $minimumSizeMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { applyFilters(immediately: true) }
                        .accessibilityLabel("Minimum size in megabytes")
                        .frame(width: 74)
                }

                filterField("Modified after") {
                    HStack(spacing: 6) {
                        Toggle("", isOn: $modifiedAfterEnabled)
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Filter by modification date")

                        DatePicker(
                            "",
                            selection: $modifiedAfterDate,
                            displayedComponents: .date
                        )
                        .labelsHidden()
                        .disabled(!modifiedAfterEnabled)
                        .accessibilityLabel("Modified after date")
                    }
                }

                Spacer(minLength: 4)

                Button("Scan") {
                    applyFilters(immediately: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.isPolicyLoaded || model.selectedFolder == nil || model.isTrashing)
                .help("Apply the filters and scan the chosen folder")
                .accessibilityLabel("Scan folder with current filters")
            }
            .padding(.top, 2)
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                .font(.caption.weight(.semibold))
        }
        .disabled(!model.isPolicyLoaded || model.isTrashing)
    }

    private func filterField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func applyFilters(immediately: Bool = false) {
        let afterDate = modifiedAfterEnabled
            ? Calendar.current.startOfDay(for: modifiedAfterDate)
            : nil
        let minimumBytes: Int64?
        if minimumSizeMB > 0 {
            let (bytes, overflow) = Int64(minimumSizeMB)
                .multipliedReportingOverflow(by: 1_048_576)
            minimumBytes = overflow ? Int64.max : bytes
        } else {
            minimumBytes = nil
        }

        model.setFilters(
            ExploreFilters(
                filenameContains: filename,
                fileExtension: extensionText,
                minimumSizeBytes: minimumBytes,
                modifiedAfter: afterDate
            )
        )

        if immediately {
            model.rescan()
        }
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        if let policyError = model.policyError {
            notice(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "Protection policy unavailable",
                detail: policyError
            )
        }

        if let folderError = model.folderError {
            notice(
                icon: "exclamationmark.triangle.fill",
                tint: .orange,
                title: "That folder cannot be explored",
                detail: folderError
            )
        }

        if let scanError = model.scanError {
            notice(
                icon: "exclamationmark.octagon.fill",
                tint: .red,
                title: "The scan failed",
                detail: scanError
            )
        }

        if model.isTruncated {
            notice(
                icon: "info.circle",
                tint: .secondary,
                title: "Showing the first \(model.resultLimit) matching files",
                detail: "Narrow the filters or choose a smaller folder to see the rest."
            )
        }

        if model.isCancelled, !model.isScanning {
            notice(
                icon: "info.circle",
                tint: .secondary,
                title: "The scan was cancelled",
                detail: "Any rows shown are the files found before cancellation."
            )
        }

        if !model.skipped.isEmpty {
            skippedLocations
        }

    }

    private func notice(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var skippedLocations: some View {
        DisclosureGroup {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.skipped) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(item.path)
                            Text(item.reason)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 120)
        } label: {
            Text("\(model.skipped.count) location\(model.skipped.count == 1 ? "" : "s") skipped or unreadable")
                .font(.caption)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if !model.isPolicyLoaded {
            statusPanel(
                icon: "lock.shield",
                title: "Protection policy missing",
                detail: "Explore needs policy.json in the app bundle before it can scan or move files to Trash."
            )
        } else if model.selectedFolder == nil {
            statusPanel(
                icon: "folder",
                title: "Choose a folder to begin",
                detail: "Only folders inside your home folder are accepted. Protected locations stay inspectable."
            )
        } else if model.isScanning, model.results.isEmpty {
            statusPanel(
                icon: "magnifyingglass",
                title: "Scanning…",
                detail: "Regular files are collected off the main thread. Use Cancel to stop early."
            )
        } else if let scanError = model.scanError {
            statusPanel(icon: "exclamationmark.octagon", title: "Scan failed", detail: scanError)
        } else if model.hasScanned, model.results.isEmpty {
            statusPanel(
                icon: "magnifyingglass",
                title: "No files match",
                detail: model.filters.isActive
                    ? "Adjust or clear the filters and scan again."
                    : "No readable regular files were found in this folder."
            )
        } else if !model.hasScanned {
            statusPanel(
                icon: "folder",
                title: "Ready to scan",
                detail: "Press Scan to read the chosen folder with the current filters."
            )
        } else {
            resultsTable
        }
    }

    private var resultsTable: some View {
        Table(model.results, selection: $model.selection) {
            TableColumn("Full path") { file in
                Text(file.url.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
                    .accessibilityLabel("Path \(file.url.path)")
            }
            .width(min: 260, ideal: 430)

            TableColumn("Size") { file in
                Text(ByteFormat.string(file.size))
                    .monospacedDigit()
                    .accessibilityLabel("Size \(ByteFormat.string(file.size))")
            }
            .width(min: 64, ideal: 84)

            TableColumn("Modified") { file in
                Text(
                    file.modificationDate.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .monospacedDigit()
            }
            .width(min: 128, ideal: 160)

            TableColumn("Protection") { file in
                if file.isProtected {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                            Text("Protected")
                                .font(.caption)
                        }
                        Text(file.protectionReason ?? "This file is protected.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .help(file.protectionReason ?? "This file is protected.")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(
                        "Protected. \(file.protectionReason ?? "This file is protected.")"
                    )
                } else {
                    Text("None")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Not protected")
                }
            }
            .width(min: 120, ideal: 190)
        }
        .frame(minHeight: 250, maxHeight: .infinity)
        .accessibilityLabel("Matching files")
    }

    private func statusPanel(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460)
        }
        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Trash

    private var trashControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(selectionSummary)
                    .font(.callout)
                    .monospacedDigit()

                Spacer(minLength: 8)

                Button("Select All") {
                    model.selectAll()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.results.isEmpty || model.isScanning)
                .help("Select every file in the table, including protected files")
                .accessibilityLabel("Select all files")

                Button("Select Unprotected") {
                    model.selectUnprotected()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.results.isEmpty || model.isScanning)
                .help("Select files that may be moved to Trash")
                .accessibilityLabel("Select unprotected files")

                Button("Clear") {
                    model.clearSelection()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.selection.isEmpty)
                .accessibilityLabel("Clear selection")

                Button {
                    model.requestTrash()
                } label: {
                    Label("Move to Trash…", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!model.canRequestTrash)
                .help(model.trashDisabledReason ?? "Review the exact paths before moving files to the native Trash")
                .accessibilityLabel("Review selected files and move them to Trash")
            }

            if let reason = model.trashDisabledReason {
                Label(reason, systemImage: model.isPolicyLoaded ? "lock.shield" : "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.isTrashing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Moving files to Trash…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            if let summary = model.trashSummary {
                Label(summary, systemImage: model.trashIssues.isEmpty ? "checkmark.circle" : "info.circle")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !model.trashIssues.isEmpty {
                trashIssues
            }
        }
    }

    private var selectionSummary: String {
        let count = model.selection.count
        let size = ByteFormat.string(model.selectedBytes)
        if count == 0 {
            return "No files selected"
        }
        return "\(count) selected, \(size)"
    }

    private var trashIssues: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Files not moved to Trash")
                .font(.caption.weight(.semibold))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(model.trashIssues) { issue in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: issue.outcome == .failed
                                ? "xmark.octagon.fill"
                                : "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(issue.outcome == .failed ? .red : .orange)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(issue.url.path)
                                    .font(.caption.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(issue.url.path)
                                Text(issue.message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 100)
        }
    }

    private var confirmationBinding: Binding<Bool> {
        Binding(
            get: { model.isConfirmingTrash },
            set: { presented in
                if !presented {
                    model.cancelTrashConfirmation()
                }
            }
        )
    }

    private var confirmationSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(confirmationTitle)
                .font(.title3.weight(.semibold))

            Text(
                "These files move to the macOS Trash, where you can recover them until you empty it. "
                    + "No cleanup rule or scheduled task is involved."
            )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 20) {
                LabeledContent("Files", value: "\(model.pendingTrashFiles.count)")
                LabeledContent("Total size", value: ByteFormat.string(pendingTrashBytes))
            }
            .font(.callout)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.pendingTrashFiles) { file in
                        Text(file.url.path)
                            .font(.caption.monospaced())
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                            .help(file.url.path)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(height: 180)
            .background(
                Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 6)
            )

            if model.isTrashing {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                    Text("Moving files to Trash…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            HStack {
                Spacer(minLength: 0)

                Button("Cancel") {
                    model.cancelTrashConfirmation()
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isTrashing)
                .accessibilityLabel("Cancel moving files to Trash")

                Button("Move to Trash", role: .destructive) {
                    Task { await model.confirmTrash() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .disabled(model.pendingTrashFiles.isEmpty || model.isTrashing)
                .accessibilityLabel("Move selected files to Trash")
            }
        }
        .padding(20)
        .frame(width: 580)
        .interactiveDismissDisabled(model.isTrashing)
    }

    private var confirmationTitle: String {
        let count = model.pendingTrashFiles.count
        return "Move \(count) file\(count == 1 ? "" : "s") to Trash?"
    }

    private var pendingTrashBytes: Int64 {
        model.pendingTrashFiles.reduce(0) { $0 + $1.size }
    }
}
