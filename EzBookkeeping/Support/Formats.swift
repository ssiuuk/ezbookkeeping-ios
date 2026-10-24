import Foundation

/// Formats amounts and dates the way the native screens show them.
/// Amounts from the server are whole cents (hundredths), whatever the currency.
enum Formats {
    static let minus = "\u{2212}"

    static func amount(_ cents: Int64, currency: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale

        if currency.count == 3 {
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
        } else {
            formatter.numberStyle = .decimal
        }

        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let magnitude = cents == Int64.min ? Int64.max : abs(cents)
        let value = NSDecimalNumber(mantissa: UInt64(magnitude), exponent: -2, isNegative: false)
        let text = formatter.string(from: value) ?? editableAmount(magnitude)
        // a real minus sign instead of the locale's hyphen
        return cents < 0 ? minus + text : text
    }

    static func signedAmount(_ cents: Int64, currency: String, negative: Bool, locale: Locale = .current) -> String {
        (negative ? minus : "+") + amount(cents == Int64.min ? Int64.max : abs(cents), currency: currency, locale: locale)
    }

    /// Parses what the user typed in an amount field into cents, or returns nil.
    /// Accepts "12.5", "12,50", "1,234.56" and "1.234,56".
    static func parseAmount(_ text: String) -> Int64? {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")

        if cleaned.isEmpty {
            return nil
        }

        let lastComma = cleaned.range(of: ",", options: .backwards)?.lowerBound
        let lastDot = cleaned.range(of: ".", options: .backwards)?.lowerBound

        if let lastComma, lastDot == nil || lastComma > lastDot! {
            // "1.234,56" or "12,5": the comma is the decimal separator
            cleaned = cleaned.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
        } else {
            cleaned = cleaned.replacingOccurrences(of: ",", with: "")
        }

        guard cleaned.range(of: "^-?([0-9]+\\.?[0-9]*|\\.[0-9]+)$", options: .regularExpression) != nil,
              let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }

        var cents = decimal * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .plain)

        let number = NSDecimalNumber(decimal: rounded)

        guard number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
              number.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending else {
            return nil
        }

        return number.int64Value
    }

    /// Shows cents in an amount field without grouping, for example 1250 → "12.50".
    static func editableAmount(_ cents: Int64) -> String {
        let negative = cents < 0
        let magnitude = cents.magnitude
        let whole = magnitude / 100
        let fraction = magnitude % 100
        return (negative ? "-" : "") + String(whole) + "." + (fraction < 10 ? "0" : "") + String(fraction)
    }

    // MARK: - Dates

    static func dayHeader(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "EEEEMMMMd" : "EEEEMMMMdyyyy")
        return formatter.string(from: date)
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// The first character of a name, for the round avatar in lists.
    static func initial(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "?"
    }

    // MARK: - Periods

    /// The periods the overview shows, in the order transactions/amounts.json is asked for them.
    static let overviewPeriods = ["today", "thisWeek", "thisMonth", "lastMonth", "thisYear"]

    /// Builds "today_start_end|thisWeek_start_end|…" in the phone's time zone, for transactions/amounts.json.
    /// firstDayOfWeek is the server's: 0 for Sunday, 1 for Monday and so on.
    static func periodQuery(now: Date = Date(), firstDayOfWeek: Int, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        var items: [String] = []

        for name in overviewPeriods {
            var start = today
            var end = today

            switch name {
            case "today":
                end = calendar.date(byAdding: .day, value: 1, to: today) ?? today
            case "thisWeek":
                let weekday = calendar.component(.weekday, from: today) // 1 is Sunday
                let offset = ((weekday - 1 - firstDayOfWeek) % 7 + 7) % 7
                start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
                end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
            case "thisMonth":
                start = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
                end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            case "lastMonth":
                end = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
                start = calendar.date(byAdding: .month, value: -1, to: end) ?? end
            default:
                start = calendar.date(from: calendar.dateComponents([.year], from: today)) ?? today
                end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
            }

            let startSeconds = Int64(start.timeIntervalSince1970)
            let endSeconds = Int64(end.timeIntervalSince1970) - 1
            items.append("\(name)_\(startSeconds)_\(endSeconds)")
        }

        return items.joined(separator: "|")
    }
}

/// Account kinds in the order people usually think of them, as the Accounts tab and account picker show them.
enum AccountCategories {
    static let order = [1, 2, 8, 3, 4, 5, 6, 7, 9]

    static func name(_ category: Int) -> String {
        switch category {
        case 1: return "Cash"
        case 2: return "Checking accounts"
        case 3: return "Credit cards"
        case 4: return "Virtual accounts"
        case 5: return "Debts"
        case 6: return "Receivables"
        case 7: return "Investments"
        case 8: return "Savings accounts"
        case 9: return "Certificates of deposit"
        default: return "Other accounts"
        }
    }

    struct AccountGroup: Identifiable {
        let category: Int
        let accounts: [Account]

        var id: Int {
            category
        }
    }

    /// Groups accounts by kind, in the usual order, followed by any kinds this app doesn't know.
    static func grouped(_ accounts: [Account]) -> [AccountGroup] {
        var categories = order

        for account in accounts where !categories.contains(account.category) {
            categories.append(account.category)
        }

        return categories.compactMap { category in
            let members = accounts.filter { $0.category == category }
            return members.isEmpty ? nil : AccountGroup(category: category, accounts: members)
        }
    }
}
