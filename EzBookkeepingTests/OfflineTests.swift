import XCTest
@testable import EzBookkeeping

final class OfflineTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("offline-test-" + UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    func testAnswersAreKeptPerServerUserAndBook() throws {
        let store = LocalStore(folder: folder)
        store.putCached(serverId: "s1", userName: "alex", bookId: nil, path: "v1/accounts/list.json", result: [["id": "1", "name": "Cash"]])

        let cached = try XCTUnwrap(store.getCached(serverId: "s1", userName: "alex", bookId: nil, path: "v1/accounts/list.json"))
        XCTAssertEqual((cached.result as? [[String: Any]])?.first?["name"] as? String, "Cash")
        XCTAssertNil(store.getCached(serverId: "s1", userName: "alex", bookId: "7", path: "v1/accounts/list.json"))
        XCTAssertNil(store.getCached(serverId: "s2", userName: "alex", bookId: nil, path: "v1/accounts/list.json"))
        XCTAssertNil(store.getCached(serverId: "s1", userName: "sam", bookId: nil, path: "v1/accounts/list.json"))

        store.clearCache(serverId: "s1")
        XCTAssertNil(store.getCached(serverId: "s1", userName: "alex", bookId: nil, path: "v1/accounts/list.json"))
    }

    /// Alex's sign-in expires, Sam signs in on the same server, and then the server can't be reached: Sam doesn't see
    /// Alex's copy, while Alex (or the widget, which asks as the user the app shares) still sees it.
    func testAnotherUserOfTheServerDoesNotSeeTheCopy() async throws {
        let serverId = "offline-test-" + UUID().uuidString
        defer { LocalStore.shared.clearCache(serverId: serverId) }

        // nothing listens on port 9, so the server can't be reached
        var server = Server(id: serverId, name: "", url: "http://127.0.0.1:9")
        server.token = "token"
        server.userJson = #"{"username":"alex"}"#
        LocalStore.shared.putCached(serverId: serverId, userName: "alex", bookId: nil, path: "v1/accounts/list.json",
                                    result: [["id": "1", "name": "Alex's cash"]])

        let alexs = try await server.client().load("v1/accounts/list.json")
        XCTAssertNotNil(alexs.savedAt)
        XCTAssertEqual((alexs.value as? [[String: Any]])?.first?["name"] as? String, "Alex's cash")

        // the expired sign-in is forgotten: no user, so no copy
        server.userJson = nil
        XCTAssertEqual(server.client().cacheUserName, "")
        await assertUnreachable(server.client())

        server.userJson = #"{"username":"sam"}"#
        await assertUnreachable(server.client())
    }

    private func assertUnreachable(_ client: APIClient, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.load("v1/accounts/list.json")
            XCTFail("answered with another user's copy", file: file, line: line)
        } catch let error as APIError {
            XCTAssertTrue(error.unreachable, file: file, line: line)
        } catch {
            XCTFail("\(error)", file: file, line: line)
        }
    }

    func testChangesSurviveARestartAndKeepTheirRevision() throws {
        let store = LocalStore(folder: folder)
        var change = LocalStore.Change(serverId: "s1", userName: "alex", kind: .add, transactionId: nil, bodyText: "{}")
        change.body = ["type": 3, "sourceAmount": 450, "clientSessionId": "abc"]
        change = store.insert(change)
        XCTAssertGreaterThan(change.id, 0)

        // the user edits it while it is being sent: the send's own write must not win
        var edited = change
        edited.body = ["type": 3, "sourceAmount": 500, "clientSessionId": "abc"]
        let saved = try XCTUnwrap(store.update(edited))
        XCTAssertEqual(saved.revision, change.revision + 1)
        XCTAssertFalse(store.removeIfUnchanged(change))

        let reopened = LocalStore(folder: folder)
        let restored = try XCTUnwrap(reopened.change(change.id))
        XCTAssertEqual(JSONObject(restored.body).int64("sourceAmount"), 500)
        XCTAssertTrue(reopened.removeIfUnchanged(restored))
        XCTAssertNil(reopened.change(change.id))
    }

    func testSentChangesAreRememberedForAnOpenForm() {
        let store = LocalStore(folder: folder)
        let change = store.insert(LocalStore.Change(serverId: "s1", userName: "alex", kind: .add, transactionId: nil, bodyText: "{}"))
        store.markSent(change, transactionId: "99", serverCopy: ["id": "99"])
        XCTAssertEqual(store.sent(change.id)?.transactionId, "99")
        XCTAssertEqual(store.sent(change.id)?.serverCopy?["id"] as? String, "99")
    }

    @MainActor
    func testVersionsCompareWhatTheAppShowsAndSends() {
        let server: [String: Any] = [
            "id": "99", "type": 3, "categoryId": "21", "sourceAccountId": "107", "sourceAmount": 450, "time": 1_700_000_000,
            "utcOffset": 60, "comment": "Coffee ", "merchant": "Corner Café", "projectId": "0", "tagIds": ["2", "1"],
            "pictures": [["pictureId": "5", "originalUrl": "http://x/pictures/5.jpg"]], "hideAmount": false,
        ]
        let sent: [String: Any] = [
            "id": "99", "type": 3, "categoryId": "21", "sourceAccountId": "107", "sourceAmount": 450, "time": 1_700_000_000,
            "utcOffset": 60, "comment": "Coffee", "merchant": "Corner Café", "projectId": "0", "tagIds": ["1", "2"],
            "pictureIds": ["5"], "hideAmount": false, "destinationAccountId": "0", "destinationAmount": 0,
        ]
        XCTAssertTrue(Sync.same(server, sent))

        var changed = sent
        changed["sourceAmount"] = 500
        changed["comment"] = "Coffee and cake"
        XCTAssertFalse(Sync.same(server, changed))
        XCTAssertEqual(Sync.differences(changed, server), ["sourceAmount", "comment"])

        var newPhoto = sent
        newPhoto["pictureIds"] = ["5", "6"]
        XCTAssertEqual(Sync.differences(newPhoto, server), ["pictureIds"])
    }

    func testAPhoneVersionReadsAsATransaction() {
        let record = TransactionRecord(json: JSONObject([
            "type": 3, "categoryId": "21", "sourceAccountId": "107", "sourceAmount": 450, "time": 1_700_000_000,
            "tagIds": ["1"], "pictureIds": ["5", "6"], "merchant": "Corner Café",
        ] as [String: Any]))
        XCTAssertEqual(record.sourceAmount, 450)
        XCTAssertEqual(record.pictureIds, ["5", "6"])
        XCTAssertTrue(record.editable)
    }
}
