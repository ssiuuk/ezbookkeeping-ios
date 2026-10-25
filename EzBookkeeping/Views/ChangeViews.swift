import SwiftUI

/// How a transaction saved on this phone but not yet on the server shows in a list, and what tapping it asks,
/// as in the Android app's ChangeViews.
enum ChangeText {
    /// The change as a transaction, with the names saved alongside it since the lists of accounts may be out of reach.
    static func record(of change: LocalStore.Change) -> TransactionRecord {
        let deleting = change.kind == .delete && change.base != nil
        var record = TransactionRecord(json: JSONObject(deleting ? change.base : change.body))

        if !deleting {
            record.categoryName = change.label("category")
            record.sourceAccountName = change.label("account")
            record.sourceCurrency = change.label("currency")
            record.destinationAccountName = change.label("destinationAccount")
            record.destinationCurrency = change.label("destinationCurrency")
        }

        record.id = change.transactionId ?? ""
        return record
    }

    static func state(_ change: LocalStore.Change) -> String {
        switch change.state {
        case .conflict:
            if change.kind == .add {
                return String(localized: "May already be on the server")
            }

            return change.serverCopy == nil ? String(localized: "Deleted on the server") : String(localized: "Also changed on the server")
        case .failed:
            return String(localized: "The server didn't accept it")
        case .waiting:
            return change.kind == .delete ? String(localized: "Waiting to be deleted") : String(localized: "Waiting to be sent")
        }
    }

    /// One line for each field that differs, such as "Amount: yours £12.00, the server's £15.00".
    static func differenceLines(_ first: TransactionRecord, _ firstJSON: [String: Any], _ second: TransactionRecord,
                                _ secondJSON: [String: Any], wasNow: Bool) -> String {
        var lines: [String] = []
        var otherFields = false

        for key in Sync.differences(firstJSON, secondJSON) {
            guard let label = label(of: key, type: first.type) else {
                otherFields = true
                continue
            }

            let mine = display(key, first)
            let servers = display(key, second)
            lines.append(wasNow ? String(localized: "\(label): was \(mine), now \(servers)")
                                : String(localized: "\(label): yours \(mine), the server's \(servers)"))
        }

        if otherFields {
            lines.append(String(localized: "Other details (project, tags, receipts or location) differ too."))
        }

        return lines.joined(separator: "\n")
    }

    private static func label(of key: String, type: Int) -> String? {
        switch key {
        case "type": return String(localized: "Type")
        case "sourceAmount": return String(localized: "Amount")
        case "destinationAmount": return String(localized: "Received amount")
        case "categoryId": return String(localized: "Category")
        case "sourceAccountId": return type == TransactionType.transfer ? String(localized: "From account") : String(localized: "Account")
        case "destinationAccountId": return String(localized: "To account")
        case "time": return String(localized: "Date")
        case "merchant": return String(localized: "Merchant")
        case "comment": return String(localized: "Description")
        // projects and tags are only known by id here
        default: return nil
        }
    }

    private static func display(_ key: String, _ record: TransactionRecord) -> String {
        let text: String

        switch key {
        case "type":
            text = record.type == TransactionType.income ? String(localized: "Income")
                : record.type == TransactionType.transfer ? String(localized: "Transfer") : String(localized: "Expense")
        case "sourceAmount":
            text = Formats.amount(record.sourceAmount, currency: record.sourceCurrency)
        case "destinationAmount":
            text = Formats.amount(record.destinationAmount, currency: record.destinationCurrency)
        case "categoryId":
            text = record.categoryName
        case "sourceAccountId":
            text = record.sourceAccountName
        case "destinationAccountId":
            text = record.destinationAccountName
        case "time":
            text = Formats.dayHeader(record.date) + " " + Formats.time(record.date)
        case "merchant":
            text = record.merchant
        default:
            text = record.comment
        }

        return text.isEmpty ? "—" : text
    }
}

/// A question about a change saved on the phone, with the buttons that settle it.
struct ChangeDecision: Identifiable {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        var role: ButtonRole?
        let run: () -> Void
    }

    let id = UUID()
    let title: String
    let message: String
    let actions: [Action]

    /// What tapping a change asks, or nil when it simply opens in the add form.
    @MainActor
    static func forChange(_ change: LocalStore.Change, edit: @escaping () -> Void) -> ChangeDecision? {
        let keepMine = Action(title: String(localized: "Keep mine")) { Sync.keepMine(change) }
        let keepServers = Action(title: String(localized: "Keep the server's")) { Sync.keepServers(change) }

        switch change.state {
        case .conflict:
            let title = String(localized: "Which version should stay?")

            if change.kind == .add {
                // the server has one like it, which may be this one sent earlier without an answer, or a separate purchase
                return ChangeDecision(title: title, message: String(localized: "The server already has a transaction like this one, at about the same time. It may be this one, sent earlier when no answer came back, or a separate one."), actions: [
                    Action(title: String(localized: "Add it anyway")) { Sync.keepMine(change) },
                    Action(title: String(localized: "Don't add it"), role: .destructive) { Sync.keepServers(change) },
                ])
            }

            guard let serverCopy = change.serverCopy else {
                // changed here, deleted there
                return ChangeDecision(title: title, message: String(localized: "This transaction was deleted on the server after you changed it on this phone."), actions: [
                    Action(title: String(localized: "Add mine back")) { Sync.keepMine(change) },
                    Action(title: String(localized: "Leave it deleted"), role: .destructive) { Sync.keepServers(change) },
                ])
            }

            let server = TransactionRecord(json: JSONObject(serverCopy))

            if change.kind == .delete {
                // deleted here, changed there
                var message = String(localized: "You deleted this transaction on this phone, but it was changed on the server since.")

                if let base = change.base {
                    message += "\n\n" + ChangeText.differenceLines(TransactionRecord(json: JSONObject(base)), base, server, serverCopy, wasNow: true)
                }

                return ChangeDecision(title: title, message: message, actions: [
                    Action(title: String(localized: "Delete"), role: .destructive) { Sync.keepMine(change) },
                    Action(title: String(localized: "Keep it")) { Sync.keepServers(change) },
                ])
            }

            let message = String(localized: "This transaction was also changed on the server after you changed it on this phone.") + "\n\n"
                + ChangeText.differenceLines(ChangeText.record(of: change), change.body, server, serverCopy, wasNow: false)
            return ChangeDecision(title: title, message: message, actions: [keepMine, keepServers])

        case .failed:
            var actions = [
                Action(title: String(localized: "Retry")) { Sync.keepMine(change) },
                Action(title: String(localized: "Discard"), role: .destructive) { Sync.keepServers(change) },
            ]

            if change.kind != .delete {
                // fix what the server didn't like, for example an account deleted meanwhile
                actions.insert(Action(title: String(localized: "Edit transaction"), run: edit), at: 0)
            }

            return ChangeDecision(title: String(localized: "The server didn't accept this change"),
                                  message: change.message ?? String(localized: "The server didn't accept it"), actions: actions)

        case .waiting:
            guard change.kind == .delete else {
                return nil
            }

            return ChangeDecision(title: String(localized: "Keep this transaction?"),
                                  message: String(localized: "It was deleted on this phone, and the server hasn't been told yet."), actions: [
                                      Action(title: String(localized: "Keep it")) { Sync.keepServers(change) },
                                  ])
        }
    }
}

/// A transaction saved on the phone, in a list: like any transaction, with its state where the time would be.
struct ChangeRow: View {
    let change: LocalStore.Change

    var body: some View {
        let record = ChangeText.record(of: change)

        HStack(spacing: 12) {
            let title = TransactionText.title(record)
            Avatar(name: title, hexColor: record.categoryColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                    .strikethrough(change.kind == .delete)
                Text(TransactionText.subtitle(record))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(TransactionText.amount(record))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.amount(forType: record.type))
                Text(ChangeText.state(change))
                    .font(.caption)
                    .foregroundStyle(change.isWaiting ? Color.secondary : Color.red)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// Says that the server can't be reached, and how old the figures on screen are.
struct OfflineNote: View {
    /// When the copy on screen was saved; nil when nothing from the server is saved yet.
    let savedAt: Date?

    var body: some View {
        Label {
            if let savedAt {
                Text("Can't reach the server. Showing what it sent at \(Formats.savedAt(savedAt)).")
            } else {
                Text("Can't reach the server, and nothing from it is saved on this phone yet.")
            }
        } icon: {
            Image(systemName: "icloud.slash")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("offline_note")
    }
}
