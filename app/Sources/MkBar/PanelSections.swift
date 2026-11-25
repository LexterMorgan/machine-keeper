import MkBarCore
import SwiftUI

/// Shared metrics so every row in the panel lines up.
enum PanelLayout {
    static let width: CGFloat = 340
    static let padding: CGFloat = 12
    static let labelColumn: CGFloat = 54
    static let labelGap: CGFloat = 8
    static let blockSpacing: CGFloat = 10
    static let tightSpacing: CGFloat = 6
    static let cornerRadius: CGFloat = 6
}

struct DiskSection: View {
    let disk: DiskInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let disk {
                HStack(alignment: .firstTextBaseline, spacing: PanelLayout.labelGap) {
                    RowLabel("Disk")
                    Text("\(ByteFormat.string(disk.freeBytes)) free")
                        .font(.subheadline)
                        .monospacedDigit()
                    Text("· \(ByteFormat.string(disk.usedBytes)) used")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text(disk.percent)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)

                UsageBar(fraction: usedFraction(disk))
                    .padding(.leading, PanelLayout.labelColumn + PanelLayout.labelGap)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: PanelLayout.labelGap) {
                    RowLabel("Disk")
                    Text("Not reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk")
        .accessibilityValue(accessibilityValue)
    }

    private func usedFraction(_ disk: DiskInfo) -> Double {
        guard disk.totalBytes > 0 else { return 0 }
        return min(max(Double(disk.usedBytes) / Double(disk.totalBytes), 0), 1)
    }

    private var accessibilityValue: String {
        guard let disk else { return "Not reported" }
        return "\(ByteFormat.string(disk.freeBytes)) free, "
            + "\(ByteFormat.string(disk.usedBytes)) used, \(disk.percent) used"
    }
}

struct MemorySection: View {
    let memory: MemoryInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let memory {
                HStack(alignment: .firstTextBaseline, spacing: PanelLayout.labelGap) {
                    RowLabel("Memory")
                    Text("Swap \(ByteFormat.string(memory.swap.usedBytes)) of \(ByteFormat.string(memory.swap.totalBytes))")
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                }

                HStack(alignment: .center, spacing: 6) {
                    PressureDot(level: memory.pressureLevel)
                    Text("Pressure: \(pressureText(memory))")
                        .font(.caption)
                        .lineLimit(1)
                    Text("· Compressor \(ByteFormat.string(memory.compressorBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.leading, PanelLayout.labelColumn + PanelLayout.labelGap)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: PanelLayout.labelGap) {
                    RowLabel("Memory")
                    Text("Not reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Memory")
        .accessibilityValue(accessibilityValue)
    }

    private func pressureText(_ memory: MemoryInfo) -> String {
        let label = memory.pressureLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return "Unknown" }
        return label.prefix(1).uppercased() + String(label.dropFirst())
    }

    private var accessibilityValue: String {
        guard let memory else { return "Not reported" }
        return "Swap \(ByteFormat.string(memory.swap.usedBytes)) of "
            + "\(ByteFormat.string(memory.swap.totalBytes)). "
            + "Pressure \(pressureText(memory)). "
            + "Compressor \(ByteFormat.string(memory.compressorBytes))."
    }
}

/// The decision: how much is ready to clean, and why it may be less than the
/// caches the user sees. Everything shown here comes from the report.
struct ReclaimableHero: View {
    let summary: ReportSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if summary.safeRuleIDs.isEmpty {
                Text("Nothing safe to clean right now")
                    .font(.headline)
                Text(emptyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(ByteFormat.string(summary.sweepableBytes))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("ready to clean")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            if summary.blockedBytes > 0 {
                blockedLine
            }

            if summary.optInBytes > 0 {
                Text("\(ByteFormat.string(summary.optInBytes)) in opt-in rules — never cleaned automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                    .help("Opt-in rules only run when you include them explicitly. Clean safe caches never does.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyExplanation: String {
        summary.blockedBytes > 0
            ? "Caches are empty or held by running apps; they refill as you work."
            : "Empty caches refill as you work; check back later."
    }

    private var blockedLine: some View {
        Text("\(ByteFormat.string(summary.blockedBytes)) held by running apps")
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: false, vertical: true)
            .help("Clean safe caches skips caches held by running apps. Quit an app to make its cache cleanable.")
    }
}

/// The detail under the decision: the largest safe rules.
struct RuleList: View {
    let rows: [RuleRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(ByteFormat.string(row.bytes))
                        .font(.caption.monospacedDigit())
                }
                .help("\(row.title) — \(row.reclaim)")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.title): \(ByteFormat.string(row.bytes)) safe to clean")
                .accessibilityHint(row.reclaim)
            }
        }
    }
}

struct StartupLine: View {
    let orphanCount: Int
    let isChecked: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbolName)
                .font(.caption)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(orphanCount > 0 ? Color.primary : Color.secondary)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private var text: String {
        guard isChecked else { return "Startup items not checked" }
        switch orphanCount {
        case 0: return "No orphaned startup items"
        case 1: return "1 orphaned startup item"
        default: return "\(orphanCount) orphaned startup items"
        }
    }

    private var symbolName: String {
        guard isChecked else { return "questionmark.circle" }
        return orphanCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle"
    }

    private var tint: Color {
        isChecked && orphanCount > 0 ? .orange : .secondary
    }

    private var helpText: String {
        guard isChecked else { return "The report did not include startup items." }
        return "Orphaned items point at a program that no longer exists. Run mk startup to list startup entries."
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.16))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * clampedFraction)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }

    private var clampedFraction: Double {
        min(max(fraction, 0), 1)
    }
}

struct PressureDot: View {
    let level: Int

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch level {
        case 1: return .green
        case 2: return .yellow
        case 4: return .red
        default: return .gray
        }
    }
}

private struct RowLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: PanelLayout.labelColumn, alignment: .leading)
    }
}
