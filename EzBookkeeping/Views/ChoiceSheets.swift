import SwiftUI

/// One row of a choice list: a name, an optional detail and a check mark on the current choice.
/// UI tests find rows by the identifier "choice:<title>".
struct ChoiceListRow: View {
    let title: String
    var detail: String = ""
    var color: String = ""
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if !color.isEmpty {
                    Circle()
                        .fill(Color(hex: color) ?? Color.accentColor)
                        .frame(width: 12, height: 12)
                }

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                if selected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("choice:" + title)
    }
}

/// A sheet with a title and a Cancel button around a list of choices.
struct ChoiceSheet<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                content()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Book

struct BookPickerSheet: View {
    @ObservedObject var model: TransactionEditModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: Book?

    var body: some View {
        ChoiceSheet(title: "Choose a book") {
            ForEach(model.books) { book in
                ChoiceListRow(title: book.label, selected: model.findBook(model.bookId)?.id == book.id) {
                    choose(book)
                }
            }
        }
        .alert("Move to another book?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Change") {
                if let book = pending {
                    model.switchBook(to: book.isPersonal ? nil : book.id)
                }

                dismiss()
            }
        } message: {
            Text("Each book has its own categories, accounts, tags and projects. Ones with the same name in the other book are picked for you, so check them before saving.")
        }
    }

    private func choose(_ book: Book) {
        let chosen: String? = book.isPersonal ? nil : book.id

        if chosen == model.bookId {
            dismiss()
        } else if model.bookChangeNeedsConfirmation {
            pending = book
        } else {
            model.switchBook(to: chosen)
            dismiss()
        }
    }
}

// MARK: - Category

struct CategoryPickerSheet: View {
    @ObservedObject var model: TransactionEditModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ChoiceSheet(title: "Choose a category") {
            ForEach(model.categoriesOfType) { parent in
                let subs = parent.subCategories.filter { !$0.hidden }

                if !subs.isEmpty {
                    Section(parent.name) {
                        ForEach(subs) { sub in
                            ChoiceListRow(title: sub.name, color: sub.color.isEmpty ? parent.color : sub.color,
                                          selected: model.category?.id == sub.id) {
                                model.choose(category: sub)
                                dismiss()
                            }
                        }
                    }
                }
            }

            Section {
                NavigationLink {
                    CategoryGroupPicker(model: model, onAdded: {
                        dismiss()
                    })
                } label: {
                    Label("Add a category", systemImage: "plus")
                }
                .accessibilityIdentifier("add_category")
            }
        }
    }
}

/// A new category goes in a group, like Restaurants in Food; the group can be new too.
struct CategoryGroupPicker: View {
    @ObservedObject var model: TransactionEditModel
    let onAdded: () -> Void

    @State private var group: TransactionCategory?
    @State private var asking = false
    @State private var newGroup = false
    @State private var groupName = ""
    @State private var name = ""

    var body: some View {
        List {
            ForEach(model.categoriesOfType.filter { !$0.hidden }) { candidate in
                ChoiceListRow(title: candidate.name, color: candidate.color) {
                    ask(group: candidate)
                }
            }

            Button {
                ask(group: nil)
            } label: {
                Label("New group", systemImage: "plus")
            }
            .accessibilityIdentifier("new_category_group")
        }
        .navigationTitle("Add it to which group?")
        .navigationBarTitleDisplayMode(.inline)
        .alert(alertTitle, isPresented: $asking) {
            if newGroup {
                TextField("Group name", text: $groupName)
                    .accessibilityIdentifier("new_group_name")
            }

            TextField("Category name", text: $name)
                .accessibilityIdentifier("new_category_name")

            Button("Cancel", role: .cancel) {}
            Button("Add") {
                add()
            }
        }
    }

    private var alertTitle: String {
        newGroup ? "New category" : "New category in \(group?.name ?? "")"
    }

    private func ask(group: TransactionCategory?) {
        self.group = group
        newGroup = group == nil
        groupName = ""
        name = ""
        asking = true
    }

    private func add() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGroup = groupName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty, !newGroup || !trimmedGroup.isEmpty else {
            model.alert = .message("Enter a name")
            return
        }

        let chosenGroup = group
        let isNewGroup = newGroup

        Task {
            await model.addCategory(name: trimmedName, group: chosenGroup, newGroupName: isNewGroup ? trimmedGroup : nil)
            onAdded()
        }
    }
}

// MARK: - Account

struct AccountPickerSheet: View {
    @ObservedObject var model: TransactionEditModel
    let destination: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ChoiceSheet(title: destination ? "Choose the account to transfer to" : "Choose an account") {
            if model.accounts.isEmpty {
                Text("Create an account first so transactions have somewhere to go.")
                    .foregroundStyle(.secondary)
            }

            ForEach(AccountCategories.grouped(model.accounts)) { group in
                Section(AccountCategories.name(group.category)) {
                    ForEach(group.accounts) { account in
                        ChoiceListRow(title: account.name, detail: Formats.amount(account.balance, currency: account.currency),
                                      color: account.color, selected: current?.id == account.id) {
                            model.choose(account: account, destination: destination)
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private var current: Account? {
        destination ? model.destinationAccount : model.account
    }
}

// MARK: - Project

struct ProjectPickerSheet: View {
    @ObservedObject var model: TransactionEditModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ChoiceSheet(title: "Choose a project") {
            ChoiceListRow(title: "No project", selected: model.findProject(model.projectId) == nil) {
                model.projectId = "0"
                dismiss()
            }

            ForEach(model.projects.filter { !$0.hidden || $0.id == model.projectId }) { project in
                ChoiceListRow(title: project.name, selected: project.id == model.projectId) {
                    model.projectId = project.id
                    dismiss()
                }
            }
        }
    }
}

// MARK: - Merchant

struct MerchantPickerSheet: View {
    @ObservedObject var model: TransactionEditModel
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        ChoiceSheet(title: "Choose a merchant") {
            ChoiceListRow(title: "No merchant", selected: model.merchant.isEmpty) {
                model.choose(merchant: "")
                dismiss()
            }

            ForEach(names, id: \.self) { name in
                ChoiceListRow(title: name, selected: name == model.merchant) {
                    model.choose(merchant: name)
                    dismiss()
                }
            }

            Button {
                newName = ""
                adding = true
            } label: {
                Label("Add a merchant", systemImage: "plus")
            }
            .accessibilityIdentifier("add_merchant")
        }
        .alert("New merchant", isPresented: $adding) {
            TextField("Merchant name", text: $newName)
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("new_merchant_name")
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                model.addMerchant(newName)
                dismiss()
            }
        }
    }

    private var names: [String] {
        var names = model.merchants

        if !model.merchant.isEmpty && !names.contains(model.merchant) {
            names.insert(model.merchant, at: 0)
        }

        return names
    }
}

// MARK: - Tags

struct TagsPickerSheet: View {
    @ObservedObject var model: TransactionEditModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                if visible.isEmpty {
                    Text("No tags")
                        .foregroundStyle(.secondary)
                }

                ForEach(visible) { tag in
                    ChoiceListRow(title: tag.name, selected: selected.contains(tag.id)) {
                        if selected.contains(tag.id) {
                            selected.remove(tag.id)
                        } else {
                            selected.insert(tag.id)
                        }
                    }
                }
            }
            .navigationTitle("Choose tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // keep the order of the tag list
                        model.tagIds = model.tags.map(\.id).filter { selected.contains($0) }
                        dismiss()
                    }
                    .accessibilityIdentifier("tags_done")
                }
            }
        }
        .onAppear {
            selected = Set(model.tagIds)
        }
    }

    private var visible: [Tag] {
        model.tags.filter { !$0.hidden || model.tagIds.contains($0.id) }
    }
}
