import SwiftUI

/// All transactions, newest first, grouped by day and loading more while scrolling.
/// Can be limited to some accounts (comma-separated ids, for an account with sub-accounts).
struct TransactionsView: View {
    let accountIds: String?
    let title: String

    @EnvironmentObject private var appState: AppState

    @State private var transactions: [TransactionRecord] = []
    @State private var nextTimeSequenceId: String?
    @State private var loading = false
    @State private var loadedVersion = -1
    @State private var requestId = 0
    @State private var keyword = ""
    @State private var activeKeyword: String?
    @State private var error: String?
    @State private var editor: EditorTarget?
    /// When the list on screen was saved, while the server can't be reached.
    @State private var offlineSince: Date?

    private static let pageSize = 50

    var body: some View {
        List {
            if let offlineSince {
                Section {
                    OfflineNote(savedAt: offlineSince)
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task {
                            await load(reset: true)
                        }
                    }
                }
            }

            ForEach(days, id: \.start) { day in
                Section {
                    ForEach(day.transactions) { transaction in
                        Button {
                            editor = .edit(id: transaction.id)
                        } label: {
                            TransactionRow(transaction: transaction, meta: Formats.time(transaction.date))
                        }
                        .buttonStyle(.plain)
                        .onAppear {
                            if transaction.id == transactions.last?.id {
                                Task {
                                    await load(reset: false)
                                }
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(Formats.dayHeader(day.start))
                        Spacer()
                        Text(day.total)
                            .monospacedDigit()
                    }
                }
            }

            if loading && !transactions.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            }
        }
        .overlay {
            if transactions.isEmpty && !loading && loadedVersion >= 0 {
                ContentUnavailableView {
                    Label("No transactions yet", systemImage: "list.bullet")
                } description: {
                    Text("Tap Add to record your first one.")
                } actions: {
                    Button("Add transaction") {
                        editor = .add(accountId: firstAccountId)
                    }
                }
            } else if loading && transactions.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .searchable(text: $keyword, prompt: "Search descriptions")
        .onSubmit(of: .search) {
            search(keyword)
        }
        .onChange(of: keyword) { _, newValue in
            if newValue.isEmpty {
                search(nil)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if accountIds == nil {
                    BookMenu()
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .add(accountId: firstAccountId)
                } label: {
                    Label("Add transaction", systemImage: "plus")
                }
                .accessibilityIdentifier("add_transaction")
            }
        }
        .refreshable {
            await load(reset: true)
        }
        .task(id: appState.dataVersion) {
            if loadedVersion != appState.dataVersion {
                await load(reset: true)
            }
        }
        .sheet(item: $editor) { target in
            TransactionEditView(target: target)
        }
    }

    private var firstAccountId: String? {
        accountIds?.split(separator: ",").first.map(String.init)
    }

    private struct Day {
        let start: Date
        let transactions: [TransactionRecord]
        let total: String
    }

    private var days: [Day] {
        let calendar = Calendar.current
        var groups: [(Date, [TransactionRecord])] = []

        for transaction in transactions {
            let start = calendar.startOfDay(for: transaction.date)

            if let last = groups.last, last.0 == start {
                groups[groups.count - 1].1.append(transaction)
            } else {
                groups.append((start, [transaction]))
            }
        }

        return groups.map { Day(start: $0.0, transactions: $0.1, total: Self.dayTotal($0.1)) }
    }

    /// The day's spending, shown next to the date when all of it is in one currency.
    private static func dayTotal(_ transactions: [TransactionRecord]) -> String {
        var expense: Int64 = 0
        var currency: String?

        for transaction in transactions where transaction.type == TransactionType.expense && !transaction.hideAmount {
            if let currency, currency != transaction.sourceCurrency {
                return ""
            }

            currency = transaction.sourceCurrency
            expense += transaction.sourceAmount
        }

        guard let currency, expense != 0 else {
            return ""
        }

        return Formats.minus + Formats.amount(expense, currency: currency)
    }

    private func search(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed

        if normalized != activeKeyword {
            activeKeyword = normalized
            Task {
                await load(reset: true)
            }
        }
    }

    private func load(reset: Bool) async {
        guard let server = appState.activeServer else {
            return
        }

        if !reset && (loading || nextTimeSequenceId == nil) {
            return
        }

        requestId += 1
        let thisRequest = requestId
        let version = appState.dataVersion
        loading = true

        do {
            let fetched = try await server.client().load("v1/transactions/list.json", query: [
                ("count", String(Self.pageSize)),
                ("page", "1"),
                ("max_time", reset ? "0" : (nextTimeSequenceId ?? "0")),
                ("min_time", "0"),
                ("account_ids", accountIds),
                ("keyword", activeKeyword),
            ])

            guard thisRequest == requestId else {
                return
            }

            let page = TransactionPage.parse(fetched.value)
            loading = false
            error = nil

            if reset {
                offlineSince = fetched.savedAt
            }
            nextTimeSequenceId = page.nextTimeSequenceId

            if reset {
                transactions = page.items
                loadedVersion = version
            } else {
                transactions.append(contentsOf: page.items)
            }
        } catch {
            guard thisRequest == requestId else {
                return
            }

            loading = false

            if !(error is CancellationError) {
                self.error = error.localizedDescription
            }
        }
    }
}
