import Foundation

/// A saved ezBookkeeping server and the sign-in kept for it.
/// The token itself lives in the Keychain; everything else is saved in the app's settings.
struct Server: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var url: String
    var userJson: String? = nil
    var bookId: String? = nil
    var bookName: String? = nil
    /// Not encoded: ServerStore keeps it in the Keychain.
    var token: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case url
        case userJson = "user"
        case bookId
        case bookName
    }

    init(id: String = UUID().uuidString, name: String, url: String) {
        self.id = id
        self.name = name
        self.url = url
    }

    var isSignedIn: Bool {
        !(token ?? "").isEmpty
    }

    var displayName: String {
        name.isEmpty ? hostLabel : name
    }

    var hostLabel: String {
        if let range = url.range(of: "://") {
            return String(url[range.upperBound...])
        }

        return url
    }

    var user: JSONObject {
        JSONObject.parse(userJson ?? "")
    }

    var defaultCurrency: String {
        let currency = user.string("defaultCurrency")
        return currency.isEmpty ? "USD" : currency
    }

    var userDisplayName: String {
        let nickname = user.string("nickname")
        return nickname.isEmpty ? user.string("username") : nickname
    }

    /// Calls the API of this server, in the selected book.
    func client() -> APIClient {
        APIClient(baseURL: url, token: token, bookId: bookId, cacheServerId: id)
    }

    /// Calls the API of this server in another book; nil is the user's own book.
    func client(bookId: String?) -> APIClient {
        APIClient(baseURL: url, token: token, bookId: bookId, cacheServerId: id)
    }

    /// Changes made on the phone are only sent with, and shown to, the user who made them.
    var userName: String {
        user.string("username")
    }

    /// Turns what the user typed into a server base address, or nil when it isn't one.
    static func normalizeURL(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.isEmpty {
            return nil
        }

        if !text.contains("://") {
            text = "https://" + text
        }

        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else {
            return nil
        }

        var path = components.percentEncodedPath

        // people often paste the address of a page, so drop a trailing page name like /mobile or /desktop
        if path.hasSuffix("/mobile") || path.hasSuffix("/desktop") || path.hasSuffix("/index.html") {
            if let slash = path.lastIndex(of: "/") {
                path = String(path[..<slash])
            }
        }

        while path.hasSuffix("/") {
            path.removeLast()
        }

        var authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host

        if let port = components.port {
            authority += ":\(port)"
        }

        return scheme + "://" + authority.lowercased() + path
    }
}
