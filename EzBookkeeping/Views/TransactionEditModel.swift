import Combine
import Foundation

/// Adds a new expense, income or transfer, or edits an existing one, in any of the user's books.
/// Mirrors the Android app's TransactionEditActivity: same requests, same remembered accounts,
/// and moving an existing transaction to another book.
@MainActor
final class TransactionEditModel: ObservableObject {
    enum Field: Hashable {
        case amount
        case category
        case account
        case destinationAccount
        case destinationAmount
    }

    enum EditAlert: Identifiable {
        case message(String)
        case loadFailed(String)
        case moveIncomplete(String)
        case confirmDelete

        var id: String {
            switch self {
            case .message(let text): return "message-" + text
            case .loadFailed(let text): return "load-" + text
            case .moveIncomplete(let text): return "move-" + text
            case .confirmDelete: return "delete"
            }
        }

        var title: String {
            switch self {
            case .message: return String(localized: "Something went wrong")
            case .loadFailed: return String(localized: "Unable to reach the server")
            case .moveIncomplete: return String(localized: "Copied, but not moved")
            case .confirmDelete: return String(localized: "Delete this transaction?")
            }
        }

        var text: String {
            switch self {
            case .message(let text), .loadFailed(let text), .moveIncomplete(let text):
                return text
            case .confirmDelete:
                return String(localized: "This can't be undone.")
            }
        }
    }

    /// Why the account was set; only a default or a shop's account gives way to another shop's account.
    enum AccountSource {
        case automatic
        case shop
        case card
        case given
    }

    /// A photo on the form: being uploaded, or already on the server.
    struct Photo: Identifiable, Equatable {
        let id: String
        /// The server's picture id, once uploaded.
        var pictureId: String?
        var url: String?
        /// A small JPEG to show on the form.
        var thumbnail: Data?
        var uploading = false
    }

    /// Choices from the previous book, looked up by name in the new one.
    private struct Carried {
        var categoryName: String?
        var categoryParentName: String?
        var account: Account?
        var accountSource = AccountSource.automatic
        var destinationAccount: Account?
        var tagNames: [String] = []
        var projectName: String?
    }

    // the server's first category icon and a neutral grey, for a group added from the app
    static let newCategoryIcon = "1"
    static let newCategoryColor = "8a8a8a"
    static let maxNameLength = 64

    let target: EditorTarget
    let server: Server
    /// The book an existing transaction is in; saving it in another book moves it there.
    let originalBookId: String?

    @Published private(set) var bookId: String?
    @Published private(set) var books: [Book] = []
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var categoriesByType: [Int: [TransactionCategory]] = [:]
    @Published private(set) var tags: [Tag] = []
    @Published private(set) var merchantsSupported = false
    @Published private(set) var merchants: [String] = []
    @Published private(set) var projectsSupported = false
    @Published private(set) var projects: [Project] = []
    @Published private(set) var original: TransactionRecord?

    @Published private(set) var type = TransactionType.expense
    @Published private(set) var category: TransactionCategory?
    @Published private(set) var account: Account?
    @Published private(set) var destinationAccount: Account?
    @Published var tagIds: [String] = []
    @Published var merchant = ""
    @Published var projectId = "0"
    @Published var time = Date()
    @Published var amountText = ""
    @Published var destinationAmountText = ""
    @Published var comment = ""
    @Published private(set) var photos: [Photo] = []
    /// Whether the server takes photos (its server_settings.js "p" flag).
    @Published private(set) var photosSupported = true
    /// The purchase from the To review list this form saves, if any.
    let pending: PendingPurchases.Item?

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published var errors: Set<Field> = []
    @Published var alert: EditAlert?
    /// Balance changes and read-only transactions open the web page instead.
    @Published private(set) var webFallbackRoute: String?
    /// Set when the screen should close; changedData says whether the lists need to load again.
    @Published private(set) var finished = false
    private(set) var changedData = false

    private var recent: RecentChoices
    private var accountChosen = false
    private(set) var accountSource = AccountSource.automatic
    private var destinationChosen = false
    private var originalApplied = false
    private var started = false
    private var loadGeneration = 0
    private var carried: Carried?
    private let clientSessionId = UUID().uuidString

    init(target: EditorTarget, server: Server) {
        self.target = target
        self.server = server

        if case .review(let id) = target {
            pending = PendingPurchases.get(id)
        } else {
            pending = nil
        }

        // a transaction saved on the phone and not sent yet is edited in its phone version, which is newer
        var queued: LocalStore.Change?
        var serverTransactionId: String?

        switch target {
        case .change(let id):
            if let change = LocalStore.shared.change(id) {
                queued = change
                serverTransactionId = change.transactionId
            } else {
                // sent meanwhile: edit what the server made of it
                serverTransactionId = LocalStore.shared.sent(id)?.transactionId
            }
        case .edit(let id):
            queued = Sync.changeFor(server, transactionId: id)
            serverTransactionId = id
        default:
            break
        }

        if queued?.kind == .delete {
            // deleted on this phone: show the server's version, and saving it takes the place of the deletion
            queued = nil
        }

        self.queued = queued
        transactionId = serverTransactionId
        var book = queued.map { $0.bookId } ?? server.bookId

        if case .quick(_, let quickBook) = target {
            if let quickBook {
                book = quickBook == "personal" ? nil : quickBook
            }
        }

        bookId = book
        originalBookId = book
        recent = RecentChoices(serverId: server.id, bookId: book)

        if case .quick(let quickType, _) = target {
            type = quickType
        }

        if let queued {
            var record = TransactionRecord(json: JSONObject(queued.body))
            record.id = queued.transactionId ?? ""
            original = record
        }

        if let pending {
            type = pending.refund ? TransactionType.income : TransactionType.expense
            amountText = Formats.editableAmount(pending.amount)
            time = pending.date
            merchant = pending.merchant
        }
    }

    var isEditing: Bool {
        original != nil || transactionId != nil
    }

    /// The server's id of the transaction being edited; nil for a new one, or one added on the phone and not sent yet.
    private let transactionId: String?
    /// A change saved on this phone and not sent yet, which this form edits instead of the server's version.
    private(set) var queued: LocalStore.Change?
    /// The server's version as it came, kept with a change saved on the phone to notice later edits on the server.
    private var originalJSON: [String: Any]?

    /// Talks to the book this transaction goes in, which can differ from the one selected in the app.
    private func api() -> APIClient {
        server.client(bookId: bookId)
    }

    private func originalBookAPI() -> APIClient {
        server.client(bookId: originalBookId)
    }

    // MARK: - Loading

    func start() async {
        guard !started else {
            return
        }

        started = true

        Task {
            await loadBooks()
        }

        Task {
            // servers can turn photos off; they then keep the ones a transaction already has
            if let info = try? await APIClient.checkServer(server.url) {
                photosSupported = info.pictures
            }
        }

        await loadBookData()
    }

    private func loadBooks() async {
        // servers without family books answer 404, and then there is nothing to choose
        if let result = try? await server.client(bookId: nil).load("v1/books/list.json") {
            books = Book.parseList(result.value)
        }
    }

    /// Loads everything that belongs to the chosen book: accounts, categories, tags, merchants and projects.
    func loadBookData() async {
        loadGeneration += 1
        let generation = loadGeneration
        let client = api()
        // the transaction itself is fetched once; switching books keeps it and reloads only the book's lists
        let fetchId: String? = original == nil ? transactionId : nil
        loading = true

        // while the server can't be reached, the lists it sent last time are used
        async let accountsResult = capture { try await client.load("v1/accounts/list.json", query: [("visible_only", "true")]).value }
        async let categoriesResult = capture { try await client.load("v1/transaction/categories/list.json").value }
        async let tagsResult = capture { try await client.load("v1/transaction/tags/list.json").value }
        async let merchantsResult = capture { try await client.load("v1/transactions/merchants/list.json").value }
        async let projectsResult = capture { try await client.load("v1/projects/list.json").value }
        async let transactionResult = capture { () async throws -> Any? in
            guard let fetchId else {
                return nil
            }

            return try await client.load("v1/transactions/get.json", query: [
                ("id", fetchId), ("trim_account", "false"), ("trim_category", "false"), ("trim_tag", "false"),
            ]).value
        }

        let required = await (accountsResult, categoriesResult, transactionResult)
        let extras = await (tagsResult, merchantsResult, projectsResult)

        guard generation == loadGeneration else {
            return
        }

        loading = false

        for result in [required.0, required.1, required.2] {
            if case .failure(let error) = result {
                if !(error is CancellationError) {
                    loadGeneration += 1
                    alert = .loadFailed(error.localizedDescription)
                }

                return
            }
        }

        if case .success(let value) = required.0 {
            accounts = Account.selectable(Account.parseList(value))
        }

        if case .success(let value) = required.1 {
            categoriesByType = TransactionCategory.parseAllTypes(value)
        }

        if fetchId != nil, case .success(let value) = required.2 {
            original = TransactionRecord(json: JSONObject(value))
            originalJSON = value as? [String: Any]
        }

        // tags are optional; merchants and projects only exist on this app's server
        switch extras.0 {
        case .success(let value): tags = Tag.parseList(value)
        case .failure: tags = []
        }

        switch extras.1 {
        case .success(let value):
            merchantsSupported = true
            merchants = Merchants.parseList(value)
        case .failure:
            merchantsSupported = false
            merchants = []
        }

        switch extras.2 {
        case .success(let value):
            projectsSupported = true
            projects = Project.parseList(value)
        case .failure:
            projectsSupported = false
            projects = []
        }

        loaded()
    }

    private func loaded() {
        if let original {
            if !originalApplied {
                originalApplied = true
                fill(from: original)
            }
        } else {
            if case .add(let accountId) = target {
                account = findAccount(accountId)
                accountChosen = account != nil

                if account != nil {
                    // started from an account's page
                    accountSource = .given
                }
            }

            if pending != nil {
                applyPendingChoices()
            }

            if account == nil {
                applyRememberedAccounts(nil)

                if let category {
                    applyRememberedAccounts(category.id)
                }
            }
        }

        if let carried {
            apply(carried)
            self.carried = nil
        }
    }

    private func fill(from original: TransactionRecord) {
        if original.type == TransactionType.modifyBalance || !original.editable {
            webFallbackRoute = "/transaction/detail?id=\(original.id)&type=\(original.type)"
            return
        }

        type = original.type
        amountText = Formats.editableAmount(original.sourceAmount)
        account = findAccount(original.sourceAccountId)
        destinationAccount = findAccount(original.destinationAccountId)
        accountChosen = true
        destinationChosen = true
        category = findCategory(original.categoryId)
        tagIds = original.tagIds
        merchant = original.merchant
        projectId = original.projectId.isEmpty ? "0" : original.projectId
        time = original.date
        comment = original.comment

        if type == TransactionType.transfer {
            destinationAmountText = Formats.editableAmount(original.destinationAmount)
        }

        photos = original.pictureIds.enumerated().map { index, pictureId in
            Photo(id: UUID().uuidString, pictureId: pictureId,
                  url: index < original.pictureURLs.count ? original.pictureURLs[index] : nil)
        }

        for photo in photos {
            loadThumbnail(photo)
        }
    }

    /// The category used last time at this shop, and the account this card belongs to or else the one used at this shop.
    private func applyPendingChoices() {
        guard let pending else {
            return
        }

        if category == nil, let categoryId = recent.categoryForMerchant(pending.merchant),
           let remembered = findCategory(categoryId), categoriesOfType.contains(where: { $0.id == remembered.parentId }) {
            category = remembered
        }

        if accountChosen {
            return
        }

        // the card the purchase names is what was actually used, so it comes before the shop
        var card = findAccount(recent.accountForCard(pending.cardKey))

        // an account named or noted with the card's last four digits, like "Visa 1234"
        if card == nil, pending.cardKey.range(of: "^\\d{4}$", options: .regularExpression) != nil {
            card = accounts.first { $0.name.contains(pending.cardKey) || $0.comment.contains(pending.cardKey) }
        }

        if let card {
            account = card
            accountChosen = true
            accountSource = .card
            return
        }

        if let usedHere = findAccount(recent.accountForMerchant(pending.merchant)) {
            account = usedHere
            accountChosen = true
            accountSource = .shop
        }
    }

    /// On a new transaction, a shop picks the account last used there, unless the account was picked by hand,
    /// came with the screen (an account's page) or is the card a purchase was paid with.
    private func applyMerchantAccount() {
        guard original == nil, accountSource == .automatic || accountSource == .shop,
              let usedHere = findAccount(recent.accountForMerchant(merchant)) else {
            return
        }

        account = usedHere
        accountChosen = true
        accountSource = .shop
        errors.remove(.account)
    }

    /// Starts a new transaction with the accounts used last time for this category, or this kind of transaction.
    private func applyRememberedAccounts(_ categoryId: String?) {
        if !accountChosen {
            var remembered = findAccount(recent.accountForCategory(categoryId, destination: false))

            if remembered == nil && categoryId == nil {
                remembered = findAccount(recent.accountForType(type, destination: false))
                    ?? findAccount(server.user.string("defaultAccountId", "0"))
                    ?? accounts.first
            }

            if let remembered {
                account = remembered
            }
        }

        if !destinationChosen && type == TransactionType.transfer {
            var remembered = findAccount(recent.accountForCategory(categoryId, destination: true))

            if remembered == nil && categoryId == nil {
                remembered = findAccount(recent.accountForType(type, destination: true))
            }

            if let remembered {
                destinationAccount = remembered
            }
        }
    }

    // MARK: - Lookups

    var categoriesOfType: [TransactionCategory] {
        categoriesByType[CategoryType.of(transactionType: type)] ?? []
    }

    func findCategory(_ id: String) -> TransactionCategory? {
        for type in [CategoryType.income, CategoryType.expense, CategoryType.transfer] {
            for parent in categoriesByType[type] ?? [] {
                if let sub = parent.subCategories.first(where: { $0.id == id }) {
                    return sub
                }
            }
        }

        return nil
    }

    private func findParentCategory(of subId: String) -> TransactionCategory? {
        for type in [CategoryType.income, CategoryType.expense, CategoryType.transfer] {
            if let parent = (categoriesByType[type] ?? []).first(where: { parent in parent.subCategories.contains { $0.id == subId } }) {
                return parent
            }
        }

        return nil
    }

    func findAccount(_ id: String?) -> Account? {
        guard let id else {
            return nil
        }

        return accounts.first { $0.id == id }
    }

    func findBook(_ id: String?) -> Book? {
        books.first(where: { id == nil ? $0.isPersonal : $0.id == id })
    }

    func findProject(_ id: String) -> Project? {
        id == "0" ? nil : projects.first(where: { $0.id == id })
    }

    // MARK: - What the form shows

    var categoryText: String {
        guard let category else {
            return ""
        }

        if let parent = findParentCategory(of: category.id) {
            return parent.name + " › " + category.name
        }

        return category.name
    }

    var bookText: String {
        findBook(bookId)?.label ?? (bookId == nil ? String(localized: "My book") : (server.bookName ?? ""))
    }

    var tagsText: String {
        tags.filter { tagIds.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    var projectText: String {
        findProject(projectId)?.name ?? ""
    }

    var canChooseBook: Bool {
        books.count > 1
    }

    var showsProject: Bool {
        projectsSupported && (!projects.isEmpty || findProject(projectId) != nil)
    }

    var showsMerchant: Bool {
        merchantsSupported || !merchant.isEmpty
    }

    var showsDestinationAmount: Bool {
        guard type == TransactionType.transfer, let account, let destinationAccount else {
            return false
        }

        return account.currency != destinationAccount.currency
    }

    /// Changing the book of a filled-in form picks the same names in the new book, which is worth confirming.
    var bookChangeNeedsConfirmation: Bool {
        original != nil || category != nil || !tagIds.isEmpty || projectId != "0"
    }

    /// Under the amount of a purchase to review: the card it was paid with, and the amount in its own currency.
    var pendingNote: String? {
        guard let pending else {
            return nil
        }

        let paid = pending.card.isEmpty ? String(localized: "Apple Pay") : pending.card
        return pending.currency.isEmpty ? paid : "\(paid) · \(Formats.amount(pending.amount, currency: pending.currency))"
    }

    // MARK: - Sums in the amount fields

    /// "= £15.50" under an amount field while it holds a sum such as "12.50+3"; nil for a plain amount.
    func sumPreview(destination: Bool) -> String? {
        let text = destination ? destinationAmountText : amountText

        guard Formats.isExpression(text), let cents = Formats.parseAmount(text) else {
            return nil
        }

        let currency = (destination ? destinationAccount?.currency : account?.currency) ?? ""
        return "= " + Formats.amount(cents, currency: currency)
    }

    /// Adds + − × ÷ from the keyboard's bar, replacing an operator just typed so "12+" then × gives "12×".
    func appendOperator(_ symbol: String, destination: Bool) {
        var text = destination ? destinationAmountText : amountText

        if let last = text.last, Formats.operators.contains(last) {
            text.removeLast()
        }

        // a sum starts with a number
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return
        }

        text += symbol
        setAmountText(text, destination: destination)
    }

    /// Replaces a sum with its result, as the "=" key and leaving the field do; a sum that can't be worked out stays.
    func workOutSum(destination: Bool) {
        let text = destination ? destinationAmountText : amountText

        guard Formats.isExpression(text), let cents = Formats.parseAmount(text), cents >= 0 else {
            return
        }

        setAmountText(Formats.editableAmount(cents), destination: destination)
    }

    private func setAmountText(_ text: String, destination: Bool) {
        if destination {
            destinationAmountText = text
        } else {
            amountText = text
        }
    }

    var showsPhotos: Bool {
        photosSupported || !photos.isEmpty
    }

    // MARK: - Choices

    func setType(_ newType: Int) {
        guard newType != type else {
            return
        }

        type = newType
        category = nil

        if original == nil {
            applyRememberedAccounts(nil)
        }
    }

    func choose(category: TransactionCategory) {
        self.category = category
        errors.remove(.category)

        if original == nil {
            applyRememberedAccounts(category.id)
        }
    }

    func choose(account: Account, destination: Bool) {
        if destination {
            destinationAccount = account
            destinationChosen = true
            errors.remove(.destinationAccount)
        } else {
            self.account = account
            accountChosen = true
            accountSource = .given
            errors.remove(.account)
        }
    }

    func choose(merchant name: String) {
        merchant = name
        applyMerchantAccount()
    }

    /// Uses the spelling already in use, so one shop doesn't show up twice in reports.
    func addMerchant(_ name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxNameLength))

        guard !trimmed.isEmpty else {
            return
        }

        choose(merchant: merchants.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) ?? trimmed)
    }

    func switchBook(to chosen: String?) {
        guard chosen != bookId else {
            return
        }

        var carried = Carried()

        if let category {
            carried.categoryName = category.name
            carried.categoryParentName = categoriesOfType.first(where: { $0.id == category.parentId })?.name
        }

        carried.account = account
        carried.accountSource = accountSource
        carried.destinationAccount = destinationAccount
        carried.tagNames = tags.filter { tagIds.contains($0.id) }.map(\.name)
        carried.projectName = findProject(projectId)?.name
        self.carried = carried

        bookId = chosen
        recent = RecentChoices(serverId: server.id, bookId: chosen)
        category = nil
        account = nil
        destinationAccount = nil
        accountChosen = false
        accountSource = .automatic
        destinationChosen = false
        tagIds = []
        merchants = []
        projectId = "0"
        accounts = []
        tags = []
        projects = []
        categoriesByType = [:]

        Task {
            await loadBookData()
        }
    }

    /// Picks the category, accounts, tags and project with the same names in the new book.
    private func apply(_ carried: Carried) {
        if let name = carried.categoryName {
            var sameName: TransactionCategory?

            for parent in categoriesOfType {
                for sub in parent.subCategories where !sub.hidden && sub.name.caseInsensitiveCompare(name) == .orderedSame {
                    if let parentName = carried.categoryParentName, parent.name.caseInsensitiveCompare(parentName) == .orderedSame {
                        category = sub
                    } else if sameName == nil {
                        sameName = sub
                    }
                }
            }

            if category == nil {
                category = sameName
            }
        }

        if let same = findCarriedAccount(carried.account) {
            account = same
            accountChosen = true
            accountSource = carried.accountSource
        }

        if let same = findCarriedAccount(carried.destinationAccount) {
            destinationAccount = same
            destinationChosen = true
        }

        for name in carried.tagNames {
            if let tag = tags.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }), !tagIds.contains(tag.id) {
                tagIds.append(tag.id)
            }
        }

        if let projectName = carried.projectName,
           let project = projects.first(where: { $0.name.caseInsensitiveCompare(projectName) == .orderedSame }) {
            projectId = project.id
        }
    }

    /// An account shared with both books keeps its id; otherwise one with the same name and currency.
    private func findCarriedAccount(_ previous: Account?) -> Account? {
        guard let previous else {
            return nil
        }

        return findAccount(previous.id)
            ?? accounts.first(where: { $0.name == previous.name && $0.currency == previous.currency })
    }

    // MARK: - Adding categories

    /// Adds a category to a group, creating the group first when there is none yet, and selects it.
    func addCategory(name: String, group: TransactionCategory?, newGroupName: String?) async {
        loading = true

        do {
            var parent = group

            if parent == nil, let newGroupName {
                parent = try await postCategory(name: newGroupName, parentId: "0", icon: Self.newCategoryIcon, color: Self.newCategoryColor)
            }

            guard let parent else {
                loading = false
                return
            }

            let created = try await postCategory(name: name, parentId: parent.id, icon: parent.icon, color: parent.color)
            let result = try await api().get("v1/transaction/categories/list.json")
            categoriesByType = TransactionCategory.parseAllTypes(result)

            if let added = findCategory(created.id) {
                choose(category: added)
            }
        } catch {
            if !(error is CancellationError) {
                alert = .message(error.localizedDescription)
            }
        }

        loading = false
    }

    private func postCategory(name: String, parentId: String, icon: String, color: String) async throws -> TransactionCategory {
        let body: [String: Any] = [
            "name": String(name.prefix(Self.maxNameLength)),
            "type": CategoryType.of(transactionType: type),
            "parentId": parentId,
            "icon": icon.isEmpty ? Self.newCategoryIcon : icon,
            "color": color.count == 6 ? color : Self.newCategoryColor,
            "comment": "",
            "clientSessionId": UUID().uuidString,
        ]
        let result = try await api().post("v1/transaction/categories/add.json", body: body)
        return TransactionCategory(json: JSONObject(result))
    }

    // MARK: - Saving

    func save() async {
        guard !saving, !loading else {
            return
        }

        var invalid = Set<Field>()
        let amount = Formats.parseAmount(amountText)
        let transfer = type == TransactionType.transfer
        var destinationAmount = amount
        var problem: String?

        if amount == nil || amount! < 0 {
            invalid.insert(.amount)
        }

        if category == nil {
            invalid.insert(.category)
        }

        if account == nil {
            invalid.insert(.account)
        }

        if transfer {
            if destinationAccount == nil {
                invalid.insert(.destinationAccount)
            } else if let account, destinationAccount?.id == account.id {
                invalid.insert(.destinationAccount)
                problem = String(localized: "Choose two different accounts")
            }

            if showsDestinationAmount {
                destinationAmount = Formats.parseAmount(destinationAmountText)

                if destinationAmount == nil || destinationAmount! < 0 {
                    invalid.insert(.destinationAmount)
                }
            }
        }

        errors = invalid

        if let problem {
            alert = .message(problem)
        }

        guard invalid.isEmpty, let amount, let category, let account else {
            return
        }

        if photos.contains(where: { $0.uploading }) {
            alert = .message(String(localized: "Wait for the photos to finish uploading"))
            return
        }

        // a transaction added on the phone and not sent yet simply goes to the other book when it is sent
        let moving = original != nil && bookId != originalBookId && queued?.kind != .add
        var body: [String: Any] = [:]

        if let original, !original.id.isEmpty, !moving {
            body["id"] = original.id
        } else {
            // the phone version of an add keeps its id, so the server can tell a repeat
            body["clientSessionId"] = queued.flatMap { JSONObject($0.body).has("clientSessionId") ? JSONObject($0.body).string("clientSessionId") : nil }
                ?? clientSessionId
        }

        body["type"] = type
        body["categoryId"] = category.id
        body["time"] = Int64(time.timeIntervalSince1970)
        body["utcOffset"] = TimeZone.current.secondsFromGMT(for: time) / 60
        body["sourceAccountId"] = account.id
        body["destinationAccountId"] = transfer ? (destinationAccount?.id ?? "0") : "0"
        body["sourceAmount"] = amount
        body["destinationAmount"] = transfer ? (destinationAmount ?? amount) : Int64(0)
        body["hideAmount"] = original?.hideAmount ?? false
        body["tagIds"] = tagIds
        // a move by adding to the other book can't take photos along; the one-step move copies them
        body["pictureIds"] = moving ? [String]() : photos.compactMap(\.pictureId)
        body["projectId"] = projectId

        if merchantsSupported || !merchant.isEmpty {
            body["merchant"] = merchant
        }

        body["comment"] = comment.trimmingCharacters(in: .whitespacesAndNewlines)

        if let geoLocation = original?.geoLocation {
            body["geoLocation"] = geoLocation
        }

        if moving && !Connectivity.shared.isOnline {
            alert = .message(String(localized: "Moving to another book needs the server. Try again when it can be reached."))
            return
        }

        saving = true

        if moving {
            await moveToBook(body)
            return
        }

        let labels = Self.labels(category: category, account: account, destination: transfer ? destinationAccount : nil)

        if queued != nil || !Connectivity.shared.isOnline {
            saveOnPhone(body, labels: labels)
            return
        }

        do {
            try await api().post(original == nil ? "v1/transactions/add.json" : "v1/transactions/modify.json", body: body)

            if let original, let deletion = Sync.changeFor(server, transactionId: original.id), deletion.kind == .delete {
                // it was deleted on the phone earlier; saving it again keeps it
                Sync.keepServers(deletion)
            }

            rememberChoices(category: category, account: account)
            finish()
        } catch let error as APIError where error.unreachable {
            saveOnPhone(body, labels: labels)
        } catch {
            saving = false
            alert = .message(error.localizedDescription)
        }
    }

    private func rememberChoices(category: TransactionCategory, account: Account) {
        recent.remember(type: type, categoryId: category.id, accountId: account.id,
                        destinationAccountId: type == TransactionType.transfer ? destinationAccount?.id : nil)
        recent.rememberMerchant(merchant, categoryId: category.id, accountId: account.id)

        if let pending {
            recent.rememberCard(pending.cardKey, accountId: account.id)
            // the automation keeps using its own name for the shop even if it was renamed here
            recent.rememberMerchant(pending.merchant, categoryId: category.id, accountId: account.id)
            PendingPurchases.remove(pending.id)
        }
    }

    /// Keeps the transaction on this phone while the server can't be reached; it is sent once it answers again.
    private func saveOnPhone(_ body: [String: Any], labels: [String: String]) {
        if var queued {
            // also when it was sent while this form was open: then it changes what the server made of it
            queued.bookId = bookId
            Sync.saveEdit(server, change: queued, body: body, labels: labels)
        } else {
            Sync.queue(server, bookId: bookId, kind: original == nil ? .add : .modify, transactionId: original?.id,
                       body: body, base: originalJSON, labels: labels)
        }

        if let category, let account {
            rememberChoices(category: category, account: account)
        }

        finish()
    }

    /// Names to show a change saved on the phone by, since the lists of accounts may be out of reach later.
    static func labels(category: TransactionCategory?, account: Account?, destination: Account?) -> [String: String] {
        [
            "category": category?.name ?? "",
            "account": account?.name ?? "",
            "currency": account?.currency ?? "",
            "destinationAccount": destination?.name ?? "",
            "destinationCurrency": destination?.currency ?? "",
        ]
    }

    /// Moves the transaction in one step on servers that can, or by adding it to the new book and deleting the old one.
    private func moveToBook(_ body: [String: Any]) async {
        guard let original, let sourceBook = findBook(originalBookId) else {
            await addThenRemoveFromOriginalBook(body)
            return
        }

        var moveBody = body
        moveBody["id"] = original.id
        moveBody["sourceBookId"] = sourceBook.id
        moveBody["pictureIds"] = photos.compactMap(\.pictureId)

        do {
            try await api().post("v1/transactions/move/book.json", body: moveBody)
            finish()
        } catch let error as APIError where error.isNotFound {
            // servers before the move request answer 404
            await addThenRemoveFromOriginalBook(body)
        } catch {
            saving = false
            alert = .message(error.localizedDescription)
        }
    }

    private func addThenRemoveFromOriginalBook(_ body: [String: Any]) async {
        guard let original else {
            return
        }

        do {
            try await api().post("v1/transactions/add.json", body: body)
        } catch {
            saving = false
            alert = .message(error.localizedDescription)
            return
        }

        do {
            try await originalBookAPI().post("v1/transactions/delete.json", body: ["id": original.id])
            finish()
        } catch {
            changedData = true
            let from = findBook(originalBookId)?.label ?? String(localized: "the other book")
            alert = .moveIncomplete(String(localized: "The transaction was saved in the new book, but couldn't be removed from \(from) (\(error.localizedDescription)). Delete it there so it isn't counted twice."))
        }
    }

    func delete() async {
        guard let original else {
            return
        }

        if let queued {
            // an add is simply dropped; one the server has is deleted there once it can be reached
            Sync.deleteEdit(server, change: queued)
            finish()
            return
        }

        if !Connectivity.shared.isOnline {
            deleteOnPhone(original)
            return
        }

        saving = true

        do {
            try await originalBookAPI().post("v1/transactions/delete.json", body: ["id": original.id])
            finish()
        } catch let error as APIError where error.unreachable {
            deleteOnPhone(original)
        } catch {
            saving = false
            alert = .message(error.localizedDescription)
        }
    }

    private func deleteOnPhone(_ original: TransactionRecord) {
        Sync.queue(server, bookId: originalBookId, kind: .delete, transactionId: original.id, body: ["id": original.id],
                   base: originalJSON, labels: Self.labels(category: category, account: account, destination: destinationAccount))
        finish()
    }

    /// Takes a purchase off the To review list without saving it.
    func dismissPending() {
        if let pending {
            PendingPurchases.remove(pending.id)
        }

        finish()
    }

    // MARK: - Photos

    /// Shows a photo on the form and uploads it to the server; jpeg is already shrunk to a sensible size.
    func addPhoto(jpeg: Data, thumbnail: Data?) {
        let photo = Photo(id: UUID().uuidString, thumbnail: thumbnail, uploading: true)
        photos.append(photo)
        let client = api()

        Task {
            do {
                let result = try await client.upload("v1/transaction/pictures/upload.json", field: "picture", fileName: "photo.jpg",
                                                     contentType: "image/jpeg", data: jpeg,
                                                     fields: [("clientSessionId", UUID().uuidString)])
                let json = JSONObject(result)

                if let index = photos.firstIndex(where: { $0.id == photo.id }) {
                    photos[index].pictureId = json.string("pictureId")
                    photos[index].url = json.string("originalUrl")
                    photos[index].uploading = false
                }
            } catch {
                photos.removeAll { $0.id == photo.id }

                if !(error is CancellationError) {
                    alert = .message(String(localized: "Couldn't upload the photo: \(error.localizedDescription)"))
                }
            }
        }
    }

    func removePhoto(_ photo: Photo) {
        photos.removeAll { $0.id == photo.id }
    }

    /// Thumbnails are made by the view, which knows about images; the model only keeps the bytes.
    static var makeThumbnail: ((Data) -> Data?)?

    private func loadThumbnail(_ photo: Photo) {
        guard let url = photo.url, !url.isEmpty else {
            return
        }

        let client = originalBookAPI()

        Task {
            guard let data = try? await client.download(client.pictureURL(url)) else {
                // the photo stays attached; only its preview is missing
                return
            }

            let thumbnail = Self.makeThumbnail?(data) ?? data

            if let index = photos.firstIndex(where: { $0.id == photo.id }) {
                photos[index].thumbnail = thumbnail
            }
        }
    }

    func finish() {
        changedData = true
        finished = true
    }
}
