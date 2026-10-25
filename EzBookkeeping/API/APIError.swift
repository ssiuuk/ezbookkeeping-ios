import Foundation

/// A failed call to the server, with the server's own message when it sent one.
struct APIError: LocalizedError, Equatable {
    var httpStatus: Int
    var errorCode: Int
    var message: String
    /// No answer came at all: no network, or the server is down. Screens then show the copy kept on the phone.
    var unreachable = false

    var errorDescription: String? {
        message
    }

    var isUnauthorized: Bool {
        httpStatus == 401
    }

    /// Servers without one of the fork's features answer 404 for its endpoints.
    var isNotFound: Bool {
        httpStatus == 404
    }

    static func unreachable(_ detail: String?) -> APIError {
        let suffix = detail.map { " (\($0))" } ?? ""
        return APIError(httpStatus: 0, errorCode: 0, message: "Can't reach the server" + suffix, unreachable: true)
    }
}
