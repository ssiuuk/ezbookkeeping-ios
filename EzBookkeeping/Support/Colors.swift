import SwiftUI

extension Color {
    /// A color the server stores as six hex digits, such as "ff6b22", or nil when it isn't one.
    init?(hex: String) {
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    static let income = Color(red: 0.18, green: 0.62, blue: 0.29)
    static let expense = Color(red: 0.86, green: 0.25, blue: 0.22)

    /// Green for income, red for expense, the normal text color for anything else.
    static func amount(forType type: Int) -> Color {
        switch type {
        case TransactionType.income:
            return .income
        case TransactionType.expense:
            return .expense
        default:
            return .primary
        }
    }
}
