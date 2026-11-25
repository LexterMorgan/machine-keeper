import Foundation

/// Formats byte counts exactly like the CLI's `src/bytes.mjs`.
public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    public static func string(_ bytes: Int64) -> String {
        guard bytes > 0 else {
            return "0 B"
        }

        // Match the CLI's Number arithmetic: the value is a Double at every
        // step, and each division is by a power of two and therefore exact.
        var value = Double(bytes)
        var unitIndex = 0
        while value >= 1024 && unitIndex < units.count - 1 {
            value /= 1024
            unitIndex += 1
        }

        let precision = value >= 100 ? 0 : value >= 10 ? 1 : 2
        return "\(decimalString(value, fractionDigits: precision)) \(units[unitIndex])"
    }

    /// Formats a positive value with ECMAScript `Number.prototype.toFixed`
    /// semantics: the exact binary value is rounded to the requested number of
    /// fractional digits, and exact halves go to the larger integer.
    ///
    /// C's `%.*f` (used by `String(format:)`) rounds halves to even instead, so
    /// a 100.5 KB report would print "100 KB" while the CLI prints "101 KB".
    /// Format far enough beyond the value's exact decimal expansion and round
    /// the digit string ourselves. A Double at or above 1 has at most 52
    /// fractional binary digits, so 60 decimal places are exact.
    private static func decimalString(_ value: Double, fractionDigits: Int) -> String {
        let exact = String(
            format: "%.60f",
            locale: Locale(identifier: "en_US_POSIX"),
            arguments: [value]
        )
        let pieces = exact.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = String(pieces[0])
        let fraction = pieces.count > 1 ? String(pieces[1]) : ""

        let retainedFraction = String(fraction.prefix(fractionDigits))
        let nextDigit: Character
        if fraction.count > fractionDigits {
            nextDigit = fraction[fraction.index(fraction.startIndex, offsetBy: fractionDigits)]
        } else {
            nextDigit = "0"
        }

        var digits = whole + retainedFraction
        if nextDigit >= "5" {
            digits = increment(digits)
        }

        guard fractionDigits > 0 else {
            return digits
        }
        if digits.count <= fractionDigits {
            digits = String(repeating: "0", count: fractionDigits + 1 - digits.count) + digits
        }
        let split = digits.index(digits.endIndex, offsetBy: -fractionDigits)
        return String(digits[..<split]) + "." + String(digits[split...])
    }

    /// Adds one to a non-empty ASCII digit string, carrying leftwards.
    private static func increment(_ digits: String) -> String {
        var characters = Array(digits)
        var index = characters.count - 1
        while index >= 0 {
            if characters[index] == "9" {
                characters[index] = "0"
                index -= 1
                continue
            }
            let digit = (characters[index].wholeNumberValue ?? 0) + 1
            characters[index] = Character(String(digit))
            return String(characters)
        }
        return "1" + String(characters)
    }
}

/// The memory pressure labels the CLI reports, mapped from `pressureLevel`.
public enum MemoryPressure: String, Sendable {
    case normal
    case warning
    case critical
    case unknown

    public init(level: Int) {
        switch level {
        case 1:
            self = .normal
        case 2:
            self = .warning
        case 4:
            self = .critical
        default:
            self = .unknown
        }
    }

    public var label: String {
        rawValue
    }
}
