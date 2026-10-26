import SwiftUI

/// A round colored badge with the first letter of a name, as the Android app shows for categories and accounts.
struct Avatar: View {
    let name: String
    let hexColor: String

    var body: some View {
        Text(Formats.initial(name))
            .font(.headline)
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color(hex: hexColor) ?? Color.accentColor))
            .accessibilityHidden(true)
    }
}

struct TransactionRow: View {
    let transaction: TransactionRecord
    /// Shown under the amount: the time, or the day on the overview.
    let meta: String

    var body: some View {
        HStack(spacing: 12) {
            let title = TransactionText.title(transaction)
            Avatar(name: title, hexColor: transaction.categoryColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                Text(TransactionText.subtitle(transaction))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(TransactionText.amount(transaction))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.amount(forType: transaction.type))
                Text(meta)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A purchase waiting on the To review list: the shop, the card and the amount.
struct PendingPurchaseRow: View {
    let item: PendingPurchases.Item
    let defaultCurrency: String

    var body: some View {
        HStack(spacing: 12) {
            let title = item.merchant.isEmpty ? String(localized: "Unknown shop") : item.merchant
            Avatar(name: title, hexColor: "")

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(item.card.isEmpty ? String(localized: "Apple Pay") : item.card)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Formats.signedAmount(item.amount, currency: item.currency.isEmpty ? defaultCurrency : item.currency, negative: !item.refund))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.amount(forType: item.refund ? TransactionType.income : TransactionType.expense))
                Text(Formats.dayHeader(item.date) + " " + Formats.time(item.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
