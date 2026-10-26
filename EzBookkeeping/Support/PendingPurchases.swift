import Foundation

/// Where the app and its widget share settings and the purchases to review.
enum SharedDefaults {
    static let appGroup = "group.com.ssiuuk.ezbookkeeping"

    /// The app group's settings when the app is signed with it, otherwise the app's own.
    static let defaults: UserDefaults = UserDefaults(suiteName: appGroup) ?? .standard
}

/// A purchase read from a payment, like the Android app's PaymentNotification: the amount with its currency,
/// the shop and the card. On the iPhone it comes from an Apple Pay automation in Shortcuts, which hands
/// over the shop, the amount ("£4.50") and the card, or from any text that reads like a payment.
struct Purchase: Equatable {
    var amount: Int64 = 0
    /// ISO code when the text makes it clear, otherwise empty and the account's currency is used.
    var currency = ""
    var merchant = ""
    /// How the card was named, like "Visa •••• 1234".
    var card = ""
    /// The card's last four digits, when shown.
    var cardDigits = ""
    var refund = false

    /// A key for remembering which account a card belongs to.
    var cardKey: String {
        if !cardDigits.isEmpty {
            return cardDigits
        }

        return card.lowercased().replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // a currency in front of the number ("HK$12.50", "USD 12.50", "€12,50") or after it ("12,50 €", "12.50 HKD")
    private static let symbol = "(?:[A-Z]{3}|[A-Z]{0,3}\\$|[€£¥₩₹₱฿₫₪₺₽]|R\\$|zł|kr|Fr\\.?)"
    private static let number = "\\d{1,3}(?:[,. \\u00a0\\u202f]\\d{3})*(?:[.,]\\d{1,2})?|\\d+(?:[.,]\\d{1,2})?"
    private static let amountBefore = try! NSRegularExpression(pattern: "(-?)(?<![A-Za-z])(" + symbol + ")\\s?(" + number + ")(?![\\d.,]*\\d)")
    private static let amountAfter = try! NSRegularExpression(pattern: "(-?)(?<![\\d.,])(" + number + ")\\s?(" + symbol + ")(?![A-Za-z])")
    private static let plainNumber = try! NSRegularExpression(pattern: "(-?)(" + number + ")")
    private static let cardDigitsPattern = try! NSRegularExpression(
        pattern: "[•·*●∙.xX]{2,}\\s*(\\d{4})\\b|\\b(?:ending(?: in)?|end(?:ing)?)\\s+(\\d{4})\\b", options: .caseInsensitive)
    private static let withCard = try! NSRegularExpression(pattern: "\\b(?:with|using|on|via)\\s+(.+)$", options: .caseInsensitive)
    private static let atMerchant = try! NSRegularExpression(pattern: "\\bat\\s+(.+)$", options: .caseInsensitive)

    /// Builds a purchase from what an Apple Pay automation hands over; nil when the amount can't be read.
    static func from(merchant: String, amount: String, card: String) -> Purchase? {
        let amountText = clean(amount)
        var purchase: Purchase

        if let found = findAmount(amountText) {
            purchase = Purchase()
            purchase.amount = found.cents
            purchase.currency = found.currency
            purchase.refund = found.negative
        } else if let match = plainNumber.firstMatch(in: amountText, range: whole(amountText)),
                  let cents = parseNumber(text(amountText, match, 2)), cents > 0 {
            // a bare "4.50" from Shortcuts' number formatting
            purchase = Purchase()
            purchase.amount = cents
            purchase.refund = !text(amountText, match, 1).isEmpty
        } else {
            return nil
        }

        guard purchase.amount > 0 else {
            return nil
        }

        purchase.card = clean(card)

        if let digits = cardDigitsPattern.firstMatch(in: purchase.card, range: whole(purchase.card)) {
            purchase.cardDigits = text(purchase.card, digits, digits.range(at: 1).location != NSNotFound ? 1 : 2)
        } else if let lastFour = purchase.card.range(of: "\\d{4}$", options: .regularExpression) {
            purchase.cardDigits = String(purchase.card[lastFour])
        }

        purchase.merchant = trimmedMerchant(clean(merchant))
        return purchase
    }

    /// Returns the purchase in a payment message's title and text, or nil when it doesn't look like one.
    static func parse(title rawTitle: String, text rawText: String) -> Purchase? {
        let title = clean(rawTitle)
        let body = clean(rawText)

        if title.isEmpty && body.isEmpty {
            return nil
        }

        let amountLine: String
        let found: FoundAmount

        if let inText = findAmount(body) {
            amountLine = body
            found = inText
        } else if let inTitle = findAmount(title) {
            amountLine = title
            found = inTitle
        } else {
            return nil
        }

        var purchase = Purchase()
        purchase.amount = found.cents
        purchase.currency = found.currency
        purchase.refund = found.negative || containsWord(title + " " + body, ["refund", "refunded", "returned"])

        let line = amountLine as NSString
        var rest = (line.substring(to: found.range.location) + " " + line.substring(from: found.range.location + found.range.length))
            .trimmingCharacters(in: .whitespaces)

        if let match = withCard.firstMatch(in: rest, range: whole(rest)) {
            purchase.card = text(rest, match, 1).trimmingCharacters(in: .whitespaces)
            rest = (rest as NSString).substring(to: match.range.location).trimmingCharacters(in: .whitespaces)
        }

        let both = title + " " + body

        if let digits = cardDigitsPattern.firstMatch(in: both, range: whole(both)) {
            let group = digits.range(at: 1).location != NSNotFound ? 1 : 2
            purchase.cardDigits = text(both, digits, group)

            if purchase.card.isEmpty {
                let before = (both as NSString).substring(to: digits.range.location).trimmingCharacters(in: .whitespaces)
                let name = before.split(separator: " ").last.map(String.init) ?? ""
                purchase.card = (name.isEmpty ? "" : name + " ") + "•••• " + purchase.cardDigits
            }
        }

        if let at = atMerchant.firstMatch(in: rest, range: whole(rest)) {
            purchase.merchant = text(rest, at, 1).trimmingCharacters(in: .whitespaces)
        } else {
            // the usual layout: the shop is the title, the amount and card the text
            purchase.merchant = amountLine == body ? title : rest
        }

        if purchase.refund {
            purchase.merchant = purchase.merchant.replacingOccurrences(of: "(?i)^refund(ed)?\\s+(from\\s+)?", with: "", options: .regularExpression)
        }

        purchase.merchant = trimmedMerchant(purchase.merchant)
        return purchase
    }

    private struct FoundAmount {
        var cents: Int64
        var currency: String
        var negative: Bool
        var range: NSRange
    }

    private static func findAmount(_ line: String) -> FoundAmount? {
        guard !line.isEmpty else {
            return nil
        }

        for (pattern, symbolGroup, numberGroup) in [(amountBefore, 2, 3), (amountAfter, 3, 2)] {
            for match in pattern.matches(in: line, range: whole(line)) where !looksLikeCardDigits(line, match) {
                guard let cents = parseNumber(text(line, match, numberGroup)), cents > 0 else {
                    continue
                }

                return FoundAmount(cents: cents, currency: currencyCode(text(line, match, symbolGroup)),
                                   negative: !text(line, match, 1).isEmpty, range: match.range)
            }
        }

        return nil
    }

    private static func looksLikeCardDigits(_ line: String, _ match: NSTextCheckingResult) -> Bool {
        let start = match.range.location

        guard start > 0 else {
            return false
        }

        let previous = (line as NSString).substring(with: NSRange(location: start - 1, length: 1))
        return "•·*●∙".contains(previous)
    }

    /// Reads "1,234.56", "12,50" or "1.234" (thousands) as cents.
    static func parseNumber(_ number: String) -> Int64? {
        let digits = number.replacingOccurrences(of: "[ \\u00a0\\u202f]", with: "", options: .regularExpression)
        let characters = Array(digits)
        var decimal = characters.lastIndex(where: { $0 == "." || $0 == "," })

        // "1,234" and "1.234" are thousands; "12,50" and "12.5" are decimals
        if let index = decimal, characters.count - index - 1 == 3 {
            decimal = nil
        }

        var whole = decimal.map { String(characters[..<$0]) } ?? digits
        let fraction = decimal.map { String(characters[($0 + 1)...]) } ?? ""
        whole = whole.replacingOccurrences(of: "[.,]", with: "", options: .regularExpression)

        if whole.isEmpty && fraction.isEmpty {
            return nil
        }

        guard let units = whole.isEmpty ? 0 : Int64(whole) else {
            return nil
        }

        var cents = units * 100

        if !fraction.isEmpty {
            guard let part = Int64(fraction.count == 1 ? fraction + "0" : fraction) else {
                return nil
            }

            cents += part
        }

        return cents
    }

    static func currencyCode(_ symbol: String) -> String {
        switch symbol {
        case "€": return "EUR"
        case "£": return "GBP"
        case "₩": return "KRW"
        case "₹": return "INR"
        case "₱": return "PHP"
        case "฿": return "THB"
        case "₫": return "VND"
        case "₪": return "ILS"
        case "₺": return "TRY"
        case "₽": return "RUB"
        case "R$": return "BRL"
        case "zł": return "PLN"
        case "US$": return "USD"
        case "HK$": return "HKD"
        case "NT$": return "TWD"
        case "S$": return "SGD"
        case "A$", "AU$": return "AUD"
        case "C$", "CA$": return "CAD"
        case "NZ$": return "NZD"
        case "MOP$": return "MOP"
        default:
            // "$", "¥", "kr" are used by several currencies; leave those to the account
            return symbol.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil ? symbol : ""
        }
    }

    private static func containsWord(_ line: String, _ words: [String]) -> Bool {
        let lower = " " + line.lowercased().replacingOccurrences(of: "[^a-z]+", with: " ", options: .regularExpression) + " "
        return words.contains { lower.contains(" " + $0 + " ") }
    }

    private static func trimmedMerchant(_ value: String) -> String {
        let trimmed = value.replacingOccurrences(of: "^[\\s:·•,.\\-–—]+|[\\s:·•,.\\-–—]+$", with: "", options: .regularExpression)
        return String(trimmed.prefix(64)).trimmingCharacters(in: .whitespaces)
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func whole(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    private static func text(_ line: String, _ match: NSTextCheckingResult, _ group: Int) -> String {
        let range = match.range(at: group)
        return range.location == NSNotFound ? "" : (line as NSString).substring(with: range)
    }
}

/// Purchases from Apple Pay automations that are waiting to be reviewed and saved, like the Android app's
/// PendingPayments. They stay on the phone until they are saved as transactions or dismissed.
enum PendingPurchases {
    struct Item: Codable, Identifiable, Equatable {
        var id: String
        /// Milliseconds since 1970, as on Android.
        var time: Int64
        var amount: Int64
        var currency = ""
        var merchant = ""
        var card = ""
        var cardKey = ""
        var refund = false
        var source = ""

        var date: Date {
            Date(timeIntervalSince1970: TimeInterval(time) / 1000)
        }
    }

    private static let key = "pending_purchases"
    private static let maxItems = 100
    // an automation can run twice for one tap; don't list the same purchase twice within a few seconds
    private static let duplicateWindow: Int64 = 10 * 1000

    /// Called after the list changes, so the overview and the widget can show it.
    static var onChange: (() -> Void)?

    /// Newest first.
    static func list(defaults: UserDefaults = SharedDefaults.defaults) -> [Item] {
        guard let data = defaults.data(forKey: key), let items = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }

        return items
    }

    static func get(_ id: String, defaults: UserDefaults = SharedDefaults.defaults) -> Item? {
        list(defaults: defaults).first { $0.id == id }
    }

    /// Adds a purchase, unless it repeats the one just added. Returns the new item, or nil for a repeat.
    @discardableResult
    static func add(_ purchase: Purchase, time: Date = Date(), source: String,
                    defaults: UserDefaults = SharedDefaults.defaults) -> Item? {
        var items = list(defaults: defaults)
        let millis = Int64(time.timeIntervalSince1970 * 1000)

        if items.contains(where: { $0.amount == purchase.amount && $0.merchant == purchase.merchant
            && $0.cardKey == purchase.cardKey && abs($0.time - millis) < duplicateWindow }) {
            return nil
        }

        let item = Item(id: UUID().uuidString, time: millis, amount: purchase.amount, currency: purchase.currency,
                        merchant: purchase.merchant, card: purchase.card, cardKey: purchase.cardKey,
                        refund: purchase.refund, source: source)
        items.insert(item, at: 0)

        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }

        save(items, defaults: defaults)
        return item
    }

    static func remove(_ id: String, defaults: UserDefaults = SharedDefaults.defaults) {
        var items = list(defaults: defaults)

        if let index = items.firstIndex(where: { $0.id == id }) {
            items.remove(at: index)
            save(items, defaults: defaults)
        }
    }

    /// Puts a dismissed item back, for undo.
    static func restore(_ item: Item, defaults: UserDefaults = SharedDefaults.defaults) {
        var items = list(defaults: defaults)

        guard !items.contains(where: { $0.id == item.id }) else {
            return
        }

        let index = items.firstIndex(where: { $0.time <= item.time }) ?? items.count
        items.insert(item, at: index)
        save(items, defaults: defaults)
    }

    private static func save(_ items: [Item], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: key)
        }

        onChange?()
    }
}
