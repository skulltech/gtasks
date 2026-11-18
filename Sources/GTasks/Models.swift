import Foundation

struct TaskList: Codable, Identifiable, Hashable {
    let id: String
    var title: String
}

struct GTask: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var notes: String?
    var status: String?      // "needsAction" | "completed"
    var due: String?         // RFC 3339; Google only stores the date part
    var parent: String?
    var position: String?
    var webViewLink: String?
}

struct PagedResponse<T: Codable>: Codable {
    var items: [T]?
    var nextPageToken: String?
}

// MARK: - Due dates

extension GTask {
    /// Local midnight of the due day. Google stores due as "YYYY-MM-DDT00:00:00.000Z" and
    /// ignores the time, so we read the calendar date literally instead of converting time zones.
    var dueDate: Date? {
        guard let due, due.count >= 10 else { return nil }
        let parts = due.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

enum DueFormat {
    enum Style { case overdue, today, future }

    static func rfc3339(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02dT00:00:00.000Z", c.year!, c.month!, c.day!)
    }

    static func daysFromToday(_ date: Date) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: date)).day ?? 0
    }

    static func describe(_ date: Date) -> (String, Style) {
        let days = daysFromToday(date)
        switch days {
        case 0: return ("Today", .today)
        case 1: return ("Tomorrow", .future)
        case ..<0:
            let n = -days
            if n == 1 { return ("Yesterday", .overdue) }
            if n < 7 { return ("\(n) days ago", .overdue) }
            if n < 30 { let w = n / 7; return ("\(w) week\(w == 1 ? "" : "s") ago", .overdue) }
            let m = n / 30; return ("\(m) month\(m == 1 ? "" : "s") ago", .overdue)
        default:
            let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            let fmt: Date.FormatStyle = sameYear
                ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                : .dateTime.month(.abbreviated).day().year()
            return (date.formatted(fmt), .future)
        }
    }

    static var today: Date { Calendar.current.startOfDay(for: Date()) }
    static func inDays(_ n: Int) -> Date { Calendar.current.date(byAdding: .day, value: n, to: today)! }
}
