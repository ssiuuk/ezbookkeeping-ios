import SwiftUI

/// Spending this month and other periods, net assets and the latest transactions.
struct OverviewView: View {
    @Binding var tab: MainTab

    @EnvironmentObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase

    @State private var amounts: [String: PeriodAmounts]?
    @State private var accounts: [Account]?
    @State private var rates = ExchangeRates()
    @State private var recent: [TransactionRecord] = []
    @State private var loadedVersion = -1
    @State private var loading = false
    @State private var error: String?
    @State private var editor: EditorTarget?
    @State private var pending: [PendingPurchases.Item] = []
    /// The purchase just dismissed, which Undo puts back.
    @State private var dismissed: PendingPurchases.Item?
    /// Transactions saved on the phone that the server hasn't taken yet.
    @State private var changes: [LocalStore.Change] = []
    @State private var decision: ChangeDecision?
    /// When the figures on screen were saved, while the server can't be reached; .distantPast when none were.
    @State private var offlineSince: Date?

    private static let recentCount = 5

    var body: some View {
        List {
            if let offlineSince {
                Section {
                    OfflineNote(savedAt: offlineSince == .distantPast ? nil : offlineSince)
                }
            }

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

            syncSection
            reviewSection
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
        .task(id: appState.pendingVersion) {
            pending = PendingPurchases.list()
        }
        .task(id: appState.syncVersion) {
            changes = appState.activeServer.map(Sync.changes) ?? []
        }
        .alert(decision?.title ?? "", isPresented: Binding(
            get: { decision != nil },
            set: { if !$0 { decision = nil } }
        ), presenting: decision) { decision in
            ForEach(decision.actions) { action in
                Button(action.title, role: action.role) {
                    action.run()
                }
            }

            Button("Cancel", role: .cancel) {}
        } message: { decision in
            Text(decision.message)
        }
        .onChange(of: scenePhase) { _, phase in
            // an Apple Pay automation may have added a purchase while the app was in the background
            if phase == .active {
                appState.pendingChanged()
            }
        }
    }

    /// Transactions saved on this phone that the server hasn't taken yet; ones that need a decision say so.
    @ViewBuilder
    private var syncSection: some View {
        if !changes.isEmpty {
            Section {
                ForEach(changes) { change in
                    Button {
                        open(change)
                    } label: {
                        ChangeRow(change: change)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("change")
                }
            } header: {
                Text("\(changes.count) transactions not on the server yet")
            } footer: {
                Text(changes.contains { !$0.isWaiting }
                     ? String(localized: "Tap the ones marked in red to choose what to keep.")
                     : String(localized: "They are sent by themselves as soon as the server answers."))
            }
        }
    }

    /// Opens a waiting change for editing, or asks how to settle one the server didn't take.
    private func open(_ change: LocalStore.Change) {
        if let question = ChangeDecision.forChange(change, edit: { editor = .change(id: change.id) }) {
            decision = question
        } else {
            editor = .change(id: change.id)
        }
    }

    /// Purchases from Apple Pay automations, waiting to be saved; tapping one opens it in the add form.
    @ViewBuilder
    private var reviewSection: some View {
        if !pending.isEmpty || dismissed != nil {
            Section {
                ForEach(pending) { item in
                    Button {
                        editor = .review(id: item.id)
                    } label: {
                        PendingPurchaseRow(item: item, defaultCurrency: appState.activeServer?.defaultCurrency ?? "")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pending:" + item.merchant)
                    .swipeActions {
                        Button("Dismiss", role: .destructive) {
                            dismiss(item)
                        }
                    }
                }

                if let dismissed {
                    HStack {
                        Text("Purchase dismissed")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Undo") {
                            PendingPurchases.restore(dismissed)
                            self.dismissed = nil
                        }
                        .accessibilityIdentifier("undo_dismiss")
                    }
                }
            } header: {
                Text("\(pending.count) purchases to review")
            } footer: {
                if !pending.isEmpty {
                    Text("Tap a purchase to save it as a transaction, or swipe it away.")
                }
            }
        }
    }

    private func dismiss(_ item: PendingPurchases.Item) {
        PendingPurchases.remove(item.id)
        dismissed = item
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
                    Text("Income \(Formats.amount(summary.period("thisMonth").income, currency: summary.currency))")
                        .foregroundStyle(Color.income)
                    Spacer()
                    Text("Last month \(Formats.amount(summary.period("lastMonth").expense, currency: summary.currency))")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)

                if !summary.unconverted.isEmpty {
                    Text("Also \(summary.unconverted.joined(separator: ", "))")
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

    private func periodRow(_ label: LocalizedStringKey, _ values: Summary.Totals, _ currency: String) -> some View {
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

        // the periods' dates change every day, so their copy on the phone goes by name
        async let amountsResult = fetch { try await client.load("v1/transactions/amounts.json", query: [("query", query), ("use_transaction_timezone", "false")], cacheAs: "overview-amounts") }
        async let accountsResult = fetch { try await client.load("v1/accounts/list.json", query: [("visible_only", "true")]) }
        async let ratesResult = fetch { try await client.load("v1/exchange_rates/latest.json") }
        async let recentResult = fetch { try await client.load("v1/transactions/list.json", query: [("count", String(Self.recentCount)), ("page", "1"), ("max_time", "0"), ("min_time", "0")]) }

        let results = await (amountsResult, accountsResult, ratesResult, recentResult)
        loading = false

        if Task.isCancelled {
            return
        }

        var failure: Error?
        var savedAt: Date?
        var unreachable = false

        func note(_ fetched: APIClient.Fetched) {
            if let saved = fetched.savedAt {
                savedAt = min(savedAt ?? saved, saved)
            }
        }

        func failed(_ error: Error) {
            if let apiError = error as? APIError, apiError.unreachable {
                // the note at the top already says the server can't be reached
                unreachable = true
            } else {
                failure = failure ?? error
            }
        }

        switch results.0 {
        case .success(let fetched):
            note(fetched)
            amounts = PeriodAmounts.parseAll(fetched.value)
        case .failure(let error): failed(error)
        }

        switch results.1 {
        case .success(let fetched):
            note(fetched)
            accounts = Account.parseList(fetched.value)
        case .failure(let error): failed(error)
        }

        // without rates, other currencies are listed separately
        if case .success(let fetched) = results.2 {
            rates = ExchangeRates.parse(fetched.value)
        }

        switch results.3 {
        case .success(let fetched):
            note(fetched)
            recent = TransactionPage.parse(fetched.value).items
        case .failure(let error): failed(error)
        }

        offlineSince = savedAt ?? (unreachable ? .distantPast : nil)

        if let failure, !(failure is CancellationError) {
            error = failure.localizedDescription
        } else if failure == nil {
            loadedVersion = version
        }
    }
}
