import SwiftUI

/// Everything that isn't a daily screen: reports, budgets and other pages of the web app, plus settings.
struct MoreView: View {
    @EnvironmentObject private var appState: AppState
    @State private var webPage: WebPage?

    var body: some View {
        List {
            Section("Insights") {
                webItem("Reports", "chart.bar", "/statistic/transaction")

                if appState.serverHasBooks {
                    // these pages only exist on servers with the family books features
                    webItem("Budgets", "chart.pie", "/budgets")
                    webItem("Household report", "house", "/reports/household")
                    webItem("Projects", "folder", "/projects")
                }
            }

            Section("Organize") {
                webItem("Categories", "square.grid.2x2", "/category/all")
                webItem("Tags", "tag", "/tag/list")
                webItem("Templates", "doc.text", "/template/list")
                webItem("Scheduled transactions", "calendar.badge.clock", "/schedule/list")

                if appState.serverHasBooks {
                    webItem("Family books", "person.2", "/user/books")
                }

                webItem("Exchange rates", "arrow.left.arrow.right", "/exchange_rates")
            }

            Section("App") {
                NavigationLink {
                    SettingsView()
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
                .accessibilityIdentifier("settings")

                webItem("Server settings and preferences", "person.crop.circle", "/settings")
                webItem("Open the full web version", "globe", "/")
            }
        }
        .navigationTitle("More")
        .fullScreenCover(item: $webPage, onDismiss: {
            // the web pages can change anything, so the native screens load again
            appState.dataChanged()
        }) { page in
            WebPageScreen(title: page.title, route: page.route)
        }
    }

    private func webItem(_ title: String, _ icon: String, _ route: String) -> some View {
        Button {
            webPage = WebPage(title: title, route: route)
        } label: {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
        }
    }
}

/// App settings: which server to use, sign-out, theme and version.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppState.themeKey) private var theme = ThemeChoice.system.rawValue
    @State private var confirmingSignOut = false

    var body: some View {
        Form {
            Section("Current server") {
                if let server = appState.activeServer {
                    NavigationLink {
                        ServersView(firstRun: false)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(server.displayName)
                            Text(server.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if server.isSignedIn {
                        LabeledContent("Account", value: server.userDisplayName)

                        Button("Sign out", role: .destructive) {
                            confirmingSignOut = true
                        }
                        .accessibilityIdentifier("sign_out")
                    }
                }

                NavigationLink {
                    ServersView(firstRun: false)
                } label: {
                    LabeledContent("Manage servers", value: appState.servers.count == 1 ? "1 server" : "\(appState.servers.count) servers")
                }
                .accessibilityIdentifier("manage_servers")
            }

            Section("App") {
                Picker("Theme", selection: $theme) {
                    ForEach(ThemeChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                .accessibilityIdentifier("theme")

                LabeledContent("Version", value: Self.version)
            }
        }
        .navigationTitle("Settings")
        .alert("Sign out", isPresented: $confirmingSignOut) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                if let server = appState.activeServer {
                    appState.signOut(server)
                }
            }
        } message: {
            Text("Sign out of \(appState.activeServer?.displayName ?? "")?")
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}
