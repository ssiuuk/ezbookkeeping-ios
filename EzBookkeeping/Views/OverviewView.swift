import SwiftUI

/// Spending this month and other periods, net assets and the latest transactions.
struct OverviewView: View {
    @Binding var tab: MainTab

    @EnvironmentObject private var appState: AppState

    @State private var amounts: [String: PeriodAmounts]?
    @State private var accounts: [Account]?
    @State private var rates = ExchangeRates()
    @State private var recent: [TransactionRecord] = []
    @State private var loadedVersion = -1
    @State private var loading = false
    @State private var error: String?
    @State private var editor: EditorTarget?

    private static let recentCount = 5

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task {
                            await load()
                        }
                    }
                }
            }

            monthSection
            periodsSection
            assetsSection
            recentSection
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BookMenu()
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .add(accountId: nil)
                } label: {
                    Label("Add transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("add_transaction")
            }
        }
        .overlay {
            if loading && amounts == nil {
                ProgressView()
            }
        }
        .refreshable {
            await load()
        }
        .task(id: appState.dataVersion) {
            if loadedVersion != appState.dataVersion {
                await load()
            }
        }
        .sheet(item: $editor) { target in
            TransactionEditView(target: target)
        }
    }

    // MARK: - Sections

    private var summary: Summary {
        Summary(server: appState.activeServer, amounts: amounts, accounts: accounts, rates: rates)
    }

    @ViewBuilder
    private var monthSection: some View {
        let summary = self.summary

        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("This month")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Formats.amount(summary.period("thisMonth").expense, currency: summary.currency))
                    .font(.largeTitle.bold().monospacedDigit())
                    .accessibilityIdentifier("month_expense")
                HStack {
                    Text("Income " + Formats.amount(summary.period("thisMonth").income, currency: summary.currency))
                        .foregroundStyle(Color.income)
                    Spacer()
                    Text("Last month " + Formats.amount(summary.period("lastMonth").expense, currency: summary.currency))
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                if !summary.unconverted.isEmpty {
                    Text("Also " + summary.unconverted.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var periodsSection: some View {
        let summary = self.summary

        Section {
            periodRow("Today", summary.period("today"), summary.currency)
            periodRow("This week", summary.period("thisWeek"), summary.currency)
            periodRow("This year", summary.period("thisYear"), summary.currency)
        }
    }

    private func periodRow(_ label: String, _ values: Summary.Totals, _ currency: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            VStack(alignment: .trailing) {
                Text(Formats.minus + Formats.amount(values.expense, currency: currency))
                    .foregroundStyle(Color.expense)
                Text("+" + Formats.amount(values.income, currency: currency))
                    .font(.caption)
                    .foregroundStyle(Color.income)
            }
            .font(.body.monospacedDigit())
        }
    }

    @ViewBuilder
    private var assetsSection: some View {
        let summary = self.summary

        if accounts != nil {
            Section {
                Button {
                    tab = .accounts
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Net assets")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(Formats.amount(summary.netAssets, currency: summary.currency))
                            .font(.title2.bold().monospacedDigit())
                            .foregroundStyle(.primary)
                        Text("Assets \(Formats.amount(summary.assets, currency: summary.currency))  ·  Liabilities \(Formats.amount(summary.liabilities, currency: summary.currency))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("assets_card")
            }
        }
    }

    private var recentSection: some View {
        Section {
            if recent.isEmpty && loadedVersion >= 0 {
                Text("No transactions yet. Tap + to record your first one.")
                    .foregroundStyle(.secondary)
            }

            ForEach(recent) { transaction in
                Button {
                    editor = .edit(id: transaction.id)
                } label: {
                    TransactionRow(transaction: transaction, meta: Formats.dayHeader(transaction.date))
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Recent transactions")
                Spacer()
                Button("See all") {
                    tab = .transactions
                }
                .font(.subheadline)
                .textCase(nil)
                .accessibilityIdentifier("see_all")
            }
        }
    }

    // MARK: - Loading

    private func load() async {
        guard let server = appState.activeServer else {
            return
        }

        let version = appState.dataVersion
        let client = server.client()
        let query = Formats.periodQuery(firstDayOfWeek: server.user.int("firstDayOfWeek"))
        loading = true
        error = nil

        async let amountsResult = capture { try await client.get("v1/transactions/amounts.json", query: [("query", query), ("use_transaction_timezone", "false")]) }
        async let accountsResult = capture { try await client.get("v1/accounts/list.json", query: [("visible_only", "true")]) }
        async let ratesResult = capture { try await client.get("v1/exchange_rates/latest.json") }
        async let recentResult = capture { try await client.get("v1/transactions/list.json", query: [("count", String(Self.recentCount)), ("page", "1"), ("max_time", "0"), ("min_time", "0")]) }

        let results = await (amountsResult, accountsResult, ratesResult, recentResult)
        loading = false

        if Task.isCancelled {
            return
        }

        var failure: Error?

        switch results.0 {
        case .success(let value): amounts = PeriodAmounts.parseAll(value)
        case .failure(let error): failure = error
        }

        switch results.1 {
        case .success(let value): accounts = Account.parseList(value)
        case .failure(let error): failure = failure ?? error
        }

        // without rates, other currencies are listed separately
        if case .success(let value) = results.2 {
            rates = ExchangeRates.parse(value)
        }

        switch results.3 {
        case .success(let value): recent = TransactionPage.parse(value).items
        case .failure(let error): failure = failure ?? error
        }

        if let failure, !(failure is CancellationError) {
            error = failure.localizedDescription
        } else if failure == nil {
            loadedVersion = version
        }
    }
}
