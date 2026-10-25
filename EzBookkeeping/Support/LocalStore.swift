import Foundation

/// The phone's own copy, as in the Android app's LocalStore: what each server last answered, to show while it
/// can't be reached, and the transactions added, changed or deleted meanwhile, waiting to be sent to it.
/// Answers are files under Application Support; the changes are one JSON file. Safe to use from any thread.
final class LocalStore: @unchecked Sendable {
    static let shared = LocalStore()

    // answers kept per server; the oldest go first
    private static let maxCached = 400
    // how long the server's id for a sent change is kept, for an editor that was still open on it
    private static let sentKept: TimeInterval = 7 * 24 * 60 * 60

    enum Kind: String, Codable {
        case add
        case modify
        case delete
    }

    enum State: String, Codable {
        /// Waiting to be sent.
        case waiting
        /// Changed on the server too, and the user picks which version stays. For an add, the server has a transaction
        /// like it, which may be this one sent earlier without an answer coming back.
        case conflict
        /// The server refused it, for example because its account was deleted.
        case failed
    }

    /// A transaction added, changed or deleted on this phone that the server hasn't taken yet.
    struct Change: Codable, Identifiable, Equatable {
        var id: Int = 0
        var serverId: String
        /// The user signed in when the change was made; it is only sent, and only shown, while they are signed in.
        var userName: String
        /// Goes up with each edit the user makes, so a send that started from an older version doesn't remove the newer one.
        var revision: Int = 0
        /// When it was last sent without an answer coming back.
        var lastAttemptAt: Date?
        /// The book it belongs to; nil is the user's own book.
        var bookId: String?
        var kind: Kind
        /// The server's id of the transaction; nil for one added on this phone.
        var transactionId: String?
        /// What add.json, modify.json or delete.json is sent, as JSON text.
        var bodyText: String
        /// The server's version the change was made to, to notice when someone changed it meanwhile.
        var baseText: String?
        /// Names to show it by while the lists of accounts and categories may be out of reach.
        var labels: [String: String] = [:]
        var createdAt = Date()
        var state = State.waiting
        var message: String?
        /// The server's version when they conflict; nil when it was deleted there.
        var serverCopyText: String?
        var attempts = 0

        var isWaiting: Bool {
            state == .waiting
        }

        var body: [String: Any] {
            get { LocalStore.object(bodyText) ?? [:] }
            set { bodyText = LocalStore.text(newValue) ?? "{}" }
        }

        var base: [String: Any]? {
            get { baseText.flatMap(LocalStore.object) }
            set { baseText = newValue.flatMap(LocalStore.text) }
        }

        var serverCopy: [String: Any]? {
            get { serverCopyText.flatMap(LocalStore.object) }
            set { serverCopyText = newValue.flatMap(LocalStore.text) }
        }

        func label(_ key: String) -> String {
            labels[key] ?? ""
        }
    }

    /// What the server got for a change that is no longer waiting, for an add or edit screen still open on it.
    struct Sent: Codable {
        var changeId: Int
        var serverId: String
        var transactionId: String?
        /// The server's version after the change; nil after a deletion.
        var serverCopyText: String?
        var sentAt: Date

        var serverCopy: [String: Any]? {
            serverCopyText.flatMap(LocalStore.object)
        }
    }

    private struct Outbox: Codable {
        var nextId = 1
        var changes: [Change] = []
        var sent: [Sent] = []
    }

    private let lock = NSLock()
    private let folder: URL
    private var outbox: Outbox

    init(folder: URL? = nil) {
        // in the app group, so the widget can show the app's copy while the server can't be reached
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedDefaults.appGroup)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let base = folder ?? container.appendingPathComponent("offline", isDirectory: true)
        self.folder = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: base.appendingPathComponent("outbox.json")),
           let saved = try? JSONDecoder().decode(Outbox.self, from: data) {
            outbox = saved
        } else {
            outbox = Outbox()
        }
    }

    // MARK: - Answers

    /// Keeps the server's answer to a request, to show while the server can't be reached.
    func putCached(serverId: String, bookId: String?, path: String, result: Any?) {
        let wrapper: [String: Any] = ["savedAt": Date().timeIntervalSince1970, "result": result ?? NSNull()]

        guard JSONSerialization.isValidJSONObject(wrapper), let data = try? JSONSerialization.data(withJSONObject: wrapper) else {
            return
        }

        let serverFolder = cacheFolder(serverId)
        try? FileManager.default.createDirectory(at: serverFolder, withIntermediateDirectories: true)

        lock.lock()
        defer { lock.unlock() }

        try? data.write(to: serverFolder.appendingPathComponent(Self.cacheName(bookId: bookId, path: path)), options: .atomic)
        pruneCache(serverFolder)
    }

    /// An answer the server gave earlier, and when.
    func getCached(serverId: String, bookId: String?, path: String) -> (result: Any?, savedAt: Date)? {
        let file = cacheFolder(serverId).appendingPathComponent(Self.cacheName(bookId: bookId, path: path))

        lock.lock()
        let data = try? Data(contentsOf: file)
        lock.unlock()

        guard let data, let wrapper = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let savedAt = wrapper["savedAt"] as? Double else {
            return nil
        }

        let result = wrapper["result"]
        return (result is NSNull ? nil : result, Date(timeIntervalSince1970: savedAt))
    }

    /// Forgets what a server answered, after signing out of it or removing it.
    func clearCache(serverId: String) {
        lock.lock()
        defer { lock.unlock() }

        try? FileManager.default.removeItem(at: cacheFolder(serverId))
    }

    private func cacheFolder(_ serverId: String) -> URL {
        folder.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(serverId.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private func pruneCache(_ serverFolder: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]

        guard let files = try? FileManager.default.contentsOfDirectory(at: serverFolder, includingPropertiesForKeys: Array(keys)),
              files.count > Self.maxCached else {
            return
        }

        let sorted = files.sorted {
            let first = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return first > second
        }

        for file in sorted.dropFirst(Self.maxCached) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A file name for a book and request: an FNV-1a hash, since the path can be long and full of symbols.
    static func cacheName(bookId: String?, path: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325

        for byte in ((bookId ?? "") + "|" + path).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }

        return String(hash, radix: 16) + ".json"
    }

    // MARK: - Changes waiting to be sent

    /// Adds a new change and returns it with its id.
    @discardableResult
    func insert(_ change: Change) -> Change {
        lock.lock()
        defer { lock.unlock() }

        var added = change
        added.id = outbox.nextId
        outbox.nextId += 1
        outbox.changes.append(added)
        saveOutbox()
        return added
    }

    /// Saves the user's edit of a change and returns it with its new revision; nil when it is gone meanwhile,
    /// because it was sent or settled.
    func update(_ change: Change) -> Change? {
        lock.lock()
        defer { lock.unlock() }

        guard let index = outbox.changes.firstIndex(where: { $0.id == change.id }) else {
            return nil
        }

        var updated = change
        updated.revision = outbox.changes[index].revision + 1
        outbox.changes[index] = updated
        saveOutbox()
        return updated
    }

    /// Saves what sending found out about a change, unless the user edited it since it was read.
    @discardableResult
    func updateIfUnchanged(_ change: Change) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let index = outbox.changes.firstIndex(where: { $0.id == change.id && $0.revision == change.revision }) else {
            return false
        }

        outbox.changes[index] = change
        saveOutbox()
        return true
    }

    func remove(_ id: Int) {
        lock.lock()
        defer { lock.unlock() }

        outbox.changes.removeAll { $0.id == id }
        saveOutbox()
    }

    /// Removes a change that was sent, unless the user edited it while it was on its way.
    @discardableResult
    func removeIfUnchanged(_ change: Change) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard let index = outbox.changes.firstIndex(where: { $0.id == change.id && $0.revision == change.revision }) else {
            return false
        }

        outbox.changes.remove(at: index)
        saveOutbox()
        return true
    }

    /// Remembers what the server got for a change, in case an add or edit screen is still open on it.
    func markSent(_ change: Change, transactionId: String?, serverCopy: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        outbox.sent.removeAll { $0.changeId == change.id || now.timeIntervalSince($0.sentAt) > Self.sentKept }
        outbox.sent.append(Sent(changeId: change.id, serverId: change.serverId, transactionId: transactionId,
                                serverCopyText: serverCopy.flatMap(Self.text), sentAt: now))
        saveOutbox()
    }

    /// What the server got for a change that is no longer waiting, or nil when it wasn't sent (it was discarded).
    func sent(_ changeId: Int) -> Sent? {
        lock.lock()
        defer { lock.unlock() }

        return outbox.sent.first { $0.changeId == changeId }
    }

    func removeAll(serverId: String) {
        lock.lock()
        defer { lock.unlock() }

        outbox.changes.removeAll { $0.serverId == serverId }
        outbox.sent.removeAll { $0.serverId == serverId }
        saveOutbox()
    }

    /// All changes, oldest first, which is the order they are sent in.
    func allChanges() -> [Change] {
        lock.lock()
        defer { lock.unlock() }

        return outbox.changes
    }

    func changes(serverId: String) -> [Change] {
        allChanges().filter { $0.serverId == serverId }
    }

    /// One user's changes for a server, oldest first.
    func changes(serverId: String, userName: String) -> [Change] {
        allChanges().filter { $0.serverId == serverId && $0.userName == userName }
    }

    func change(_ id: Int) -> Change? {
        allChanges().first { $0.id == id }
    }

    /// The user's change waiting for one of the server's transactions, if any.
    func changeFor(serverId: String, userName: String, transactionId: String) -> Change? {
        allChanges().first { $0.serverId == serverId && $0.userName == userName && $0.transactionId == transactionId }
    }

    /// Called with the lock held.
    private func saveOutbox() {
        if let data = try? JSONEncoder().encode(outbox) {
            try? data.write(to: folder.appendingPathComponent("outbox.json"), options: .atomic)
        }
    }

    // MARK: - JSON text

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    static func text(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }

        return String(decoding: data, as: UTF8.self)
    }
}
