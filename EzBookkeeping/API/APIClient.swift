import Foundation

/// Calls the ezBookkeeping JSON API (`/api/...`) of one server, as the signed-in user, in one book.
///
/// Every request carries the time zone headers the server uses for "today" and "this month",
/// the bearer token and, for a family book, `X-Book-Id`. Responses look like
/// `{"success": true, "result": ...}` or `{"success": false, "errorCode": ..., "errorMessage": ...}`.
struct APIClient {
    let baseURL: String
    /// The saved sign-in, or a temporary one during the two-factor step; nil or empty sends none.
    var token: String?
    /// The family book to work in; nil is the user's own book.
    var bookId: String?

    /// Called on the main actor when the server rejects the saved sign-in (HTTP 401).
    static var onUnauthorized: (@MainActor (_ baseURL: String, _ token: String) -> Void)?

    static let timeout: TimeInterval = 20

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = APIClient.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: - Requests

    /// GETs `path` (relative to /api/, for example "v1/accounts/list.json") and returns the "result" value.
    func get(_ path: String, query: [(String, String?)] = []) async throws -> Any? {
        var fullPath = path
        var pairs: [String] = []

        for (key, value) in query {
            if let value {
                pairs.append(Self.encode(key) + "=" + Self.encode(value))
            }
        }

        if !pairs.isEmpty {
            fullPath += "?" + pairs.joined(separator: "&")
        }

        return try await send(method: "GET", path: fullPath, body: nil)
    }

    /// POSTs a JSON body and returns the "result" value.
    @discardableResult
    func post(_ path: String, body: [String: Any] = [:]) async throws -> Any? {
        let data = try JSONSerialization.data(withJSONObject: body, options: [])
        return try await send(method: "POST", path: path, body: data)
    }

    private func send(method: String, path: String, body: Data?) async throws -> Any? {
        guard let url = URL(string: baseURL + "/api/" + path) else {
            throw APIError(httpStatus: 0, errorCode: 0, message: "Invalid server address")
        }

        var request = URLRequest(url: url, timeoutInterval: Self.timeout)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")

        let timeZone = TimeZone.current
        request.setValue(String(timeZone.secondsFromGMT() / 60), forHTTPHeaderField: "X-Timezone-Offset")
        request.setValue(timeZone.identifier, forHTTPHeaderField: "X-Timezone-Name")

        if let token, !token.isEmpty {
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }

        if let bookId, !bookId.isEmpty {
            request.setValue(bookId, forHTTPHeaderField: "X-Book-Id")
        }

        if let body {
            request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let received: (Data, URLResponse)

        do {
            received = try await Self.session.data(for: request)
        } catch {
            // a screen that went away cancels its loads; that isn't worth an error message
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }

            throw APIError.unreachable(error.localizedDescription)
        }

        let (data, response) = received

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        do {
            return try Self.result(of: data, status: status)
        } catch let error as APIError {
            if error.isUnauthorized, let token, !token.isEmpty, let handler = Self.onUnauthorized {
                let baseURL = self.baseURL
                await MainActor.run {
                    handler(baseURL, token)
                }
            }

            throw error
        }
    }

    /// Reads the server's response envelope; separate so it can be unit tested.
    static func result(of data: Data, status: Int) throws -> Any? {
        let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        guard let envelope = parsed as? [String: Any] else {
            if status == 404 {
                throw APIError(httpStatus: status, errorCode: 0, message: "This server doesn't support this feature")
            }

            throw APIError(httpStatus: status, errorCode: 0, message: status >= 400
                ? "The server answered with error \(status)"
                : "This address doesn't look like an ezBookkeeping server")
        }

        let json = JSONObject(envelope)

        guard json.bool("success") else {
            let message = json.string("errorMessage")
            throw APIError(httpStatus: status, errorCode: json.int("errorCode"),
                           message: message.isEmpty ? "The server answered with error \(status)" : message)
        }

        let result = envelope["result"]
        return result is NSNull ? nil : result
    }

    /// Percent-encodes everything but unreserved characters, so "+", "&" and "|" survive the trip.
    static func encode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    // MARK: - Server check

    /// Checks that an address is an ezBookkeeping server before it is saved, and reads what it offers.
    static func checkServer(_ baseURL: String) async throws -> ServerInfo {
        guard let url = URL(string: baseURL + "/server_settings.js") else {
            throw APIError(httpStatus: 0, errorCode: 0, message: "Please enter a valid server address")
        }

        let received: (Data, URLResponse)

        do {
            received = try await session.data(for: URLRequest(url: url, timeoutInterval: timeout))
        } catch {
            throw APIError.unreachable(error.localizedDescription)
        }

        let (data, response) = received

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = status == 200 ? String(decoding: data, as: UTF8.self) : ""

        guard let info = ServerInfo.parse(script: text) else {
            throw APIError(httpStatus: status, errorCode: 0, message: "This address doesn't look like an ezBookkeeping server")
        }

        return info
    }
}

/// Runs a request and keeps its outcome, so several requests can run together and fail on their own.
func capture(_ operation: @escaping () async throws -> Any?) async -> Result<Any?, Error> {
    do {
        let value = try await operation()
        return .success(value)
    } catch {
        return .failure(error)
    }
}
