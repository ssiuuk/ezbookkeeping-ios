import AppIntents
import SwiftUI
import WidgetKit

@main
struct EzBookkeepingWidgets: WidgetBundle {
    var body: some Widget {
        SpendingWidget()
    }
}

/// Home screen widget, like the Android app's: a period's spending, a few other figures, the latest transactions and
/// quick ways to add one. Small shows the spending; medium adds income and two other periods; large adds the latest
/// transactions and buttons for income, transfers and purchases to review.
struct SpendingWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SpendingWidget", intent: SpendingWidgetIntent.self, provider: SpendingProvider()) { entry in
            SpendingWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Spending")
        .description("Spending this month, the latest transactions and quick ways to add one")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WidgetRow: Hashable {
    var title: String
    var subtitle: String
    var amount: String
    var type: Int
}

struct WidgetFigures {
    var currency: String
    var totals: [String: Summary.Totals]
    var unconverted: [String]
    var recent: [WidgetRow]
    /// When the figures were saved, while the server can't be reached.
    var savedAt: Date?
    /// The family book shown, or nil for the user's own.
    var bookName: String?
    /// The book to add transactions to: nil follows the app, "personal" is the user's own.
    var book: String?

    func expense(_ period: String) -> Int64 {
        totals[period]?.expense ?? 0
    }

    func income(_ period: String) -> Int64 {
        totals[period]?.income ?? 0
    }
}

struct SpendingEntry: TimelineEntry {
    enum Content {
        case figures(WidgetFigures)
        case signedOut
        case failed
    }

    var date: Date
    var period: WidgetPeriod
    var hideAmounts: Bool
    var content: Content
    var pendingCount: Int

    static func placeholder() -> SpendingEntry {
        SpendingEntry(date: Date(), period: .thisMonth, hideAmounts: false, content: .figures(WidgetFigures(
            currency: "USD", totals: ["thisMonth": Summary.Totals(income: 250000, expense: 123450), "today": Summary.Totals(income: 0, expense: 1250),
                                      "lastMonth": Summary.Totals(income: 250000, expense: 198000)],
            unconverted: [], recent: [
                WidgetRow(title: "Restaurants", subtitle: "Cash", amount: "−$12.50", type: TransactionType.expense),
                WidgetRow(title: "Groceries", subtitle: "Visa", amount: "−$48.20", type: TransactionType.expense),
            ], savedAt: nil, bookName: nil, book: nil)), pendingCount: 0)
    }
}

struct SpendingProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SpendingEntry {
        .placeholder()
    }

    func snapshot(for configuration: SpendingWidgetIntent, in context: Context) async -> SpendingEntry {
        context.isPreview ? .placeholder() : await entry(for: configuration)
    }

    func timeline(for configuration: SpendingWidgetIntent, in context: Context) async -> Timeline<SpendingEntry> {
        // refreshes every 30 minutes, and whenever something changes in the app
        Timeline(entries: [await entry(for: configuration)], policy: .after(Date().addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SpendingWidgetIntent) async -> SpendingEntry {
        let content = await Self.load(book: configuration.book)
        return SpendingEntry(date: Date(), period: configuration.period, hideAmounts: configuration.hideAmounts,
                             content: content, pendingCount: PendingPurchases.list().count)
    }

    /// Loads the periods' totals, exchange rates and latest transactions of the widget's book.
    static func load(book choice: WidgetBookEntity?) async -> SpendingEntry.Content {
        guard let share = WidgetShare.load(), let token = share.token, !token.isEmpty else {
            return .signedOut
        }

        let server = share.server
        let followsApp = choice == nil || choice?.id == WidgetBookEntity.sameAsApp
        let bookId: String? = followsApp ? share.bookId : (choice?.id == "personal" ? nil : choice?.id)
        let bookName: String? = followsApp ? share.bookName : (bookId == nil ? nil : choice?.name)
        let client = server.client(bookId: bookId)
        let query = Formats.periodQuery(firstDayOfWeek: server.user.int("firstDayOfWeek"))

        // the same requests as the app's overview, so the widget can use its copy while the server can't be reached
        async let amountsResult = fetch { try await client.load("v1/transactions/amounts.json", query: [("query", query), ("use_transaction_timezone", "false")], cacheAs: "overview-amounts") }
        async let ratesResult = fetch { try await client.load("v1/exchange_rates/latest.json") }
        async let recentResult = fetch { try await client.load("v1/transactions/list.json", query: [("count", "5"), ("page", "1"), ("max_time", "0"), ("min_time", "0")]) }

        let results = await (amountsResult, ratesResult, recentResult)

        guard case .success(let amounts) = results.0 else {
            return .failed
        }

        var rates = ExchangeRates()

        if case .success(let fetched) = results.1 {
            rates = ExchangeRates.parse(fetched.value)
        }

        let summary = Summary(server: server, amounts: PeriodAmounts.parseAll(amounts.value), accounts: nil, rates: rates)
        var totals: [String: Summary.Totals] = [:]

        for period in Formats.overviewPeriods {
            totals[period] = summary.period(period)
        }

        var rows: [WidgetRow] = []
        var savedAt = amounts.savedAt

        if case .success(let fetched) = results.2 {
            if let saved = fetched.savedAt {
                savedAt = min(savedAt ?? saved, saved)
            }

            rows = TransactionPage.parse(fetched.value).items.map { transaction in
                WidgetRow(title: TransactionText.title(transaction), subtitle: TransactionText.subtitle(transaction),
                          amount: TransactionText.amount(transaction), type: transaction.type)
            }
        }

        return .figures(WidgetFigures(currency: summary.currency, totals: totals, unconverted: summary.unconverted, recent: rows,
                                      savedAt: savedAt, bookName: bookName,
                                      book: followsApp ? nil : (bookId ?? "personal")))
    }
}

struct SpendingWidgetView: View {
    let entry: SpendingEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch entry.content {
        case .signedOut:
            message("Sign in to see your spending")
        case .failed:
            message("Couldn't update")
        case .figures(let figures):
            content(figures)
        }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ezBookkeeping")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: AppLink.scheme + "://")!)
    }

    @ViewBuilder
    private func content(_ figures: WidgetFigures) -> some View {
        switch family {
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                heading(figures)
                spent(figures)
                otherCurrencies(figures)
                Spacer(minLength: 0)
                if figures.savedAt != nil {
                    notUpdated(figures)
                } else {
                    Label("Add", systemImage: "plus.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .widgetURL(AppLink.add(type: TransactionType.expense, book: figures.book).url)

        case .systemMedium:
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    heading(figures)
                    spent(figures)
                    otherCurrencies(figures)
                    Spacer(minLength: 0)
                    stats(figures)
                    notUpdated(figures)
                }

                Spacer(minLength: 8)

                VStack(spacing: 10) {
                    addButton(type: TransactionType.expense, figures: figures, systemImage: "plus")
                    refreshButton
                }
            }

        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        heading(figures)
                        spent(figures)
                    }

                    Spacer()
                    refreshButton
                }

                stats(figures)
                otherCurrencies(figures)
                notUpdated(figures)
                Divider()

                // the notes above take the place of a row
                ForEach(Array(figures.recent.prefix(4 - notes(figures))), id: \.self) { row in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(row.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer()

                        Text(entry.hideAmounts ? "•••" : row.amount)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Color.amount(forType: row.type))
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 8) {
                    addButton(type: TransactionType.expense, figures: figures, systemImage: "minus", title: "Expense")
                    addButton(type: TransactionType.income, figures: figures, systemImage: "plus", title: "Income")
                    addButton(type: TransactionType.transfer, figures: figures, systemImage: "arrow.left.arrow.right", title: "Transfer")

                    if entry.pendingCount > 0 {
                        Link(destination: AppLink.review.url) {
                            Label("\(entry.pendingCount) to review", systemImage: "creditcard")
                                .font(.caption.bold())
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func periodName(_ period: String) -> LocalizedStringKey {
        switch period {
        case "today": return "Today"
        case "thisWeek": return "This week"
        case "lastMonth": return "Last month"
        case "thisYear": return "This year"
        default: return "This month"
        }
    }

    /// The two periods shown next to the income: a shorter and a longer one, or last month next to this month.
    private var otherPeriods: [String] {
        switch entry.period {
        case .today: return ["thisWeek", "thisMonth"]
        case .thisMonth: return ["today", "lastMonth"]
        default: return ["today", "thisMonth"]
        }
    }

    private func money(_ cents: Int64, _ figures: WidgetFigures) -> String {
        entry.hideAmounts ? "•••" : Formats.amount(cents, currency: figures.currency)
    }

    /// The period, and the book when it isn't the user's own.
    private func heading(_ figures: WidgetFigures) -> some View {
        HStack(spacing: 4) {
            Text(periodName(entry.period.rawValue))

            if let bookName = figures.bookName, !bookName.isEmpty {
                Text("· " + bookName)
            }
        }
        .font(.caption.bold())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func spent(_ figures: WidgetFigures) -> some View {
        Text(money(figures.expense(entry.period.rawValue), figures))
            .font(.title2.bold().monospacedDigit())
            .minimumScaleFactor(0.5)
            .lineLimit(1)
    }

    private func stats(_ figures: WidgetFigures) -> some View {
        HStack(spacing: 12) {
            stat("Income", money(figures.income(entry.period.rawValue), figures), color: .income)

            ForEach(otherPeriods, id: \.self) { period in
                stat(periodName(period), money(figures.expense(period), figures), color: .primary)
            }
        }
    }

    private func stat(_ label: LocalizedStringKey, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }

    /// When the figures were saved, while the server can't be reached; nothing otherwise.
    @ViewBuilder
    private func notUpdated(_ figures: WidgetFigures) -> some View {
        if let note = Formats.notUpdated(figures.savedAt, now: entry.date) {
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemSmall ? 2 : 1)
                .minimumScaleFactor(0.8)
        }
    }

    /// The currencies left out of the totals because there is no exchange rate for them; nothing otherwise.
    @ViewBuilder
    private func otherCurrencies(_ figures: WidgetFigures) -> some View {
        if let note = Formats.otherCurrencies(figures.unconverted) {
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    private func notes(_ figures: WidgetFigures) -> Int {
        (Formats.notUpdated(figures.savedAt, now: entry.date) == nil ? 0 : 1)
            + (Formats.otherCurrencies(figures.unconverted) == nil ? 0 : 1)
    }

    private func addButton(type: Int, figures: WidgetFigures, systemImage: String, title: LocalizedStringKey? = nil) -> some View {
        Link(destination: AppLink.add(type: type, book: figures.book).url) {
            Group {
                if let title {
                    Label(title, systemImage: systemImage)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                } else {
                    Image(systemName: systemImage)
                        .font(.title3.bold())
                        .frame(width: 40, height: 40)
                        .background(Color.accentColor, in: Circle())
                        .foregroundStyle(.white)
                }
            }
        }
        .accessibilityLabel(title ?? "Add transaction")
    }

    private var refreshButton: some View {
        Button(intent: RefreshWidgetIntent()) {
            Image(systemName: "arrow.clockwise")
                .font(.footnote.bold())
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Refresh")
    }
}
