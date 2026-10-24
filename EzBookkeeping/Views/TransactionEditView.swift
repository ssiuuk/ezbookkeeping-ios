import SwiftUI

/// Opens the add or edit form for the server in use.
struct TransactionEditView: View {
    let target: EditorTarget

    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let server = appState.activeServer {
            TransactionEditForm(target: target, server: server)
        } else {
            Text("Not signed in")
        }
    }
}

/// The choice lists the form opens.
enum EditSheet: Identifiable {
    case book
    case category
    case account(destination: Bool)
    case project
    case merchant
    case tags

    var id: String {
        switch self {
        case .book: return "book"
        case .category: return "category"
        case .account(let destination): return destination ? "destination" : "account"
        case .project: return "project"
        case .merchant: return "merchant"
        case .tags: return "tags"
        }
    }
}

struct TransactionEditForm: View {
    @StateObject private var model: TransactionEditModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sheet: EditSheet?
    @FocusState private var amountFocused: Bool

    init(target: EditorTarget, server: Server) {
        _model = StateObject(wrappedValue: TransactionEditModel(target: target, server: server))
    }

    var body: some View {
        NavigationStack {
            Group {
                if let route = model.webFallbackRoute {
                    WebPageView(server: model.server, route: route, signInMode: false, onClose: {
                        dismiss()
                    }, onSignInRejected: {}, onSignedIn: { _, _ in })
                } else {
                    form
                }
            }
            .navigationTitle(model.isEditing ? "Edit transaction" : "Add transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("cancel_button")
                }

                ToolbarItem(placement: .confirmationAction) {
                    if model.webFallbackRoute == nil {
                        Button("Save") {
                            amountFocused = false
                            Task {
                                await model.save()
                            }
                        }
                        .disabled(model.saving || model.loading)
                        .accessibilityIdentifier("save_button")
                    }
                }

                // the decimal pad has no return key, so give the keyboard a way to close
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button("Done") {
                        amountFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .accessibilityIdentifier("keyboard_done")
                }
            }
        }
        .interactiveDismissDisabled(model.saving)
        .task {
            await model.start()

            if !model.isEditing {
                amountFocused = true
            }
        }
        .onChange(of: model.finished) { _, finished in
            if finished {
                if model.changedData {
                    appState.dataChanged()
                }

                dismiss()
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .book:
                BookPickerSheet(model: model)
            case .category:
                CategoryPickerSheet(model: model)
            case .account(let destination):
                AccountPickerSheet(model: model, destination: destination)
            case .project:
                ProjectPickerSheet(model: model)
            case .merchant:
                MerchantPickerSheet(model: model)
            case .tags:
                TagsPickerSheet(model: model)
            }
        }
        .alert(model.alert?.title ?? "", isPresented: Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        ), presenting: model.alert) { alert in
            switch alert {
            case .message:
                Button("OK", role: .cancel) {}
            case .loadFailed:
                Button("Retry") {
                    Task {
                        await model.loadBookData()
                    }
                }
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
            case .moveIncomplete:
                Button("OK", role: .cancel) {
                    model.finish()
                }
            case .confirmDelete:
                Button("Delete", role: .destructive) {
                    Task {
                        await model.delete()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        } message: { alert in
            Text(alert.text)
        }
    }

    /// Photos can't be added or removed in this app yet; the ones a transaction has stay attached.
    private var photosText: String {
        model.pictureCount == 1 ? "1 photo, kept as it is" : "\(model.pictureCount) photos, kept as they are"
    }

    private var isTransfer: Bool {
        model.type == TransactionType.transfer
    }

    private var form: some View {
        Form {
            if model.canChooseBook {
                Section {
                    ChoiceRow(title: "Book", value: model.bookText, identifier: "book") {
                        sheet = .book
                    }
                } footer: {
                    if model.isEditing && model.bookId != model.originalBookId {
                        Text("Saving moves this transaction to \(model.bookText).")
                    }
                }
            }

            Section {
                Picker("Type", selection: Binding(get: { model.type }, set: { model.setType($0) })) {
                    Text("Expense").tag(TransactionType.expense)
                    Text("Income").tag(TransactionType.income)
                    Text("Transfer").tag(TransactionType.transfer)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("type")

                HStack {
                    TextField("Amount", text: $model.amountText)
                        .keyboardType(.decimalPad)
                        .font(.title2.monospacedDigit())
                        .focused($amountFocused)
                        .accessibilityIdentifier("amount")
                        .onChange(of: model.amountText) { _, _ in
                            model.errors.remove(.amount)
                        }

                    Text(model.account?.currency ?? "")
                        .foregroundStyle(.secondary)
                }

                if model.errors.contains(.amount) {
                    ErrorText("Enter an amount")
                }
            }

            Section {
                ChoiceRow(title: "Category", value: model.categoryText, identifier: "category", invalid: model.errors.contains(.category)) {
                    sheet = .category
                }

                ChoiceRow(title: isTransfer ? "From account" : "Account", value: model.account?.name ?? "", identifier: "account",
                          invalid: model.errors.contains(.account)) {
                    sheet = .account(destination: false)
                }

                if isTransfer {
                    ChoiceRow(title: "To account", value: model.destinationAccount?.name ?? "", identifier: "destination_account",
                              invalid: model.errors.contains(.destinationAccount)) {
                        sheet = .account(destination: true)
                    }
                }

                if model.showsDestinationAmount {
                    HStack {
                        TextField("Received amount", text: $model.destinationAmountText)
                            .keyboardType(.decimalPad)
                            .accessibilityIdentifier("destination_amount")
                        Text(model.destinationAccount?.currency ?? "")
                            .foregroundStyle(.secondary)
                    }

                    if model.errors.contains(.destinationAmount) {
                        ErrorText("Enter an amount")
                    }
                }
            }

            Section {
                DatePicker("Time", selection: $model.time)
                    .accessibilityIdentifier("time")

                if model.showsProject {
                    ChoiceRow(title: "Project", value: model.projectText, identifier: "project") {
                        sheet = .project
                    }
                }

                if model.showsMerchant {
                    ChoiceRow(title: "Merchant", value: model.merchant, identifier: "merchant") {
                        sheet = .merchant
                    }
                }

                ChoiceRow(title: "Tags", value: model.tagsText, identifier: "tags") {
                    sheet = .tags
                }

                TextField("Description", text: $model.comment, axis: .vertical)
                    .lineLimit(1...4)
                    .accessibilityIdentifier("comment")

                if model.pictureCount > 0 {
                    Label(photosText, systemImage: "photo")
                        .foregroundStyle(.secondary)
                }
            }

            if model.isEditing {
                Section {
                    Button("Delete", role: .destructive) {
                        model.alert = .confirmDelete
                    }
                    .accessibilityIdentifier("delete_button")
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .disabled(model.saving)
        .overlay {
            if model.loading || model.saving {
                ProgressView()
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }
}

/// A form row that opens a choice list, showing the current choice on the right.
struct ChoiceRow: View {
    let title: String
    let value: String
    let identifier: String
    var invalid = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(invalid ? Color.red : Color.primary)
                Spacer(minLength: 12)
                Text(value.isEmpty ? (invalid ? "Required" : "Choose") : value)
                    .foregroundStyle(value.isEmpty ? (invalid ? Color.red : Color.secondary) : Color.primary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

struct ErrorText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
    }
}
