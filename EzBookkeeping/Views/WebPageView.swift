import SwiftUI
import UIKit
import WebKit

/// Shares the native sign-in with the server's mobile web pages that open inside the app,
/// the same way the Android app does: the token, user and book go where the web app looks for them.
enum WebSession {
    static let tokenKey = "ebk_user_token"
    static let userKey = "ebk_user_info"
    static let bookKey = "ebk_user_current_book_id"

    static func mobileURL(_ server: Server, route: String) -> URL? {
        URL(string: server.url + "/mobile#!" + route)
    }

    /// scheme://host[:port] of the server, as the page's own `location` reports it.
    static func origin(_ server: Server) -> String {
        guard let components = URLComponents(string: server.url),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            return server.url
        }

        let hostPart = host.contains(":") ? "[\(host)]" : host
        let defaultPort = scheme == "https" ? 443 : 80

        if let port = components.port, port != defaultPort {
            return "\(scheme)://\(hostPart):\(port)"
        }

        return "\(scheme)://\(hostPart)"
    }

    /// A script run before the server's page starts, writing the sign-in into its storage.
    /// It does nothing on other sites, so the token never leaves the server's own pages.
    static func signedInScript(_ server: Server) -> String {
        var body = ""

        if let token = server.token {
            body += "localStorage.setItem(\(jsString(tokenKey)),\(jsString(token)));"
        }

        if let user = server.userJson {
            body += "localStorage.setItem(\(jsString(userKey)),\(jsString(user)));"
        }

        if let bookId = server.bookId {
            body += "localStorage.setItem(\(jsString(bookKey)),\(jsString(bookId)));"
        } else {
            body += "localStorage.removeItem(\(jsString(bookKey)));"
        }

        return "(function(){if(location.protocol+'//'+location.host!==\(jsString(origin(server))))return;try{\(body)}catch(e){}})();"
    }

    static let readSignInScript = "JSON.stringify({t:localStorage.getItem('\(tokenKey)'),u:localStorage.getItem('\(userKey)')})"

    /// A JavaScript string literal for any text.
    static func jsString(_ text: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
              let array = String(data: data, encoding: .utf8) else {
            return "''"
        }

        // ["..."] → "..."
        return String(array.dropFirst().dropLast())
    }

    /// The part after "#!" of a web app address, without its query.
    static func route(of url: URL?) -> String {
        guard let text = url?.absoluteString, let hash = text.range(of: "#!") else {
            return "/"
        }

        var route = String(text[hash.upperBound...])

        if let query = route.firstIndex(of: "?") {
            route = String(route[..<query])
        }

        return route.isEmpty ? "/" : route
    }

    /// Forgets what the server's web pages stored in the app, for sign-out and removed servers.
    static func clear(_ server: Server) {
        guard let host = URL(string: server.url)?.host?.lowercased() else {
            return
        }

        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let matching = records.filter { record in
                let name = record.displayName.lowercased()
                return name == host || host.hasSuffix("." + name)
            }

            if !matching.isEmpty {
                store.removeData(ofTypes: types, for: matching) {}
            }
        }
    }
}

/// One of the server's mobile web pages (reports, budgets and other less used pages), already signed in.
struct WebPageScreen: View {
    let title: String
    let route: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let server = appState.activeServer {
                    WebPageView(server: server, route: route, signInMode: false, onClose: {
                        dismiss()
                    }, onSignInRejected: {
                        // check natively, which signs out if the sign-in really expired
                        let client = server.client()
                        Task {
                            _ = try? await client.get("v1/users/profile/get.json")
                        }
                    }, onSignedIn: { _, _ in })
                } else {
                    Text("Not signed in")
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityIdentifier("web_done")
                }
            }
        }
    }
}

/// The web sign-in page, for single sign-on or creating an account; hands the resulting sign-in back.
struct WebSignInScreen: View {
    let server: Server
    let onSignedIn: (_ token: String, _ userJson: String?) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            WebPageView(server: server, route: "/login", signInMode: true, onClose: {
                dismiss()
            }, onSignInRejected: {}, onSignedIn: { token, user in
                onSignedIn(token, user)
                dismiss()
            })
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle("Sign in")
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

struct WebPageView: UIViewRepresentable {
    let server: Server
    let route: String
    let signInMode: Bool
    let onClose: () -> Void
    let onSignInRejected: () -> Void
    let onSignedIn: (_ token: String, _ userJson: String?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        if signInMode {
            // a fresh, private storage: the sign-in page must not see an old sign-in
            configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        } else {
            let script = WKUserScript(source: WebSession.signedInScript(server), injectionTime: .atDocumentStart, forMainFrameOnly: true)
            configuration.userContentController.addUserScript(script)
        }

        configuration.applicationNameForUserAgent = "ezBookkeepingiOS"

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.accessibilityIdentifier = "web_view"
        context.coordinator.attach(webView)
        context.coordinator.load()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebPageView
        private weak var webView: WKWebView?
        private var urlObservation: NSKeyValueObservation?
        private var pollTimer: Timer?
        private var targetReached = false
        private var finished = false

        init(parent: WebPageView) {
            self.parent = parent
        }

        func attach(_ webView: WKWebView) {
            self.webView = webView
            urlObservation = webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                let url = view.url
                Task { @MainActor [weak self] in
                    self?.routeChanged(url)
                }
            }

            if parent.signInMode {
                pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.readWebSignIn()
                    }
                }
            }
        }

        func load() {
            targetReached = false

            if let url = WebSession.mobileURL(parent.server, route: parent.route) {
                webView?.load(URLRequest(url: url))
            }
        }

        func stop() {
            pollTimer?.invalidate()
            pollTimer = nil
            urlObservation?.invalidate()
            urlObservation = nil
        }

        private func routeChanged(_ url: URL?) {
            guard !finished, let url, url.absoluteString.hasPrefix(parent.server.url + "/mobile") else {
                return
            }

            let route = WebSession.route(of: url)

            if parent.signInMode {
                if route != "/login" && !route.hasPrefix("/signup") {
                    Task {
                        await readWebSignIn()
                    }
                }

                return
            }

            if !targetReached {
                targetReached = route == parent.route
                return
            }

            if route == "/" {
                // the home page is the native overview, so going "back home" on a web page closes it
                finish()
                parent.onClose()
            } else if route == "/login" {
                finish()
                parent.onSignInRejected()
                parent.onClose()
            }
        }

        private func readWebSignIn() async {
            guard !finished, let webView else {
                return
            }

            guard let value = try? await webView.evaluateJavaScript(WebSession.readSignInScript),
                  let text = value as? String, !finished else {
                return
            }

            let json = JSONObject.parse(text)
            let token = json.string("t")

            // a token protected by the web app's PIN lock isn't a usable sign-in
            guard token.hasPrefix("ey") else {
                return
            }

            let user = json.string("u")
            finish()
            parent.onSignedIn(token, user.isEmpty ? nil : user)
        }

        private func finish() {
            finished = true
            stop()
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            showError(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showError(error, in: webView)
        }

        private func showError(_ error: Error, in webView: WKWebView) {
            let nsError = error as NSError

            // a cancelled load is replaced by another one, not an error
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                return
            }

            let html = """
            <html><head><meta name="viewport" content="width=device-width,initial-scale=1"></head>
            <body style="font-family:-apple-system;padding:24px;color:#555">
            <h3>Unable to reach the server</h3><p>\(escapeHTML(parent.server.url))<br>\(escapeHTML(error.localizedDescription))</p>
            </body></html>
            """
            webView.loadHTMLString(html, baseURL: nil)
        }

        private func escapeHTML(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
    }
}
