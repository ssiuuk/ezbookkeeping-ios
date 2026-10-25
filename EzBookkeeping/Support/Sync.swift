import Foundation

/// Sends the transactions added, changed or deleted while the server was out of reach, oldest first, once it answers
/// again, like the Android app's Sync. A change to a transaction that was also changed on the server meanwhile is held
/// back as a conflict for the user to settle.
@MainActor
enum Sync {
    // the server's error for a transaction that doesn't exist (any more)
    static let transactionNotFound = 205001
    // the server may move a transaction's time by a few seconds when another one has the same second
    private static let sameTimeSeconds: Int64 = 120
    // passes over the outbox in one run, for changes that sending itself creates (a deletion of an add removed meanwhile)
    private static let maxPasses = 5
    nonisolated private static let compared = ["type", "categoryId", "sourceAccountId", "sourceAmount", "comment", "merchant", "projectId"]

    /// Called after changes were sent, held back or settled, so the screens can show the server's figures again.
    static var onChange: (@MainActor () -> Void)?
    /// Called after a change is saved on the phone, so it is sent as soon as possible.
    static var onQueued: (@MainActor () -> Void)?

    private static var running = false

    nonisolated static var store: LocalStore {
        LocalStore.shared
    }

    /// The signed-in user's changes for a server, oldest first.
    nonisolated static func changes(_ server: Server) -> [LocalStore.Change] {
        store.changes(serverId: server.id, userName: server.userName)
    }

    /// The signed-in user's change waiting for one of the server's transactions, if any.
    nonisolated static func changeFor(_ server: Server, transactionId: String) -> LocalStore.Change? {
        store.changeFor(serverId: server.id, userName: server.userName, transactionId: transactionId)
    }

    nonisolated static var hasWaiting: Bool {
        store.allChanges().contains { $0.isWaiting }
    }

    // MARK: - Saving on the phone

    /// Saves a transaction added, changed or deleted while the server couldn't be reached. A later change to the same
    /// transaction replaces the earlier one but keeps the server's version it started from.
    @discardableResult
    static func queue(_ server: Server, bookId: String?, kind: LocalStore.Kind, transactionId: String?,
                      body: [String: Any], base: [String: Any]?, labels: [String: String]) -> LocalStore.Change {
        var change = transactionId.flatMap { changeFor(server, transactionId: $0) }
            ?? LocalStore.Change(serverId: server.id, userName: server.userName, kind: kind, transactionId: transactionId,
                                 bodyText: "{}", baseText: base.flatMap(LocalStore.text))
        change.bookId = bookId
        change.kind = kind
        change.body = body
        change.labels = labels
        change.state = .waiting
        change.message = nil
        change.serverCopy = nil

        if change.id != 0, let updated = store.update(change) {
            change = updated
        } else {
            change.id = 0
            change = store.insert(change)
        }

        changed()
        onQueued?()
        return change
    }

    /// Saves the user's new version of a change opened in the add form. If it was sent while the form was open, the new
    /// version becomes a change to the transaction the server made of it, so nothing typed is lost and nothing is added twice.
    @discardableResult
    static func saveEdit(_ server: Server, change original: LocalStore.Change, body: [String: Any],
                         labels: [String: String]) -> LocalStore.Change {
        var change = original
        change.body = body
        change.labels = labels
        change.state = .waiting
        change.message = nil
        change.serverCopy = nil
        change.attempts = 0

        if let updated = store.update(change) {
            changed()
            onQueued?()
            return updated
        }

        var newBody = body

        if let sent = store.sent(change.id) {
            if let serverCopy = sent.serverCopy, let transactionId = sent.transactionId {
                // sent while the form was open: the edit changes the transaction the server has
                newBody.removeValue(forKey: "clientSessionId")
                newBody["id"] = transactionId
                return queue(server, bookId: change.bookId, kind: .modify, transactionId: transactionId, body: newBody,
                             base: serverCopy, labels: labels)
            }

            // it turned out to be deleted on the server: the edit is added back
            newBody.removeValue(forKey: "id")
            newBody["clientSessionId"] = UUID().uuidString
            return queue(server, bookId: change.bookId, kind: .add, transactionId: nil, body: newBody, base: nil, labels: labels)
        }

        // settled meanwhile by keeping the server's version, but the user saved theirs again, so theirs is sent
        return queue(server, bookId: change.bookId, kind: change.kind, transactionId: change.transactionId, body: body,
                     base: change.base, labels: labels)
    }

    /// Deletes a change opened in the add form: an add is dropped, anything else is deleted on the server once it answers.
    static func deleteEdit(_ server: Server, change: LocalStore.Change) {
        var transactionId = change.transactionId
        var base = change.base

        if store.change(change.id) == nil {
            // sent while the form was open: delete what the server made of it
            guard let sent = store.sent(change.id), let sentId = sent.transactionId else {
                return
            }

            transactionId = sentId
            base = sent.serverCopy
        } else if change.kind == .add {
            // if it was on its way meanwhile, sending notices it is gone and deletes it again
            store.remove(change.id)
            changed()
            return
        }

        store.remove(change.id)

        if let transactionId {
            queue(server, bookId: change.bookId, kind: .delete, transactionId: transactionId, body: ["id": transactionId],
                  base: base, labels: change.labels)
        }
    }

    /// Settles a conflict, or a change the server refused, with the phone's version: it is sent again.
    static func keepMine(_ original: LocalStore.Change) {
        var change = original

        if change.state == .conflict {
            if change.kind == .add || (change.serverCopy == nil && change.kind == .modify) {
                // added anyway, as a new transaction; or deleted on the server and added back
                change.kind = .add
                change.transactionId = nil
                change.base = nil
                var body = change.body
                body.removeValue(forKey: "id")
                body["clientSessionId"] = UUID().uuidString
                change.body = body
            } else {
                // what the server has now is what the phone's version replaces
                change.base = change.serverCopy
            }
        }

        change.state = .waiting
        change.serverCopy = nil
        change.message = nil
        change.attempts = 0
        change.lastAttemptAt = nil
        _ = store.update(change)
        changed()
        onQueued?()
    }

    /// Settles a conflict with the server's version, or gives up a change the server refused.
    static func keepServers(_ change: LocalStore.Change) {
        store.remove(change.id)
        changed()
    }

    private static func changed() {
        onChange?()
    }

    // MARK: - Sending

    /// A server that can't be reached is tried again later; this says whether everything waiting could be tried.
    @discardableResult
    static func run(servers: [Server]) async -> Bool {
        guard !running else {
            return true
        }

        running = true
        defer { running = false }

        var skipped = Set<String>()
        var complete = true
        var sentSomething = false

        for _ in 0..<maxPasses {
            var sentAny = false

            for change in store.allChanges() where change.isWaiting && !skipped.contains(change.serverId) {
                // removing a server removes its changes, so one without its server isn't in the app (yet)
                guard let server = servers.first(where: { $0.id == change.serverId }) else {
                    continue
                }

                if !server.isSignedIn {
                    // waits until the user signs in again
                    skipped.insert(server.id)
                    continue
                }

                if server.userName != change.userName {
                    // made by another user of this server: waits until they sign in again
                    continue
                }

                do {
                    try await send(change, client: server.client(bookId: change.bookId))
                    sentAny = true
                } catch let error as APIError {
                    if error.unreachable {
                        // later changes may depend on this one, so the rest of this server's changes wait too
                        skipped.insert(server.id)
                        complete = false
                    } else if error.isUnauthorized {
                        skipped.insert(server.id)
                    } else {
                        var failed = change
                        failed.state = .failed
                        failed.message = error.localizedDescription
                        store.updateIfUnchanged(failed)
                        sentAny = true
                    }
                } catch {
                    skipped.insert(server.id)
                    complete = false
                }
            }

            sentSomething = sentSomething || sentAny

            if !sentAny {
                break
            }
        }

        if sentSomething {
            changed()
        }

        return complete
    }

    /// Sends one change. Every write checks that the user didn't edit it meanwhile, since the add form may be open on it.
    static func send(_ original: LocalStore.Change, client: APIClient) async throws {
        var change = original

        switch change.kind {
        case .add:
            // an earlier try may have reached the server even though no answer came back. The server's duplicate check
            // on clientSessionId can't be relied on (it expires, can be turned off and is lost on a restart), so when a
            // transaction like this one is there, it may be this one or a separate purchase, and the user decides.
            if change.attempts > 0, let similar = try await findSimilar(client, body: change.body) {
                conflict(change, serverCopy: similar)
                return
            }

            change.attempts += 1
            change.lastAttemptAt = Date()

            guard store.updateIfUnchanged(change) else {
                // edited meanwhile; the newer version goes in the next round
                return
            }

            let added = try await client.post("v1/transactions/add.json", body: change.body) as? [String: Any]
            let transactionId = added.map { JSONObject($0).string("id") }.flatMap { $0.isEmpty ? nil : $0 }
            store.markSent(change, transactionId: transactionId, serverCopy: added)

            if !store.removeIfUnchanged(change), let transactionId {
                if var latest = store.change(change.id) {
                    // edited while it was on its way: the newer version changes the transaction the server just made
                    latest.kind = .modify
                    latest.transactionId = transactionId
                    latest.base = added
                    var body = latest.body
                    body.removeValue(forKey: "clientSessionId")
                    body["id"] = transactionId
                    latest.body = body
                    latest.attempts = 0
                    store.updateIfUnchanged(latest)
                } else {
                    // deleted on the phone while it was on its way: delete it on the server too
                    var deletion = LocalStore.Change(serverId: change.serverId, userName: change.userName, kind: .delete,
                                                     transactionId: transactionId, bodyText: "{}")
                    deletion.bookId = change.bookId
                    deletion.body = ["id": transactionId]
                    deletion.base = added
                    deletion.labels = change.labels
                    store.insert(deletion)
                }
            }

        case .modify:
            guard let transactionId = change.transactionId else {
                store.remove(change.id)
                return
            }

            let current = try await fetch(client, transactionId: transactionId)

            if let current {
                if same(current, change.body) {
                    store.markSent(change, transactionId: transactionId, serverCopy: current)
                    store.removeIfUnchanged(change)
                } else if let base = change.base, !same(current, base) {
                    conflict(change, serverCopy: current)
                } else {
                    let modified = try await client.post("v1/transactions/modify.json", body: change.body) as? [String: Any]
                    store.markSent(change, transactionId: transactionId, serverCopy: modified)

                    if !store.removeIfUnchanged(change), var latest = store.change(change.id), let modified {
                        // edited while it was on its way: the newer version changes what the server has now
                        latest.base = modified
                        store.updateIfUnchanged(latest)
                    }
                }
            } else {
                conflict(change, serverCopy: nil)
            }

        case .delete:
            guard let transactionId = change.transactionId else {
                store.remove(change.id)
                return
            }

            let current = try await fetch(client, transactionId: transactionId)

            if let current {
                if let base = change.base, !same(current, base) {
                    conflict(change, serverCopy: current)
                } else {
                    try await client.post("v1/transactions/delete.json", body: ["id": transactionId])
                    store.markSent(change, transactionId: transactionId, serverCopy: nil)
                    store.removeIfUnchanged(change)
                }
            } else {
                // already gone
                store.markSent(change, transactionId: transactionId, serverCopy: nil)
                store.removeIfUnchanged(change)
            }
        }
    }

    private static func conflict(_ original: LocalStore.Change, serverCopy: [String: Any]?) {
        var change = original
        change.state = .conflict
        change.serverCopy = serverCopy
        change.message = nil
        store.updateIfUnchanged(change)
    }

    /// The server's version of a transaction, or nil when it no longer has it.
    private static func fetch(_ client: APIClient, transactionId: String) async throws -> [String: Any]? {
        do {
            return try await client.get("v1/transactions/get.json", query: [
                ("id", transactionId), ("trim_account", "false"), ("trim_category", "false"), ("trim_tag", "false"),
            ]) as? [String: Any]
        } catch let error as APIError where error.errorCode == transactionNotFound {
            return nil
        }
    }

    /// A transaction on the server that says the same as this new one, at about the same time, or nil.
    private static func findSimilar(_ client: APIClient, body: [String: Any]) async throws -> [String: Any]? {
        let time = JSONObject(body).int64("time")
        let date = Date(timeIntervalSince1970: TimeInterval(time))
        let parts = Calendar.current.dateComponents([.year, .month], from: date)
        let result = try await client.get("v1/transactions/list/by_month.json", query: [
            ("year", String(parts.year ?? 0)), ("month", String(parts.month ?? 0)), ("type", value(body, "type")),
            ("trim_account", "true"), ("trim_category", "true"), ("trim_tag", "true"),
        ])

        for item in JSONObject(result).objects("items") {
            if abs(item.int64("time") - time) <= sameTimeSeconds, same(item.raw, body, exactTime: false) {
                return item.raw
            }
        }

        return nil
    }

    // MARK: - Comparing versions

    /// Whether two versions of a transaction say the same: what this app shows and edits, and what it sends without
    /// showing (photos, hidden amount, time zone and location). Either may be the server's JSON or what is sent.
    nonisolated static func same(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        same(a, b, exactTime: true)
    }

    nonisolated private static func same(_ a: [String: Any], _ b: [String: Any], exactTime: Bool) -> Bool {
        for key in compared where value(a, key) != value(b, key) {
            return false
        }

        if JSONObject(a).int("type") == TransactionType.transfer
            && (value(a, "destinationAccountId") != value(b, "destinationAccountId")
                || value(a, "destinationAmount") != value(b, "destinationAmount")) {
            return false
        }

        if tagIds(a) != tagIds(b) {
            return false
        }

        if !exactTime {
            // a list of the month only has the fields above
            return true
        }

        return value(a, "time") == value(b, "time")
            && pictureIds(a) == pictureIds(b)
            && JSONObject(a).bool("hideAmount") == JSONObject(b).bool("hideAmount")
            && JSONObject(a).int("utcOffset") == JSONObject(b).int("utcOffset")
            && geoLocation(a) == geoLocation(b)
    }

    /// The fields that differ, in the order the add form shows them.
    nonisolated static func differences(_ mine: [String: Any], _ servers: [String: Any]) -> [String] {
        var keys: [String] = []
        let transfer = JSONObject(mine).int("type") == TransactionType.transfer

        for key in ["type", "sourceAmount", "destinationAmount", "categoryId", "sourceAccountId", "destinationAccountId",
                    "time", "projectId", "merchant", "comment"] {
            if key.hasPrefix("destination") && !transfer {
                continue
            }

            if value(mine, key) != value(servers, key) {
                keys.append(key)
            }
        }

        if tagIds(mine) != tagIds(servers) {
            keys.append("tagIds")
        }

        if pictureIds(mine) != pictureIds(servers) {
            keys.append("pictureIds")
        }

        if JSONObject(mine).bool("hideAmount") != JSONObject(servers).bool("hideAmount") || geoLocation(mine) != geoLocation(servers) {
            keys.append("other")
        }

        return keys
    }

    nonisolated private static func value(_ json: [String: Any], _ key: String) -> String {
        let fallback = key.hasSuffix("Id") || key.hasSuffix("Amount") ? "0" : ""
        let text = JSONObject(json).string(key, fallback).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? fallback : text
    }

    /// Photo ids, from what is sent ("pictureIds") or from the server's "pictures".
    nonisolated private static func pictureIds(_ json: [String: Any]) -> [String] {
        let object = JSONObject(json)

        if let sent = object.array("pictureIds") {
            return sent.map { "\($0)" }.sorted()
        }

        return object.objects("pictures").map { $0.string("pictureId") }.sorted()
    }

    nonisolated private static func geoLocation(_ json: [String: Any]) -> String {
        guard let location = JSONObject(json).object("geoLocation") else {
            return ""
        }

        return "\(location.raw["latitude"] ?? 0),\(location.raw["longitude"] ?? 0)"
    }

    nonisolated private static func tagIds(_ json: [String: Any]) -> [String] {
        (JSONObject(json).array("tagIds") ?? []).map { "\($0)" }.sorted()
    }
}
