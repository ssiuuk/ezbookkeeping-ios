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

    func testAnswersAreKeptPerServerAndBook() throws {
        let store = LocalStore(folder: folder)
        store.putCached(serverId: "s1", bookId: nil, path: "v1/accounts/list.json", result: [["id": "1", "name": "Cash"]])

        let cached = try XCTUnwrap(store.getCached(serverId: "s1", bookId: nil, path: "v1/accounts/list.json"))
        XCTAssertEqual((cached.result as? [[String: Any]])?.first?["name"] as? String, "Cash")
        XCTAssertNil(store.getCached(serverId: "s1", bookId: "7", path: "v1/accounts/list.json"))
        XCTAssertNil(store.getCached(serverId: "s2", bookId: nil, path: "v1/accounts/list.json"))

        store.clearCache(serverId: "s1")
        XCTAssertNil(store.getCached(serverId: "s1", bookId: nil, path: "v1/accounts/list.json"))
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
