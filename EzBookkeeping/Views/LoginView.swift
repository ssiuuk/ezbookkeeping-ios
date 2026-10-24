import SwiftUI

/// Native sign-in with username and password, including the two-factor step.
struct LoginView: View {
    let server: Server

    @EnvironmentObject private var appState: AppState

    @State private var loginName = ""
    @State private var password = ""
    @State private var passcode = ""
    @State private var twoFactorToken: String?
    @State private var busy = false
    @State private var error: String?
    @State private var internalAuth = true
    @State private var showingWebSignIn = false
    @FocusState private var focused: Field?

    private enum Field {
        case loginName
        case password
        case passcode
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Sign in to \(server.displayName)")
                        .font(.title2.bold())
                    NavigationLink {
                        ServersView(firstRun: false)
                    } label: {
                        Label(server.hostLabel, systemImage: "server.rack")
                            .font(.subheadline)
                    }
                    .accessibilityIdentifier("server_chip")
                }
                .padding(.vertical, 6)
            }

            if twoFactorToken != nil {
                Section {
                    SecureField("Passcode", text: $passcode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .focused($focused, equals: .passcode)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .accessibilityIdentifier("passcode")
                } header: {
                    Text("Two-factor authentication")
                } footer: {
                    Text("Enter the 6-digit code from your authenticator app.")
                }
            } else if internalAuth {
                Section {
                    TextField("Username or email", text: $loginName)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .loginName)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                        .accessibilityIdentifier("login_name")

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focused, equals: .password)
                        .submitLabel(.done)
                        .onSubmit(submit)
                        .accessibilityIdentifier("password")
                }
            } else {
                Section {
                    Text("This server only allows single sign-on. Use \"Sign in on the web page\".")
                }
            }

            if let error {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("sign_in_error")
                }
            }

            if internalAuth || twoFactorToken != nil {
                Section {
                    HStack {
                        Button(action: submit) {
                            Text(twoFactorToken == nil ? "Sign in" : "Verify")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        .accessibilityIdentifier("sign_in_button")

                        if busy {
                            ProgressView()
                                .padding(.leading, 8)
                        }
                    }
                }
            }

            Section {
                Button("Sign in on the web page") {
                    showingWebSignIn = true
                }
                .accessibilityIdentifier("web_sign_in_button")
            } footer: {
                Text("Use this for single sign-on or to create an account.")
            }
        }
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingWebSignIn) {
            WebSignInScreen(server: server) { token, user in
                appState.finishSignIn(server, token: token, userJson: user)
            }
        }
        .task {
            let lastLoginName = server.user.string("username")

            if loginName.isEmpty && !lastLoginName.isEmpty {
                loginName = lastLoginName
            }

            if let info = try? await APIClient.checkServer(server.url) {
                internalAuth = info.internalAuth
            }
        }
    }

    private func submit() {
        guard !busy else {
            return
        }

        if let twoFactorToken {
            submitPasscode(twoFactorToken)
            return
        }

        let name = loginName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty, !password.isEmpty else {
            error = name.isEmpty ? "Enter your username or email" : "Enter your password"
            return
        }

        busy = true
        error = nil
        let client = APIClient(baseURL: server.url, token: "", bookId: nil)
        let password = self.password

        Task {
            do {
                let response = try await client.post("authorize.json", body: ["loginName": name, "password": password])
                let result = JSONObject(response)
                busy = false

                if result.bool("need2FA") {
                    twoFactorToken = result.string("token")
                    focused = .passcode
                    return
                }

                finish(result)
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    private func submitPasscode(_ token: String) {
        let code = passcode.trimmingCharacters(in: .whitespacesAndNewlines)

        guard code.count == 6 else {
            error = "Enter the 6-digit code from your authenticator app."
            return
        }

        busy = true
        error = nil
        let client = APIClient(baseURL: server.url, token: token, bookId: nil)

        Task {
            do {
                let response = try await client.post("2fa/authorize.json", body: ["passcode": code])
                let result = JSONObject(response)
                busy = false
                finish(result)
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }

    private func finish(_ result: JSONObject) {
        let token = result.string("token")

        guard !token.isEmpty else {
            error = "Unexpected response from the server"
            return
        }

        appState.finishSignIn(server, token: token, userJson: result.object("user")?.jsonText())
    }
}
