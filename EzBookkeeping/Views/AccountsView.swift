import SwiftUI

/// Accounts grouped by kind, with their balances. Tapping one shows its transactions.
struct AccountsView: View {
    @EnvironmentObject private var appState: AppState

    @State private var accounts: [Account] = []
    @State private var loading = false
    @State private var loadedVersion = -1
    @State private var error: String?
    @State private var webPage: WebPage?

    var body: some View {
        List {
            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                    Button("Retry") {
                        Task {
                            await load()
                        }
                    }
                }
            }

            ForEach(AccountCategories.grouped(accounts.filter { !$0.hidden })) { group in
                Section(AccountCategories.name(group.category)) {
                    ForEach(group.accounts) { account in
                        NavigationLink {
                            TransactionsView(accountIds: accountIds(of: account), title: account.name)
                        } label: {
                            AccountRow(account: account)
                        }
                    }
                }
            }
        }
        .overlay {
            if accounts.isEmpty && !loading && loadedVersion >= 0 && error == nil {
                ContentUnavailableView {
                    Label("No accounts yet", systemImage: "creditcard")
                } description: {
                    Text("Create an account first so transactions have somewhere to go.")
                } actions: {
                    Button("Add account") {
                        webPage = WebPage(title: "Add account", route: "/account/add")
                    }
                }
            } else if loading && accounts.isEmpty {
                ProgressView()
            }
        }
        .navigationTitle("Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                BookMenu()
            }
        }
        .refreshable {
            await load()
        }
        .task(id: appState.dataVersion) {
            if loadedVersion != appState.dataVersion {
                await load()
            }
        }
        .fullScreenCover(item: $webPage, onDismiss: {
            appState.dataChanged()
        }) { page in
            WebPageScreen(title: page.title, route: page.route)
        }
    }

    private func accountIds(of account: Account) -> String {
        account.hasSubAccounts ? account.subAccounts.map(\.id).joined(separator: ",") : account.id
    }

    private func load() async {
        guard let server = appState.activeServer else {
            return
        }

        let version = appState.dataVersion
        loading = true

        do {
            let result = try await server.client().get("v1/accounts/list.json", query: [("visible_only", "true")])
            accounts = Account.parseList(result)
            loadedVersion = version
            error = nil
        } catch is CancellationError {
            // the screen went away
        } catch {
            self.error = error.localizedDescription
        }

        loading = false
    }
}

struct AccountRow: View {
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            Avatar(name: account.name, hexColor: account.color)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            let balance = account.totalBalance
            Text(Formats.amount(balance, currency: account.displayCurrency))
                .font(.body.monospacedDigit())
                .foregroundStyle(balance < 0 ? Color.expense : Color.primary)
        }
    }

    private var subtitle: String {
        if account.hasSubAccounts {
            return "\(account.subAccounts.count) sub-accounts"
        }

        if !account.sharedBy.isEmpty {
            return "Shared by " + account.sharedBy
        }

        return account.currency
    }
}
