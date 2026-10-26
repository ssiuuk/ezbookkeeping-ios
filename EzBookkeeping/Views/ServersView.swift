import SwiftUI

/// Lists the saved servers, switches between them and adds new ones. Also the first screen on a fresh install.
struct ServersView: View {
    let firstRun: Bool

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showingAddForm = false
    @State private var address = ""
    @State private var name = ""
    @State private var connecting = false
    @State private var addressError: String?
    @State private var renaming: Server?
    @State private var newName = ""
    @State private var confirmingSignOut: Server?
    @State private var confirmingRemove: Server?

    private var removeMessage: String {
        let name = confirmingRemove?.displayName ?? ""
        var message = String(localized: "The app forgets \(name) and signs out of it. Your data stays on the server.")
        let unsent = confirmingRemove.map { LocalStore.shared.changes(serverId: $0.id).count } ?? 0

        if unsent > 0 {
            message += "\n\n" + String(localized: "\(unsent) changes made on this phone haven't reached this server yet and will be lost.")
        }

        return message
    }

    var body: some View {
        Form {
            if firstRun {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Welcome to ezBookkeeping")
                            .font(.title2.bold())
                        Text("Connect to your ezBookkeeping server to get started. You can add more servers later in Settings.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            } else {
                Section {
                    ForEach(appState.servers) { server in
                        serverRow(server)
                    }
                }
            }

            if firstRun || showingAddForm {
                addForm
            } else {
                Section {
                    Button {
                        showingAddForm = true
                    } label: {
                        Label("Add server", systemImage: "plus")
                    }
                    .accessibilityIdentifier("show_add_form")
                }
            }
        }
        .navigationTitle(firstRun ? "" : String(localized: "Servers"))
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(renaming?.hostLabel ?? String(localized: "Name"), text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let server = renaming {
                    appState.rename(server, to: newName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        .alert("Sign out", isPresented: Binding(get: { confirmingSignOut != nil }, set: { if !$0 { confirmingSignOut = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Sign out", role: .destructive) {
                if let server = confirmingSignOut {
                    appState.signOut(server)
                }
            }
        } message: {
            Text("Sign out of \(confirmingSignOut?.displayName ?? "")?")
        }
        .alert("Remove this server?", isPresented: Binding(get: { confirmingRemove != nil }, set: { if !$0 { confirmingRemove = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let server = confirmingRemove {
                    appState.remove(server)
                }
            }
        } message: {
            Text(removeMessage)
        }
    }

    private func serverRow(_ server: Server) -> some View {
        let isActive = server.id == appState.activeServerId
        let status = server.isSignedIn ? String(localized: "Signed in as \(server.userDisplayName)") : String(localized: "Not signed in")

        return Button {
            open(server)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.displayName)
                        .font(.headline)
                    Text(server.url)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(isActive ? String(localized: "In use") + " · " + status : status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename") {
                newName = server.name
                renaming = server
            }

            if server.isSignedIn {
                Button("Sign out") {
                    confirmingSignOut = server
                }
            }

            Button("Remove", role: .destructive) {
                confirmingRemove = server
            }
        }
        .swipeActions {
            Button("Remove", role: .destructive) {
                confirmingRemove = server
            }

            Button("Rename") {
                newName = server.name
                renaming = server
            }
        }
    }

    private var addForm: some View {
        Section {
            TextField("Server address", text: $address)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .accessibilityIdentifier("server_address")

            TextField("Name (optional)", text: $name)
                .textInputAutocapitalization(.words)
                .submitLabel(.go)
                .onSubmit(connect)
                .accessibilityIdentifier("server_name")

            if let addressError {
                Text(addressError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("server_error")
            }

            HStack {
                Button(action: connect) {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(connecting)
                .accessibilityIdentifier("connect_button")

                if connecting {
                    ProgressView()
                        .padding(.leading, 8)
                }
            }

            if !firstRun {
                Button("Cancel", role: .cancel) {
                    showingAddForm = false
                    addressError = nil
                }
            }
        } header: {
            Text("Add server")
        } footer: {
            Text("For example https://money.example.com or http://192.168.1.10:8080")
        }
    }

    private func connect() {
        // the keyboard's Go key can call this again while the first check is still running
        guard !connecting else {
            return
        }

        guard let url = Server.normalizeURL(address) else {
            addressError = String(localized: "Please enter a valid server address")
            return
        }

        addressError = nil
        connecting = true

        Task {
            do {
                _ = try await APIClient.checkServer(url)
                connecting = false
                let server = appState.addServer(name: name.trimmingCharacters(in: .whitespacesAndNewlines), url: url)
                address = ""
                name = ""
                showingAddForm = false
                open(server)
            } catch {
                connecting = false
                addressError = error.localizedDescription
            }
        }
    }

    private func open(_ server: Server) {
        let wasActive = server.id == appState.activeServerId

        if !wasActive {
            appState.setActive(server)
        }

        if !firstRun {
            dismiss()
        }
    }
}
