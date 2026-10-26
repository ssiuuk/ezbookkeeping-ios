import XCTest
@testable import EzBookkeeping

/// Answers sending's requests like a server: it remembers the clientSessionId of each add, and can lose its answers.
private final class FakeServer: SyncRemote, @unchecked Sendable {
    var transactions: [String: [String: Any]] = [:]
    /// Commits what it is sent but the answer doesn't reach the phone, like a dropped connection.
    var loseAnswers = false
    private var sessions: [String: String] = [:]
    private var nextId = 100

    func get(_ path: String, query: [(String, String?)]) async throws -> Any? {
        switch path {
        case "v1/transactions/get.json":
            let id = query.first { $0.0 == "id" }?.1 ?? ""

            guard let transaction = transactions[id] else {
                throw APIError(httpStatus: 400, errorCode: 205001, message: "Transaction not found")
            }

            return transaction
        case "v1/transactions/list/by_month.json":
            return ["items": Array(transactions.values)]
        default:
            throw APIError(httpStatus: 404, errorCode: 0, message: path)
        }
    }

    func post(_ path: String, body: [String: Any]) async throws -> Any? {
        var answer: [String: Any]

        switch path {
        case "v1/transactions/add.json":
            let session = body["clientSessionId"] as? String ?? ""

            if let id = sessions[session], let added = transactions[id] {
                // the server's duplicate check: the same clientSessionId answers with what it added the first time
                answer = added
            } else {
                nextId += 1
                answer = body
                answer.removeValue(forKey: "clientSessionId")
                answer["id"] = String(nextId)
                transactions[String(nextId)] = answer
                sessions[session] = String(nextId)
            }
        case "v1/transactions/modify.json":
            answer = body
            transactions[body["id"] as? String ?? ""] = answer
        default:
            throw APIError(httpStatus: 404, errorCode: 0, message: path)
        }

        if loseAnswers {
            throw APIError.unreachable("lost")
        }

        return answer
    }
}

@MainActor
final class SyncTests: XCTestCase {
    private var server: Server!

    override func setUp() {
        super.setUp()
        server = Server(id: "sync-test-" + UUID().uuidString, name: "", url: "http://127.0.0.1:9")
        server.userJson = #"{"username":"alex"}"#
    }

    override func tearDown() {
        Sync.store.removeAll(serverId: server.id)
        super.tearDown()
    }

    private func coffee(_ amount: Int) -> [String: Any] {
        [
            "type": 3, "categoryId": "21", "sourceAccountId": "107", "sourceAmount": amount, "time": 1_700_000_000,
            "utcOffset": 0, "comment": "", "merchant": "Corner Cafe", "projectId": "0", "tagIds": [String](),
            "pictureIds": [String](), "hideAmount": false, "clientSessionId": "abc",
        ]
    }

    /// The server adds the purchase but its answer is lost; the user changes £4.50 to £5.00 before the next try. The
    /// server's duplicate check answers that try with the £4.50 it has, so the £5.00 must still be sent, as a change.
    func testAnEditAfterALostAnswerChangesWhatTheServerAdded() async throws {
        let remote = FakeServer()
        let added = Sync.queue(server, bookId: nil, kind: .add, transactionId: nil, body: coffee(450), base: nil, labels: [:])

        remote.loseAnswers = true

        do {
            try await Sync.send(added, client: remote)
            XCTFail("the answer should have been lost")
        } catch let error as APIError {
            XCTAssertTrue(error.unreachable)
        }

        XCTAssertEqual(remote.transactions.count, 1)

        // the add form was opened before the try, so it has the change as it was then
        let edited = Sync.saveEdit(server, change: added, body: coffee(500), labels: [:])
        XCTAssertEqual(edited.kind, .add)
        XCTAssertEqual(edited.attempts, 1, "the edit must not forget that the add may be on the server")

        remote.loseAnswers = false
        try await Sync.send(try XCTUnwrap(Sync.store.change(added.id)), client: remote)

        let modify = try XCTUnwrap(Sync.store.change(added.id), "the £5.00 was dropped as sent")
        XCTAssertEqual(modify.kind, .modify)
        XCTAssertNil(modify.body["clientSessionId"])
        XCTAssertEqual(JSONObject(modify.base ?? [:]).int64("sourceAmount"), 450)

        try await Sync.send(modify, client: remote)

        XCTAssertNil(Sync.store.change(added.id))
        XCTAssertEqual(remote.transactions.count, 1)
        XCTAssertEqual(remote.transactions.values.first.map { JSONObject($0).int64("sourceAmount") }, 500)
    }

    /// The add form saves again after sending turned the add into a change: it stays a change of that transaction.
    func testAnEditOfAnAddThatBecameAChangeStaysAChange() async throws {
        let remote = FakeServer()
        let added = Sync.queue(server, bookId: nil, kind: .add, transactionId: nil, body: coffee(450), base: nil, labels: [:])
        remote.loseAnswers = true
        _ = try? await Sync.send(added, client: remote)
        Sync.saveEdit(server, change: added, body: coffee(500), labels: [:])
        remote.loseAnswers = false
        try await Sync.send(try XCTUnwrap(Sync.store.change(added.id)), client: remote)

        let again = Sync.saveEdit(server, change: added, body: coffee(550), labels: [:])
        XCTAssertEqual(again.kind, .modify)
        XCTAssertNil(again.body["clientSessionId"])
        XCTAssertNotNil(again.body["id"])

        try await Sync.send(again, client: remote)
        XCTAssertEqual(remote.transactions.count, 1)
        XCTAssertEqual(remote.transactions.values.first.map { JSONObject($0).int64("sourceAmount") }, 550)
    }

    /// An add whose first answer arrives is simply sent.
    func testAnAnsweredAddIsSent() async throws {
        let remote = FakeServer()
        let added = Sync.queue(server, bookId: nil, kind: .add, transactionId: nil, body: coffee(450), base: nil, labels: [:])
        try await Sync.send(added, client: remote)
        XCTAssertNil(Sync.store.change(added.id))
        XCTAssertEqual(remote.transactions.count, 1)
    }
}
