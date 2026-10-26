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
    /// Accepts "12.5", "12,50", "1,234.56" and "1.234,56", and sums such as "12.50+3" or "3×4.20" (see `evaluate`).
    static func parseAmount(_ text: String) -> Int64? {
        guard let value = evaluate(text) else {
            return nil
        }

        return cents(value)
    }

    /// Whether the text is a sum to work out rather than a plain amount, such as "12.50+3".
    static func isExpression(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // a leading minus is only a sign
        return trimmed.dropFirst().contains { operators.contains($0) }
    }

    static let operators: Set<Character> = ["+", "-", "−", "*", "×", "x", "X", "/", "÷"]

    /// Works out a typed amount or sum with + − × ÷ (and * / x), multiplying and dividing first. Each number may be
    /// written in any of the ways `parseAmount` accepts. Nil when it can't be read or divides by zero.
    static func evaluate(_ text: String) -> Decimal? {
        var numbers: [Decimal] = []
        var pending: [Character] = []
        var current = ""
        var sign: Decimal = 1

        func finishNumber() -> Bool {
            guard let value = number(current) else {
                return false
            }

            numbers.append(sign * value)
            current = ""
            sign = 1
            return true
        }

        for character in text {
            if operators.contains(character) {
                if current.trimmingCharacters(in: .whitespaces).isEmpty {
                    // a minus before a number makes it negative: "-3", "5×-2"
                    guard character == "-" || character == "−" else {
                        return nil
                    }

                    sign = -sign
                    continue
                }

                guard finishNumber() else {
                    return nil
                }

                pending.append(character)
            } else {
                current.append(character)
            }
        }

        guard finishNumber() else {
            return nil
        }

        // × and ÷ first, then + and −, left to right
        var terms: [Decimal] = [numbers[0]]
        var additions: [Character] = []

        for (index, op) in pending.enumerated() {
            let value = numbers[index + 1]

            switch op {
            case "*", "×", "x", "X":
                terms[terms.count - 1] *= value
            case "/", "÷":
                guard value != 0 else {
                    return nil
                }

                terms[terms.count - 1] /= value
            default:
                terms.append(value)
                additions.append(op)
            }
        }

        var total = terms[0]

        for (index, op) in additions.enumerated() {
            total += op == "+" ? terms[index + 1] : -terms[index + 1]
        }

        return total
    }

    /// One number as typed, without a sign: "12.5", "12,50", "1,234.56" or "1.234,56".
    private static func number(_ text: String) -> Decimal? {
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

        guard cleaned.range(of: "^([0-9]+\\.?[0-9]*|\\.[0-9]+)$", options: .regularExpression) != nil else {
            return nil
        }

        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Rounds to whole cents, or nil when it doesn't fit.
    private static func cents(_ value: Decimal) -> Int64? {
        var scaled = value * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)

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
            return String(localized: "Today")
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
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

    /// When a copy kept on the phone was saved: the time today, otherwise the day and time.
    static func savedAt(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, inSameDayAs: now) ? time(date) : dayHeader(date, now: now) + " " + time(date)
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
        case 1: return String(localized: "Cash")
        case 2: return String(localized: "Checking accounts")
        case 3: return String(localized: "Credit cards")
        case 4: return String(localized: "Virtual accounts")
        case 5: return String(localized: "Debts")
        case 6: return String(localized: "Receivables")
        case 7: return String(localized: "Investments")
        case 8: return String(localized: "Savings accounts")
        case 9: return String(localized: "Certificates of deposit")
        default: return String(localized: "Other accounts")
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
