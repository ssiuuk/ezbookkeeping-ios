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
