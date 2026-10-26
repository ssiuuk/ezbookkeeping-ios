import Foundation

/// What the Spending widget needs from the app: the server in use, its sign-in and its books. The app writes it to
/// the app group whenever they change; the widget reads it to load its figures by itself every half hour.
struct WidgetShare: Codable, Equatable {
    struct Book: Codable, Equatable {
        var id: String
        var name: String
        var isPersonal: Bool
    }

    var serverId: String
    var serverName: String
    var url: String
    var token: String?
    var userJson: String?
    /// The book selected in the app; nil is the user's own.
    var bookId: String?
    var bookName: String?
    var books: [Book] = []

    private static let key = "widget_share"

    static func load(defaults: UserDefaults = SharedDefaults.defaults) -> WidgetShare? {
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        return try? JSONDecoder().decode(WidgetShare.self, from: data)
    }

    /// Saves it, and says whether it changed, so the widget is only reloaded then.
    @discardableResult
    static func save(_ share: WidgetShare?, defaults: UserDefaults = SharedDefaults.defaults) -> Bool {
        guard share != load(defaults: defaults) else {
            return false
        }

        if let share, let data = try? JSONEncoder().encode(share) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }

        return true
    }

    var server: Server {
        var server = Server(id: serverId, name: serverName, url: url)
        server.token = token
        server.userJson = userJson
        server.bookId = bookId
        server.bookName = bookName
        return server
    }
}

/// The app's own links, which the widget's buttons open: ezbookkeeping://add?type=3&book=… and ezbookkeeping://review.
enum AppLink: Equatable {
    /// A new transaction of a type; book is nil for the book selected in the app, "personal" for the user's own.
    case add(type: Int, book: String?)
    case review

    static let scheme = "ezbookkeeping"

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme

        switch self {
        case .add(let type, let book):
            components.host = "add"
            components.queryItems = [URLQueryItem(name: "type", value: String(type))]
                + (book.map { [URLQueryItem(name: "book", value: $0)] } ?? [])
        case .review:
            components.host = "review"
        }

        return components.url ?? URL(string: "ezbookkeeping://add")!
    }

    init?(url: URL) {
        guard url.scheme == Self.scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        func value(_ name: String) -> String? {
            components.queryItems?.first { $0.name == name }?.value
        }

        switch components.host {
        case "add":
            let type = Int(value("type") ?? "") ?? TransactionType.expense
            self = .add(type: [TransactionType.income, TransactionType.expense, TransactionType.transfer].contains(type) ? type : TransactionType.expense,
                        book: value("book"))
        case "review":
            self = .review
        default:
            return nil
        }
    }
}
