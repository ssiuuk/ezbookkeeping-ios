import Foundation

/// The overview's numbers in the user's default currency; currencies without a rate are listed separately.
struct Summary {
    struct Totals {
        var income: Int64 = 0
        var expense: Int64 = 0
    }

    let currency: String
    private(set) var periods: [String: Totals] = [:]
    private(set) var netAssets: Int64 = 0
    private(set) var assets: Int64 = 0
    private(set) var liabilities: Int64 = 0
    private(set) var unconverted: [String] = []

    init(server: Server?, amounts: [String: PeriodAmounts]?, accounts: [Account]?, rates: ExchangeRates) {
        currency = server?.defaultCurrency ?? "USD"
        var missing: [String] = []

        for (name, period) in amounts ?? [:] {
            var totals = Totals()

            for item in period.items {
                guard let income = rates.convert(item.income, from: item.currency, to: currency),
                      let expense = rates.convert(item.expense, from: item.currency, to: currency) else {
                    missing.append(item.currency)
                    continue
                }

                totals.income += income
                totals.expense += expense
            }

            periods[name] = totals
        }

        for account in Account.selectable(accounts ?? []) {
            guard let converted = rates.convert(account.balance, from: account.currency, to: currency) else {
                missing.append(account.currency)
                continue
            }

            netAssets += converted

            if account.isLiability || converted < 0 {
                liabilities += converted
            } else {
                assets += converted
            }
        }

        liabilities = abs(liabilities)

        var seen = Set<String>()
        unconverted = missing.filter { $0 != currency && seen.insert($0).inserted }
    }

    func period(_ name: String) -> Totals {
        periods[name] ?? Totals()
    }
}
