import Foundation

/// How a transaction is described in lists.
enum TransactionText {
    static func title(_ transaction: TransactionRecord) -> String {
        if transaction.type == TransactionType.modifyBalance {
            return "Balance change"
        }

        if !transaction.categoryName.isEmpty {
            return transaction.categoryName
        }

        switch transaction.type {
        case TransactionType.income:
            return "Income"
        case TransactionType.transfer:
            return "Transfer"
        default:
            return "Expense"
        }
    }

    static func subtitle(_ transaction: TransactionRecord) -> String {
        var account = transaction.sourceAccountName

        if transaction.type == TransactionType.transfer && !transaction.destinationAccountName.isEmpty {
            account = account + " → " + transaction.destinationAccountName
        }

        if !transaction.comment.isEmpty {
            return account.isEmpty ? transaction.comment : transaction.comment + " · " + account
        }

        return account
    }

    static func amount(_ transaction: TransactionRecord) -> String {
        if transaction.hideAmount {
            return "•••"
        }

        let currency = transaction.sourceCurrency

        switch transaction.type {
        case TransactionType.income:
            return Formats.signedAmount(transaction.sourceAmount, currency: currency, negative: false)
        case TransactionType.expense:
            return Formats.signedAmount(transaction.sourceAmount, currency: currency, negative: true)
        case TransactionType.modifyBalance:
            return Formats.signedAmount(transaction.sourceAmount, currency: currency, negative: transaction.sourceAmount < 0)
        default:
            return Formats.amount(transaction.sourceAmount, currency: currency)
        }
    }
}

/// What a tap on a transaction or an add button opens.
enum EditorTarget: Identifiable {
    case add(accountId: String?)
    case edit(id: String)
    /// A purchase from the To review list, opened in the add form.
    case review(id: String)
    /// A transaction saved on the phone and not sent to the server yet.
    case change(id: Int)

    var id: String {
        switch self {
        case .add(let accountId):
            return "add-" + (accountId ?? "")
        case .edit(let id):
            return "edit-" + id
        case .review(let id):
            return "review-" + id
        case .change(let id):
            return "change-" + String(id)
        }
    }
}

/// A page of the server's web app to open inside the app.
struct WebPage: Identifiable {
    let title: String
    let route: String

    var id: String {
        route
    }
}
