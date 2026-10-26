import AppIntents
import Foundation

/// Puts a purchase on the To review list. Meant for a Shortcuts automation: Automation → Wallet
/// ("When I tap any of my cards") → this action, with the automation's Merchant, Amount and Card.
/// iOS doesn't let apps read Wallet's notifications, which is how the Android app sees purchases.
struct AddPurchaseToReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a purchase to review"
    static var description = IntentDescription(
        "Puts a purchase on ezBookkeeping's To review list, for example from an Apple Pay automation. Open the app to save it as a transaction.")
    static var openAppWhenRun = false

    @Parameter(title: "Amount", description: "The amount with its currency, like £4.50.")
    var amount: String

    @Parameter(title: "Merchant")
    var merchant: String?

    @Parameter(title: "Card", description: "The card or pass it was paid with.")
    var card: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$merchant) to review") {
            \.$card
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let purchase = Purchase.from(merchant: merchant ?? "", amount: amount, card: card ?? "") else {
            throw PurchaseIntentError.unreadableAmount(amount)
        }

        PendingPurchases.add(purchase, source: "shortcuts")
        if purchase.merchant.isEmpty {
            return .result(dialog: "Added \(amount) to To review.")
        }

        return .result(dialog: "Added \(amount) at \(purchase.merchant) to To review.")
    }
}

/// Reads a purchase out of a payment message, such as a bank's text or email, and puts it on the To review list.
struct AddPaymentMessageToReviewIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a payment message to review"
    static var description = IntentDescription(
        "Reads the amount, shop and card from a payment message, like \"£4.50 at Corner Café with Visa •••• 1234\", and puts it on the To review list.")
    static var openAppWhenRun = false

    @Parameter(title: "Message")
    var message: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add the payment in \(\.$message) to review")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let lines = message.split(whereSeparator: \.isNewline).map(String.init)
        let title = lines.count > 1 ? lines[0] : ""
        let text = lines.count > 1 ? lines.dropFirst().joined(separator: " ") : message

        guard let purchase = Purchase.parse(title: title, text: text) else {
            throw PurchaseIntentError.notAPayment
        }

        PendingPurchases.add(purchase, source: "message")
        return .result(dialog: "Added to To review.")
    }
}

enum PurchaseIntentError: Error, CustomLocalizedStringResourceConvertible {
    case unreadableAmount(String)
    case notAPayment

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unreadableAmount(let amount):
            return "\"\(amount)\" doesn't look like an amount."
        case .notAPayment:
            return "This message doesn't look like a payment."
        }
    }
}

struct EzBookkeepingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddPurchaseToReviewIntent(),
                    phrases: ["Add a purchase to \(.applicationName)", "Add a purchase to review in \(.applicationName)"],
                    shortTitle: "Add a purchase",
                    systemImageName: "creditcard")
    }
}
