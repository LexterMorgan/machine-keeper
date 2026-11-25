import Foundation

enum UpdatedLabel {
    /// "Updated just now" right after a refresh, then a fixed 24-hour clock.
    static func string(for date: Date?, now: Date = Date()) -> String {
        guard let date else { return "Not updated yet" }
        if now.timeIntervalSince(date) < 5 { return "Updated just now" }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return "Updated \(formatter.string(from: date))"
    }
}
