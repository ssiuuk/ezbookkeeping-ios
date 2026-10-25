import BackgroundTasks
import Foundation
import SwiftUI

/// The servers the user added, which one is in use and the family books of that one.
/// Server details are saved in UserDefaults and the sign-in tokens in the Keychain.
@MainActor
final class AppState: ObservableObject {
    private static let serversKey = "servers"
    private static let activeServerKey = "active_server_id"
    static let themeKey = "theme"

    @Published private(set) var servers: [Server] = []
    @Published private(set) var activeServerId: String?
    /// Bumped whenever data changes, so screens reload when shown again.
    @Published private(set) var dataVersion = 0
    /// The active server's books; empty when it has none or doesn't know about books.
    @Published private(set) var books: [Book] = []
    /// Whether the active server answered books/list.json (the fork's family books, projects and so on).
    @Published private(set) var serverHasBooks = false
    /// A short notice for the whole app, such as an expired sign-in.
    @Published var notice: String?
    /// Bumped when the To review list changes, which an automation can do while the app is open.
    @Published private(set) var pendingVersion = 0
    /// Bumped when the transactions saved on the phone change: saved, sent, held back or settled.
    @Published private(set) var syncVersion = 0

    /// The background refresh that sends changes saved on the phone while the app isn't open.
    static let syncTaskId = "com.ssiuuk.ezbookkeeping.sync"
    private var retryTask: Task<Void, Never>?
    private var retryDelay: UInt64 = 15

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if ProcessInfo.processInfo.arguments.contains("-resetForUITesting") {
            if let bundleId = Bundle.main.bundleIdentifier {
                defaults.removePersistentDomain(forName: bundleId)
            }

            Keychain.removeAll()
        }

        load()

        APIClient.onUnauthorized = { [weak self] baseURL, token in
            self?.signInExpired(baseURL: baseURL, token: token)
        }

        PendingPurchases.onChange = { [weak self] in
            Task { @MainActor in
                self?.pendingChanged()
            }
        }

        Sync.onChange = { [weak self] in
            self?.syncVersion += 1
            self?.dataChanged()
        }

        Sync.onQueued = { [weak self] in
            Task {
                await self?.sendWaiting()
            }
        }

        Connectivity.shared.onOnline = { [weak self] in
            Task {
                // screens showing the phone's copy load the server's figures again
                self?.dataChanged()
                await self?.sendWaiting()
            }
        }
    }

    // MARK: - Changes saved on the phone

    /// Sends what was saved on the phone; while a server doesn't answer, tries again a little later each time.
    func sendWaiting() async {
        retryTask?.cancel()
        retryTask = nil

        guard Sync.hasWaiting else {
            return
        }

        if await Sync.run(servers: servers) {
            retryDelay = 15
        } else {
            let delay = retryDelay
            retryDelay = min(retryDelay * 2, 600)
            retryTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)

                if !Task.isCancelled {
                    await self?.sendWaiting()
                }
            }
        }

        Self.scheduleBackgroundSync()
    }

    /// Asks iOS to wake the app now and then while changes wait, so they reach the server even if the app isn't opened.
    static func scheduleBackgroundSync() {
        guard Sync.hasWaiting else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: syncTaskId)
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: syncTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Runs in the background refresh: the saved servers, without the screens.
    static func sendWaitingInBackground() async {
        await Sync.run(servers: savedServers(defaults: .standard))
        scheduleBackgroundSync()
    }

    /// The To review list changed here or in a Shortcuts action, or the app came back to the front.
    func pendingChanged() {
        pendingVersion += 1
    }

    var activeServer: Server? {
        servers.first { $0.id == activeServerId }
    }

    // MARK: - Servers

    /// Adds a server, or renames the saved one with the same address, and returns it.
    @discardableResult
    func addServer(name: String, url: String) -> Server {
        if let index = servers.firstIndex(where: { $0.url == url }) {
            servers[index].name = name
            save()
            return servers[index]
        }

        let server = Server(name: name, url: url)
        servers.append(server)
        save()
        return server
    }

    func setActive(_ server: Server?) {
        if activeServerId != server?.id {
            books = []
            serverHasBooks = false
        }

        activeServerId = server?.id
        save()
        dataChanged()
    }

    func rename(_ server: Server, to name: String) {
        update(server.id) { $0.name = name }
    }

    func remove(_ server: Server) {
        Keychain.setToken(nil, for: server.id)
        LocalStore.shared.clearCache(serverId: server.id)
        LocalStore.shared.removeAll(serverId: server.id)
        WebSession.clear(server)
        servers.removeAll { $0.id == server.id }

        if activeServerId == server.id {
            activeServerId = servers.first?.id
            books = []
            serverHasBooks = false
        }

        save()
        dataChanged()
    }

    func finishSignIn(_ server: Server, token: String, userJson: String?) {
        Keychain.setToken(token, for: server.id)
        update(server.id) {
            $0.token = token
            $0.userJson = userJson
            $0.bookId = nil
            $0.bookName = nil
        }
        activeServerId = server.id
        save()
        dataChanged()
    }

    /// Signs out of a server: revokes the token on the server too, without waiting for it.
    func signOut(_ server: Server) {
        if let token = server.token, !token.isEmpty {
            let client = APIClient(baseURL: server.url, token: token, bookId: nil)
            Task {
                _ = try? await client.get("logout.json")
            }
        }

        forgetSignIn(server.id)
        WebSession.clear(server)
        // changes saved on the phone stay, and are sent once the same user signs in again
        LocalStore.shared.clearCache(serverId: server.id)
    }

    private func forgetSignIn(_ serverId: String) {
        Keychain.setToken(nil, for: serverId)
        update(serverId) {
            $0.token = nil
            $0.userJson = nil
            $0.bookId = nil
            $0.bookName = nil
        }

        if serverId == activeServerId {
            books = []
            serverHasBooks = false
        }
    }

    /// The server no longer accepts the saved sign-in of the server in use: go back to its sign-in screen.
    private func signInExpired(baseURL: String, token: String) {
        guard let server = activeServer, server.url == baseURL, server.token == token else {
            return
        }

        forgetSignIn(server.id)
        notice = "Your sign-in expired. Please sign in again."
    }

    // MARK: - Books

    /// Loads the active server's books; servers without family books answer 404 and keep working the same.
    func loadBooks() async {
        guard let server = activeServer, server.isSignedIn else {
            return
        }

        do {
            let result = try await server.client(bookId: nil).get("v1/books/list.json")
            guard activeServerId == server.id else {
                return
            }

            books = Book.parseList(result)
            serverHasBooks = true

            // the selected book may have been deleted or the user removed from it
            if let bookId = server.bookId, !books.contains(where: { $0.id == bookId }) {
                selectBook(nil)
            }
        } catch {
            if activeServerId == server.id {
                books = []
                serverHasBooks = false
            }
        }
    }

    /// Switches the main screens to a book; nil or the personal book is the user's own.
    func selectBook(_ book: Book?) {
        guard let id = activeServerId else {
            return
        }

        let chosen = book?.isPersonal == true ? nil : book
        update(id) {
            $0.bookId = chosen?.id
            $0.bookName = chosen?.name
        }
        dataChanged()
    }

    func dataChanged() {
        dataVersion += 1
    }

    // MARK: - Saving

    private func update(_ id: String, _ change: (inout Server) -> Void) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else {
            return
        }

        change(&servers[index])
        save()
    }

    /// The servers saved in the settings, with their sign-ins from the Keychain.
    static func savedServers(defaults: UserDefaults) -> [Server] {
        guard let data = defaults.data(forKey: serversKey), let saved = try? JSONDecoder().decode([Server].self, from: data) else {
            return []
        }

        return saved.map { server in
            var server = server
            server.token = Keychain.token(for: server.id)
            return server
        }
    }

    private func load() {
        servers = Self.savedServers(defaults: defaults)

        activeServerId = defaults.string(forKey: Self.activeServerKey)

        if activeServer == nil {
            activeServerId = servers.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            defaults.set(data, forKey: Self.serversKey)
        }

        defaults.set(activeServerId, forKey: Self.activeServerKey)
    }
}

/// The app's light or dark look, chosen in Settings.
enum ThemeChoice: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .system: return "System default"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
