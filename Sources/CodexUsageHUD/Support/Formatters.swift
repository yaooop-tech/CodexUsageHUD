import Foundation

enum HUDFormatters {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static let compactDateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()

    static let railDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static let railTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let compactNumber: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    static func tokenCount(_ value: Int64?) -> String {
        guard let value else {
            return "-"
        }
        if value >= 1_000_000 {
            let millions = Double(value) / 1_000_000
            return String(format: "%.1fM", millions)
        }
        if value >= 1_000 {
            let thousands = Double(value) / 1_000
            return String(format: "%.1fK", thousands)
        }
        return "\(value)"
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        return HUDFormatters.time.string(from: date)
    }

    static func fullResetText(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        return HUDFormatters.dateTime.string(from: date)
    }

    static func compactFullResetText(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        return HUDFormatters.compactDateTime.string(from: date)
    }

    static func railResetParts(_ date: Date?) -> (date: String, time: String) {
        guard let date else {
            return ("-", "--:--")
        }
        return (HUDFormatters.railDate.string(from: date), HUDFormatters.railTime.string(from: date))
    }

    static func durationLabel(minutes: Int64?) -> String {
        guard let minutes else {
            return "Window"
        }
        if minutes == 300 {
            return "5-hour"
        }
        if minutes == 10_080 {
            return "Weekly"
        }
        if minutes >= 60 {
            return "\(minutes / 60)h"
        }
        return "\(minutes)m"
    }
}
