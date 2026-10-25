import Foundation

/// Transaction and category kinds, as numbered by the server.
enum TransactionType {
    static let modifyBalance = 1
    static let income = 2
    static let expense = 3
    static let transfer = 4
}

enum CategoryType {
    static let income = 1
    static let expense = 2
    static let transfer = 3

    static func of(transactionType: Int) -> Int {
        switch transactionType {
        case TransactionType.income:
            return income
        case TransactionType.transfer:
            return transfer
        default:
            return expense
        }
    }
}

struct Account: Identifiable, Hashable {
    var id: String
    var name: String
    var parentId: String
    var category: Int
    var type: Int
    var color: String
    var currency: String
    var balance: Int64
    var hidden: Bool
    var isAsset: Bool
    var isLiability: Bool
    var sharedBy: String
    var comment: String
    var subAccounts: [Account]

    init(json: JSONObject) {
        id = json.string("id")
        name = json.string("name")
        parentId = json.string("parentId", "0")
        category = json.int("category")
        type = json.int("type")
        color = json.string("color")
        currency = json.string("currency")
        balance = json.int64("balance")
        hidden = json.bool("hidden")
        isAsset = json.bool("isAsset")
        isLiability = json.bool("isLiability")
        sharedBy = json.string("sharedBy")
        comment = json.string("comment")
        subAccounts = json.objects("subAccounts").map { Account(json: $0) }
    }

    /// Accounts with sub-accounts hold their money in the sub-accounts, so transactions use those.
    var hasSubAccounts: Bool {
        !subAccounts.isEmpty
    }

    var totalBalance: Int64 {
        hasSubAccounts ? subAccounts.reduce(0) { $0 + $1.balance } : balance
    }

    /// The currency shown for the account's total: its own, or its first sub-account's.
    var displayCurrency: String {
        subAccounts.first?.currency ?? currency
    }

    static func parseList(_ result: Any?) -> [Account] {
        JSONObject.objects(in: result).map { Account(json: $0) }
    }

    /// Every account money can be booked to: plain accounts and sub-accounts, without hidden ones.
    /// Sub-accounts are named after their parent, as in "Bank · Savings".
    static func selectable(_ accounts: [Account]) -> [Account] {
        var list: [Account] = []

        for account in accounts where !account.hidden {
            if account.hasSubAccounts {
                for var sub in account.subAccounts where !sub.hidden {
                    if sub.name.isEmpty {
                        sub.name = account.name
                    } else if !sub.name.hasPrefix(account.name) {
                        sub.name = account.name + " · " + sub.name
                    }

                    list.append(sub)
                }
            } else {
                list.append(account)
            }
        }

        return list
    }
}

struct TransactionCategory: Identifiable, Hashable {
    var id: String
    var name: String
    var parentId: String
    var type: Int
    var color: String
    var icon: String
    var hidden: Bool
    var subCategories: [TransactionCategory]

    init(json: JSONObject) {
        id = json.string("id")
        name = json.string("name")
        parentId = json.string("parentId", "0")
        type = json.int("type")
        color = json.string("color")
        icon = json.string("icon")
        hidden = json.bool("hidden")
        subCategories = json.objects("subCategories").map { TransactionCategory(json: $0) }
    }

    /// The category list comes back grouped by category type, as {"1": [...], "2": [...]}.
    /// Hidden groups are left out.
    static func parseByType(_ result: Any?, type: Int) -> [TransactionCategory] {
        JSONObject(result).objects(String(type))
            .map { TransactionCategory(json: $0) }
            .filter { !$0.hidden }
    }

    static func parseAllTypes(_ result: Any?) -> [Int: [TransactionCategory]] {
        var map: [Int: [TransactionCategory]] = [:]

        for type in [CategoryType.income, CategoryType.expense, CategoryType.transfer] {
            map[type] = parseByType(result, type: type)
        }

        return map
    }
}

struct Tag: Identifiable, Hashable {
    var id: String
    var name: String
    var groupId: String
    var hidden: Bool

    init(json: JSONObject) {
        id = json.string("id")
        name = json.string("name")
        groupId = json.string("groupId", "0")
        hidden = json.bool("hidden")
    }

    static func parseList(_ result: Any?) -> [Tag] {
        JSONObject.objects(in: result).map { Tag(json: $0) }
    }
}

struct Project: Identifiable, Hashable {
    var id: String
    var name: String
    var hidden: Bool

    init(json: JSONObject) {
        id = json.string("id")
        name = json.string("name")
        hidden = json.bool("hidden")
    }

    static func parseList(_ result: Any?) -> [Project] {
        JSONObject.objects(in: result).map { Project(json: $0) }
    }
}

/// A family book; the user's own book is the one with isPersonal.
struct Book: Identifiable, Hashable {
    var id: String
    var name: String
    var ownerNickname: String
    var isPersonal: Bool
    var isOwner: Bool

    init(json: JSONObject) {
        id = json.string("id")
        name = json.string("name")
        ownerNickname = json.string("ownerNickname")
        isPersonal = json.bool("isPersonal")
        isOwner = json.bool("isOwner")
    }

    static func parseList(_ result: Any?) -> [Book] {
        JSONObject.objects(in: result).map { Book(json: $0) }
    }

    /// "My book", the book's name, or the name and who shared it.
    var label: String {
        if isPersonal {
            return "My book"
        }

        return isOwner ? name : "\(name) · Shared by \(ownerNickname)"
    }
}

/// The server's merchants list holds plain names.
enum Merchants {
    static func parseList(_ result: Any?) -> [String] {
        guard let array = result as? [Any] else {
            return []
        }

        return array.compactMap { item in
            guard let name = item as? String else {
                return nil
            }

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

struct TransactionRecord: Identifiable {
    var id: String
    var timeSequenceId: String
    var type: Int
    var categoryId: String
    var categoryName: String
    var categoryColor: String
    var time: Int64
    var utcOffset: Int
    var sourceAccountId: String
    var sourceAccountName: String
    var sourceCurrency: String
    var destinationAccountId: String
    var destinationAccountName: String
    var destinationCurrency: String
    var sourceAmount: Int64
    var destinationAmount: Int64
    var hideAmount: Bool
    var tagIds: [String]
    var tagNames: [String]
    var comment: String
    var editable: Bool
    var geoLocation: [String: Any]?
    var pictureIds: [String]
    var pictureURLs: [String]
    var projectId: String
    var merchant: String

    init(json: JSONObject) {
        id = json.string("id")
        timeSequenceId = json.string("timeSequenceId")
        type = json.int("type")
        categoryId = json.string("categoryId", "0")
        time = json.int64("time")
        utcOffset = json.int("utcOffset")
        sourceAccountId = json.string("sourceAccountId")
        destinationAccountId = json.string("destinationAccountId", "0")
        sourceAmount = json.int64("sourceAmount")
        destinationAmount = json.int64("destinationAmount")
        hideAmount = json.bool("hideAmount")
        comment = json.string("comment")
        editable = json.bool("editable", true)
        geoLocation = json.object("geoLocation")?.raw
        projectId = json.string("projectId", "0")
        merchant = json.string("merchant")

        let category = json.object("category")
        categoryName = category?.string("name") ?? ""
        categoryColor = category?.string("color") ?? ""

        let source = json.object("sourceAccount")
        sourceAccountName = source?.string("name") ?? ""
        sourceCurrency = source?.string("currency") ?? ""

        let destination = json.object("destinationAccount")
        destinationAccountName = destination?.string("name") ?? ""
        destinationCurrency = destination?.string("currency") ?? ""

        tagIds = (json.array("tagIds") ?? []).compactMap { item in
            if let text = item as? String {
                return text
            }

            return (item as? NSNumber)?.stringValue
        }
        tagNames = json.objects("tags").map { $0.string("name") }
        pictureIds = json.objects("pictures").map { $0.string("pictureId") }
        pictureURLs = json.objects("pictures").map { $0.string("originalUrl") }
    }

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(time))
    }
}

struct TransactionPage {
    var items: [TransactionRecord] = []
    /// Where the next page starts, or nil on the last page.
    var nextTimeSequenceId: String?

    static func parse(_ result: Any?) -> TransactionPage {
        let json = JSONObject(result)
        var page = TransactionPage()
        page.items = json.objects("items").map { TransactionRecord(json: $0) }

        if json.has("nextTimeSequenceId") {
            let next = json.string("nextTimeSequenceId")
            page.nextTimeSequenceId = next.isEmpty || next == "0" ? nil : next
        }

        return page
    }
}

/// Income and expense of one period, per currency, from transactions/amounts.json.
struct PeriodAmounts {
    struct Item: Equatable {
        var currency: String
        var income: Int64
        var expense: Int64
    }

    var items: [Item] = []

    static func parseAll(_ result: Any?) -> [String: PeriodAmounts] {
        var map: [String: PeriodAmounts] = [:]

        for (key, value) in JSONObject(result).raw {
            let item = JSONObject(value)
            var period = PeriodAmounts()
            period.items = item.objects("amounts").map {
                Item(currency: $0.string("currency"), income: $0.int64("incomeAmount"), expense: $0.int64("expenseAmount"))
            }
            map[key] = period
        }

        return map
    }
}

/// Exchange rates against one base currency, for showing totals in the user's default currency.
struct ExchangeRates {
    var rates: [String: Double] = [:]

    static func parse(_ result: Any?) -> ExchangeRates {
        let json = JSONObject(result)
        var exchangeRates = ExchangeRates()
        let base = json.string("baseCurrency")

        if !base.isEmpty {
            exchangeRates.rates[base] = 1.0
        }

        for rate in json.objects("exchangeRates") {
            if let value = Double(rate.string("rate")) {
                exchangeRates.rates[rate.string("currency")] = value
            }
        }

        return exchangeRates
    }

    /// Converts an amount in cents, or returns nil when either rate is unknown.
    func convert(_ amount: Int64, from: String, to: String) -> Int64? {
        if from == to {
            return amount
        }

        guard let fromRate = rates[from], let toRate = rates[to], fromRate != 0 else {
            return nil
        }

        return Int64((Double(amount) / fromRate * toRate).rounded())
    }
}

/// What the server's sign-in page offers, read from its public server_settings.js.
struct ServerInfo: Equatable {
    var internalAuth = true
    var oauth2 = false
    var register = false
    var pictures = true

    /// Reads flags written like `EZBOOKKEEPING_SERVER_SETTINGS['a']=1`.
    static func parse(script: String) -> ServerInfo? {
        guard script.contains("EZBOOKKEEPING_SERVER_SETTINGS") else {
            return nil
        }

        var info = ServerInfo()
        info.internalAuth = flag(script, "a", fallback: true)
        info.oauth2 = flag(script, "o", fallback: false)
        info.register = flag(script, "r", fallback: false)
        info.pictures = flag(script, "p", fallback: true)
        return info
    }

    private static func flag(_ script: String, _ key: String, fallback: Bool) -> Bool {
        let pattern = "\\[\\s*['\"]" + key + "['\"]\\s*\\]\\s*=\\s*([01])"

        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let range = Range(match.range(at: 1), in: script) else {
            return fallback
        }

        return script[range] == "1"
    }
}
