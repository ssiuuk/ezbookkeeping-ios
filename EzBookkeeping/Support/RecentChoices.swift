import Foundation

/// Remembers which account was used last for each category and each kind of transaction,
/// per server and book, so a new transaction starts with the account people usually pick.
/// It also keeps the category used at each shop. Same keys as the Android app's RecentChoices.
struct RecentChoices {
    private let defaults: UserDefaults
    private let prefix: String

    init(serverId: String, bookId: String?, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        prefix = "recent|" + serverId + "|" + (bookId ?? "") + "|"
    }

    func accountForCategory(_ categoryId: String?, destination: Bool) -> String? {
        guard let categoryId else {
            return nil
        }

        return defaults.string(forKey: prefix + (destination ? "to|" : "from|") + categoryId)
    }

    func accountForType(_ type: Int, destination: Bool) -> String? {
        defaults.string(forKey: prefix + (destination ? "to-type|" : "from-type|") + String(type))
    }

    func categoryForMerchant(_ merchant: String) -> String? {
        let key = Self.merchantKey(merchant)
        return key.isEmpty ? nil : defaults.string(forKey: prefix + "merchant|" + key)
    }

    /// Remembers the category used at a shop, so the next purchase there starts with it.
    func rememberMerchant(_ merchant: String, categoryId: String) {
        let key = Self.merchantKey(merchant)

        if !key.isEmpty {
            defaults.set(categoryId, forKey: prefix + "merchant|" + key)
        }
    }

    func remember(type: Int, categoryId: String, accountId: String, destinationAccountId: String?) {
        defaults.set(accountId, forKey: prefix + "from|" + categoryId)
        defaults.set(accountId, forKey: prefix + "from-type|" + String(type))

        if let destinationAccountId {
            defaults.set(destinationAccountId, forKey: prefix + "to|" + categoryId)
            defaults.set(destinationAccountId, forKey: prefix + "to-type|" + String(type))
        }
    }

    private static func merchantKey(_ merchant: String) -> String {
        merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
