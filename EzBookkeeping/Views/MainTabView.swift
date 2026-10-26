import SwiftUI

enum MainTab: Hashable {
    case overview
    case transactions
    case accounts
    case more
}

/// The app's home: overview, transactions, accounts and more, switched with the tab bar.
struct MainTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var tab = MainTab.overview
    /// The add form a widget button asked for.
    @State private var linkEditor: EditorTarget?

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack {
                OverviewView(tab: $tab)
            }
            .tabItem {
                Label("Overview", systemImage: "chart.pie")
            }
            .tag(MainTab.overview)

            NavigationStack {
                TransactionsView(accountIds: nil, title: String(localized: "Transactions"))
            }
            .tabItem {
                Label("Transactions", systemImage: "list.bullet")
            }
            .tag(MainTab.transactions)

            NavigationStack {
                AccountsView()
            }
            .tabItem {
                Label("Accounts", systemImage: "creditcard")
            }
            .tag(MainTab.accounts)

            NavigationStack {
                MoreView()
            }
            .tabItem {
                Label("More", systemImage: "ellipsis.circle")
            }
            .tag(MainTab.more)
        }
        .task {
            await appState.loadBooks()
        }
        .onChange(of: appState.link, initial: true) { _, link in
            guard let link else {
                return
            }

            appState.link = nil
            tab = .overview

            if case .add(let type, let book) = link {
                linkEditor = .quick(type: type, book: book)
            }
        }
        .sheet(item: $linkEditor) { target in
            TransactionEditView(target: target)
        }
    }
}

/// Toolbar button that switches the main screens between the user's own book and family books.
/// Hidden on servers without books, and when there is only the user's own book.
struct BookMenu: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.books.count > 1 {
            Menu {
                ForEach(appState.books) { book in
                    Button {
                        appState.selectBook(book)
                    } label: {
                        if isSelected(book) {
                            Label(book.label, systemImage: "checkmark")
                        } else {
                            Text(book.label)
                        }
                    }
                }
            } label: {
                Label(appState.activeServer?.bookName ?? String(localized: "My book"), systemImage: "books.vertical")
                    .labelStyle(.titleAndIcon)
            }
            .accessibilityIdentifier("book_menu")
        }
    }

    private func isSelected(_ book: Book) -> Bool {
        let selected = appState.activeServer?.bookId
        return selected == nil ? book.isPersonal : book.id == selected
    }
}
