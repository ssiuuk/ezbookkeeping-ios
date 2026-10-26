import AppIntents
import WidgetKit

/// The periods a widget can show, as named by v1/transactions/amounts.json.
enum WidgetPeriod: String, AppEnum {
    case today
    case thisWeek
    case thisMonth
    case thisYear

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Period"
    static var caseDisplayRepresentations: [WidgetPeriod: DisplayRepresentation] = [
        .today: "Today",
        .thisWeek: "This week",
        .thisMonth: "This month",
        .thisYear: "This year",
    ]
}

/// A book for the widget: "" follows the app, "personal" is the user's own, anything else a family book's id.
struct WidgetBookEntity: AppEntity {
    static let sameAsApp = "app"

    var id: String
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Book"
    static var defaultQuery = WidgetBookQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }

    static var appsBook: WidgetBookEntity {
        WidgetBookEntity(id: sameAsApp, name: String(localized: "Same as the app"))
    }
}

struct WidgetBookQuery: EntityQuery {
    func entities(for identifiers: [WidgetBookEntity.ID]) async throws -> [WidgetBookEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WidgetBookEntity] {
        let books = WidgetShare.load()?.books ?? []
        return [WidgetBookEntity.appsBook] + books.map { book in
            WidgetBookEntity(id: book.isPersonal ? "personal" : book.id, name: book.name)
        }
    }

    func defaultResult() async -> WidgetBookEntity? {
        WidgetBookEntity.appsBook
    }
}

/// The widget's settings: the period, the book and whether amounts are hidden.
struct SpendingWidgetIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Widget settings"
    static var description = IntentDescription("Choose what the Spending widget shows.")

    @Parameter(title: "Period", default: .thisMonth)
    var period: WidgetPeriod

    @Parameter(title: "Book")
    var book: WidgetBookEntity?

    @Parameter(title: "Hide amounts", default: false)
    var hideAmounts: Bool
}

/// The widget's refresh button.
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh"
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
