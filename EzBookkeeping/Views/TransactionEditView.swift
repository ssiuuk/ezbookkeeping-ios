import PhotosUI
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
    /// The amount field the number pad types into, if it is showing.
    @State private var pad: AmountField?
    @State private var photoItem: PhotosPickerItem?
    @State private var takingPhoto = false
    @State private var photoToRemove: TransactionEditModel.Photo?

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
            .navigationTitle(model.pending != nil ? String(localized: "Review purchase") : model.isEditing ? String(localized: "Edit transaction") : String(localized: "Add transaction"))
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
                            closePad()
                            Task {
                                await model.save()
                            }
                        }
                        .disabled(model.saving || model.loading)
                        .accessibilityIdentifier("save_button")
                    }
                }

                // a multi-line description has no key that closes the keyboard
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()

                    Button("Done") {
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
                openPad(.amount)
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
        .fullScreenCover(isPresented: $takingPhoto) {
            CameraPicker { image in
                addPhoto { PhotoProcessing.prepare(image) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { _, item in
            guard let item else {
                return
            }

            photoItem = nil

            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    model.alert = .message(String(localized: "Couldn't read that photo"))
                    return
                }

                addPhoto { PhotoProcessing.prepare(data) }
            }
        }
        .confirmationDialog("Remove this photo?", isPresented: Binding(
            get: { photoToRemove != nil },
            set: { if !$0 { photoToRemove = nil } }
        ), titleVisibility: .visible, presenting: photoToRemove) { photo in
            Button("Remove", role: .destructive) {
                model.removePhoto(photo)
            }
            .accessibilityIdentifier("remove_photo")
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

    /// Shrinks the photo away from the main thread, then shows it and uploads it.
    private func addPhoto(_ prepare: @escaping @Sendable () -> (jpeg: Data, thumbnail: Data?)?) {
        Task {
            let prepared = await Task.detached(priority: .userInitiated) { prepare() }.value

            if let prepared {
                model.addPhoto(jpeg: prepared.jpeg, thumbnail: prepared.thumbnail)
            } else {
                model.alert = .message(String(localized: "Couldn't read that photo"))
            }
        }
    }

    private var isTransfer: Bool {
        model.type == TransactionType.transfer
    }

    private var form: some View {
        ScrollViewReader { proxy in
            amountForm
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let pad {
                        NumberPad(isSum: Formats.isExpression(amountText(pad)), onKey: { key in
                            model.press(key, destination: pad == .destination)
                        }, onDone: {
                            if Formats.isExpression(amountText(pad)) {
                                model.workOutSum(destination: pad == .destination)
                            } else {
                                closePad()
                            }
                        }, onHide: {
                            closePad()
                        })
                        .transition(.move(edge: .bottom))
                    }
                }
                .onChange(of: pad) { _, field in
                    if let field {
                        withAnimation {
                            proxy.scrollTo(field, anchor: .center)
                        }
                    }
                }
        }
        // another field's keyboard, or a list to choose from, takes the pad's place
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            closePad()
        }
        .onChange(of: sheet?.id) { _, which in
            if which != nil {
                closePad()
            }
        }
    }

    private enum AmountField: Hashable {
        case amount
        case destination
    }

    private func amountText(_ field: AmountField) -> String {
        field == .destination ? model.destinationAmountText : model.amountText
    }

    /// Shows the number pad for an amount field, in place of the keyboard.
    private func openPad(_ field: AmountField) {
        if let pad, pad != field {
            model.workOutSum(destination: pad == .destination)
        }

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        withAnimation(.easeOut(duration: 0.2)) {
            pad = field
        }
    }

    /// Hides the number pad, working out a sum left in its field.
    private func closePad() {
        guard let field = pad else {
            return
        }

        model.workOutSum(destination: field == .destination)

        withAnimation(.easeOut(duration: 0.2)) {
            pad = nil
        }
    }

    /// An amount field: tapping it shows the number pad.
    private func amountButton(_ field: AmountField, placeholder: LocalizedStringKey, currency: String, large: Bool,
                              identifier: String) -> some View {
        let text = amountText(field)

        return Button {
            openPad(field)
        } label: {
            HStack {
                Group {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(Color(.placeholderText))
                    } else {
                        Text(verbatim: text)
                            .foregroundStyle(pad == field ? Color.accentColor : Color.primary)
                    }
                }
                .font(large ? .title2.monospacedDigit() : .body.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)

                Spacer()

                Text(currency)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(placeholder))
        .accessibilityValue(Text(verbatim: text))
        .accessibilityIdentifier(identifier)
        .listRowBackground(pad == field ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground))
        .id(field)
    }

    private var amountForm: some View {
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

                amountButton(.amount, placeholder: "Amount", currency: model.account?.currency ?? "", large: true,
                             identifier: "amount")
                    .onChange(of: model.amountText) { _, _ in
                        model.errors.remove(.amount)
                    }

                if let sum = model.sumPreview(destination: false) {
                    Text(sum)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("amount_sum")
                }

                if model.errors.contains(.amount) {
                    ErrorText("Enter an amount")
                }
            } footer: {
                if let note = model.pendingNote {
                    Text(note)
                        .accessibilityIdentifier("pending_note")
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
                    amountButton(.destination, placeholder: "Received amount",
                                 currency: model.destinationAccount?.currency ?? "", large: false, identifier: "destination_amount")

                    if let sum = model.sumPreview(destination: true) {
                        Text(sum)
                            .font(.subheadline.monospacedDigit())
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

            }

            if model.showsPhotos {
                photosSection
            }

            if model.pending != nil {
                Section {
                    Button("Dismiss purchase", role: .destructive) {
                        model.dismissPending()
                    }
                    .accessibilityIdentifier("dismiss_purchase")
                } footer: {
                    Text("Takes it off the To review list without saving it.")
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

extension TransactionEditForm {
    /// Receipts and other photos: thumbnails to tap for removing, and buttons to take or choose one.
    fileprivate var photosSection: some View {
        Section("Photos") {
            if !model.photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.photos) { photo in
                            PhotoThumbnail(photo: photo)
                                .onTapGesture {
                                    if !photo.uploading {
                                        photoToRemove = photo
                                    }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .accessibilityIdentifier("photos")
            }

            if model.photosSupported {
                if CameraPicker.isAvailable {
                    Button {
                        takingPhoto = true
                    } label: {
                        Label("Take photo", systemImage: "camera")
                    }
                    .accessibilityIdentifier("take_photo")
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose photo", systemImage: "photo.on.rectangle")
                }
                .accessibilityIdentifier("choose_photo")
            }
        }
    }
}

/// One photo on the form, dimmed with a spinner while it uploads.
struct PhotoThumbnail: View {
    let photo: TransactionEditModel.Photo

    var body: some View {
        ZStack {
            if let data = photo.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.secondarySystemFill)
            }
        }
        .frame(width: 88, height: 88)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(photo.uploading ? 0.5 : 1)
        .overlay {
            if photo.uploading {
                ProgressView()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(photo.uploading ? String(localized: "Photo, uploading") : String(localized: "Photo"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("photo")
    }
}

/// A form row that opens a choice list, showing the current choice on the right.
struct ChoiceRow: View {
    let title: LocalizedStringResource
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
                Text(value.isEmpty ? (invalid ? String(localized: "Required") : String(localized: "Choose")) : value)
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
        .accessibilityLabel(Text(title))
        .accessibilityValue(value)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(identifier)
    }
}

struct ErrorText: View {
    let text: LocalizedStringResource

    init(_ text: LocalizedStringResource) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.red)
    }
}
