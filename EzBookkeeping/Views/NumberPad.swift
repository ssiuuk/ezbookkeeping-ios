import SwiftUI

/// The amount fields' keys, shown in place of the phone's keyboard: digits, + − × ÷ for working out a sum, delete (hold
/// it to clear the field) and OK, which shows = while the field holds a sum, like the Android app's and the web app's pads.
struct NumberPad: View {
    /// Whether the field holds a sum, so OK works it out instead of closing the pad.
    let isSum: Bool
    let onKey: (TransactionEditModel.PadKey) -> Void
    /// OK, or = while the field holds a sum.
    let onDone: () -> Void
    /// Closes the pad as it is.
    let onHide: () -> Void

    private let keyHeight: CGFloat = 52
    private let spacing: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()

                Button(action: onHide) {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.body)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                }
                .accessibilityLabel(Text("Done"))
                .accessibilityIdentifier("pad_hide")
            }

            HStack(spacing: spacing) {
                Grid(horizontalSpacing: spacing, verticalSpacing: spacing) {
                    ForEach(["789", "456", "123"], id: \.self) { row in
                        GridRow {
                            ForEach(Array(row), id: \.self) { digit in
                                characterKey(digit)
                            }
                        }
                    }

                    GridRow {
                        characterKey("0")
                            .gridCellColumns(2)
                        characterKey(".")
                    }
                }

                VStack(spacing: spacing) {
                    ForEach(["÷", "×", "−", "+"], id: \.self) { symbol in
                        key(Text(verbatim: symbol), identifier: "operator:" + symbol, style: .operation) {
                            onKey(.operation(symbol))
                        }
                    }
                }

                VStack(spacing: spacing) {
                    key(Text(Image(systemName: "delete.left")), identifier: "key:delete", style: .operation) {
                        onKey(.delete)
                    }
                    .accessibilityLabel(Text("Delete"))
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        onKey(.clear)
                    })

                    Button(action: onDone) {
                        Group {
                            if isSum {
                                Text(verbatim: "=")
                            } else {
                                Text("OK")
                            }
                        }
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: keyHeight * 3 + spacing * 2)
                        .background(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PadButtonStyle())
                    .accessibilityIdentifier("pad_ok")
                }
            }
        }
        .padding(.bottom, spacing)
        .background(Color(.systemGray4))
    }

    private enum KeyStyle {
        case digit
        case operation
    }

    private func characterKey(_ character: Character) -> some View {
        key(Text(verbatim: String(character)), identifier: "key:" + String(character), style: .digit) {
            onKey(.character(character))
        }
    }

    private func key(_ label: Text, identifier: String, style: KeyStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            label
                .font(.title2.monospacedDigit())
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: keyHeight)
                .background(style == .digit ? Color(.systemBackground) : Color(.secondarySystemBackground))
                .contentShape(Rectangle())
        }
        .buttonStyle(PadButtonStyle())
        .accessibilityIdentifier(identifier)
    }
}

/// Darkens a key while it is held, like the system keyboard.
private struct PadButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Color.primary.opacity(configuration.isPressed ? 0.12 : 0))
    }
}
