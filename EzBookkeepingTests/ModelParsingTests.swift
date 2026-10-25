import XCTest
@testable import EzBookkeeping

/// Reads responses shaped like the server's (ids as strings, amounts sometimes as strings) into the app's models.
final class ModelParsingTests: XCTestCase {
    private func result(_ json: String) throws -> Any? {
        try APIClient.result(of: Data(json.utf8), status: 200)
    }

    func testEnvelopeReturnsResult() throws {
        let value = try result(#"{"success":true,"result":{"token":"ey123","need2FA":false}}"#)
        XCTAssertEqual(JSONObject(value).string("token"), "ey123")
        XCTAssertFalse(JSONObject(value).bool("need2FA"))
    }

    func testEnvelopeErrorCarriesServerMessage() {
        XCTAssertThrowsError(try APIClient.result(of: Data(#"{"success":false,"errorCode":201001,"errorMessage":"user not found"}"#.utf8), status: 400)) { error in
            let apiError = error as? APIError
            XCTAssertEqual(apiError?.httpStatus, 400)
            XCTAssertEqual(apiError?.errorCode, 201001)
            XCTAssertEqual(apiError?.message, "user not found")
        }
    }

    func testNotFoundWithoutJSONMeansMissingFeature() {
        XCTAssertThrowsError(try APIClient.result(of: Data("404 page not found".utf8), status: 404)) { error in
            XCTAssertEqual((error as? APIError)?.isNotFound, true)
        }
    }

    func testUnauthorizedIsRecognised() {
        XCTAssertThrowsError(try APIClient.result(of: Data(#"{"success":false,"errorCode":202001,"errorMessage":"unauthorized"}"#.utf8), status: 401)) { error in
            XCTAssertEqual((error as? APIError)?.isUnauthorized, true)
        }
    }

    func testAccountsWithSubAccounts() throws {
        let value = try result("""
        {"success":true,"result":[
          {"id":"101","name":"Wallet","parentId":"0","category":1,"type":1,"color":"ff9800","currency":"GBP","balance":"8000","hidden":false},
          {"id":"102","name":"Bank","parentId":"0","category":2,"type":2,"color":"1e88e5","currency":"GBP","balance":"0","hidden":false,
           "subAccounts":[
             {"id":"103","name":"Savings","parentId":"102","category":2,"type":1,"currency":"GBP","balance":"120000","hidden":false},
             {"id":"104","name":"Bank Current","parentId":"102","category":2,"type":1,"currency":"GBP","balance":"-500","hidden":false},
             {"id":"105","name":"Old","parentId":"102","category":2,"type":1,"currency":"GBP","balance":"1","hidden":true}
           ]},
          {"id":"106","name":"Hidden","parentId":"0","category":1,"type":1,"currency":"GBP","balance":"5","hidden":true},
          {"id":"107","name":"Card","parentId":"0","category":3,"type":1,"currency":"GBP","balance":-32000,"isLiability":true,"sharedBy":"Alex"}
        ]}
        """)

        let accounts = Account.parseList(value)
        XCTAssertEqual(accounts.count, 4)
        XCTAssertEqual(accounts[0].balance, 8000)
        XCTAssertEqual(accounts[1].subAccounts.count, 3)
        XCTAssertEqual(accounts[1].totalBalance, 120000 - 500 + 1)
        XCTAssertEqual(accounts[3].balance, -32000)
        XCTAssertTrue(accounts[3].isLiability)
        XCTAssertEqual(accounts[3].sharedBy, "Alex")

        let selectable = Account.selectable(accounts)
        XCTAssertEqual(selectable.map(\.id), ["101", "103", "104", "107"])
        XCTAssertEqual(selectable[1].name, "Bank · Savings")
        // a sub-account already named after its parent keeps its name
        XCTAssertEqual(selectable[2].name, "Bank Current")
    }

    func testCategoriesGroupedByType() throws {
        let value = try result("""
        {"success":true,"result":{
          "1":[{"id":"1","name":"Salary","parentId":"0","type":1,"icon":"1","color":"43a047","subCategories":[{"id":"11","name":"Bonus","parentId":"1","type":1}]}],
          "2":[{"id":"2","name":"Food","parentId":"0","type":2,"icon":"1","color":"ff6b22","subCategories":[{"id":"21","name":"Restaurants","parentId":"2","type":2,"hidden":false}]},
               {"id":"3","name":"Old","parentId":"0","type":2,"hidden":true,"subCategories":[]}]
        }}
        """)

        let byType = TransactionCategory.parseAllTypes(value)
        XCTAssertEqual(byType[CategoryType.income]?.first?.subCategories.first?.name, "Bonus")
        XCTAssertEqual(byType[CategoryType.expense]?.map(\.name), ["Food"])
        XCTAssertEqual(byType[CategoryType.expense]?.first?.icon, "1")
        XCTAssertEqual(byType[CategoryType.transfer]?.count, 0)
        XCTAssertEqual(CategoryType.of(transactionType: TransactionType.transfer), CategoryType.transfer)
        XCTAssertEqual(CategoryType.of(transactionType: TransactionType.expense), CategoryType.expense)
    }

    func testTransactionPage() throws {
        let value = try result("""
        {"success":true,"result":{"items":[
          {"id":"9001","timeSequenceId":"1700000000123","type":3,"categoryId":"21","category":{"name":"Restaurants","color":"ff6b22"},
           "time":1700000000,"utcOffset":60,"sourceAccountId":"107","sourceAccount":{"name":"Card","currency":"GBP"},
           "destinationAccountId":"0","sourceAmount":1250,"hideAmount":false,"tagIds":["5","6"],"tags":[{"id":"5","name":"Trip"}],
           "pictures":[{"pictureId":"77","originalUrl":"http://x/pictures/77.jpg"}],
           "comment":"Lunch","merchant":"Corner Café","projectId":"301","editable":true,
           "geoLocation":{"latitude":51.5,"longitude":-0.1}}
        ],"nextTimeSequenceId":"1700000000000"}}
        """)

        let page = TransactionPage.parse(value)
        XCTAssertEqual(page.nextTimeSequenceId, "1700000000000")
        let transaction = try XCTUnwrap(page.items.first)
        XCTAssertEqual(transaction.id, "9001")
        XCTAssertEqual(transaction.type, TransactionType.expense)
        XCTAssertEqual(transaction.categoryName, "Restaurants")
        XCTAssertEqual(transaction.sourceAccountName, "Card")
        XCTAssertEqual(transaction.sourceCurrency, "GBP")
        XCTAssertEqual(transaction.sourceAmount, 1250)
        XCTAssertEqual(transaction.destinationAmount, 0)
        XCTAssertEqual(transaction.tagIds, ["5", "6"])
        XCTAssertEqual(transaction.tagNames, ["Trip"])
        XCTAssertEqual(transaction.pictureIds, ["77"])
        XCTAssertEqual(transaction.merchant, "Corner Café")
        XCTAssertEqual(transaction.projectId, "301")
        XCTAssertEqual(transaction.utcOffset, 60)
        XCTAssertNotNil(transaction.geoLocation)
        XCTAssertEqual(TransactionText.subtitle(transaction), "Lunch · Card")
    }

    func testLastPageHasNoNextId() {
        XCTAssertNil(TransactionPage.parse(JSONObject.parse(#"{"items":[],"nextTimeSequenceId":null}"#).raw).nextTimeSequenceId)
        XCTAssertNil(TransactionPage.parse(JSONObject.parse(#"{"items":[],"nextTimeSequenceId":"0"}"#).raw).nextTimeSequenceId)
        XCTAssertNil(TransactionPage.parse(JSONObject.parse(#"{"items":[]}"#).raw).nextTimeSequenceId)
    }

    func testBooks() {
        let books = Book.parseList(JSONObject.parse("""
        {"r":[{"id":"1","name":"Alex","isPersonal":true,"isOwner":true},
              {"id":"2","name":"Family","ownerNickname":"Alex","isPersonal":false,"isOwner":true},
              {"id":"3","name":"Flat","ownerNickname":"Sam","isPersonal":false,"isOwner":false}]}
        """).raw["r"])
        XCTAssertEqual(books.map(\.label), ["My book", "Family", "Flat · Shared by Sam"])
    }

    func testPeriodAmountsAndExchangeRates() {
        let amounts = PeriodAmounts.parseAll(JSONObject.parse("""
        {"thisMonth":{"startTime":1,"endTime":2,"amounts":[{"currency":"GBP","incomeAmount":"285000","expenseAmount":"162000"},
                                                            {"currency":"EUR","incomeAmount":"0","expenseAmount":"1000"}]},
         "today":{"amounts":[]}}
        """).raw)
        XCTAssertEqual(amounts["thisMonth"]?.items.first, PeriodAmounts.Item(currency: "GBP", income: 285000, expense: 162000))
        XCTAssertEqual(amounts["today"]?.items.count, 0)

        let rates = ExchangeRates.parse(JSONObject.parse("""
        {"baseCurrency":"EUR","exchangeRates":[{"currency":"GBP","rate":"0.5"},{"currency":"USD","rate":"bad"}]}
        """).raw)
        XCTAssertEqual(rates.convert(1000, from: "EUR", to: "GBP"), 500)
        XCTAssertEqual(rates.convert(500, from: "GBP", to: "EUR"), 1000)
        XCTAssertNil(rates.convert(100, from: "USD", to: "GBP"))
        XCTAssertEqual(rates.convert(100, from: "JPY", to: "JPY"), 100)

        let server = serverWithUser(#"{"defaultCurrency":"GBP"}"#)
        let summary = Summary(server: server, amounts: amounts, accounts: [], rates: rates)
        XCTAssertEqual(summary.period("thisMonth").income, 285000)
        XCTAssertEqual(summary.period("thisMonth").expense, 162000 + 500)
        XCTAssertTrue(summary.unconverted.isEmpty)
    }

    func testServerSettingsScript() {
        let script = "window.EZBOOKKEEPING_SERVER_SETTINGS={};EZBOOKKEEPING_SERVER_SETTINGS['a']=0;EZBOOKKEEPING_SERVER_SETTINGS[\"o\"] = 1;"
        let info = ServerInfo.parse(script: script)
        XCTAssertEqual(info?.internalAuth, false)
        XCTAssertEqual(info?.oauth2, true)
        XCTAssertEqual(info?.register, false)
        XCTAssertEqual(info?.pictures, true)
        XCTAssertNil(ServerInfo.parse(script: "<html>not a server</html>"))
    }

    func testServerAddressIsNormalised() {
        XCTAssertEqual(Server.normalizeURL("money.example.com"), "https://money.example.com")
        XCTAssertEqual(Server.normalizeURL(" http://192.168.1.10:8080/ "), "http://192.168.1.10:8080")
        XCTAssertEqual(Server.normalizeURL("https://Example.com/ezb/mobile"), "https://example.com/ezb")
        XCTAssertEqual(Server.normalizeURL("http://localhost:8080/desktop#/"), "http://localhost:8080")
        XCTAssertNil(Server.normalizeURL("ftp://example.com"))
        XCTAssertNil(Server.normalizeURL(""))
    }

    func testServerKeepsTokenOutOfSavedSettings() throws {
        var server = Server(name: "Home", url: "http://localhost:8080")
        server.token = "secret"
        server.userJson = #"{"nickname":"Alex","username":"demo","defaultCurrency":"GBP"}"#
        let data = try JSONEncoder().encode([server])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))

        let decoded = try JSONDecoder().decode([Server].self, from: data)
        XCTAssertNil(decoded.first?.token)
        XCTAssertEqual(decoded.first?.userDisplayName, "Alex")
        XCTAssertEqual(decoded.first?.defaultCurrency, "GBP")
    }

    func testRecentChoicesArePerServerAndBook() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "recent-choices-test"))
        defaults.removePersistentDomain(forName: "recent-choices-test")
        let mine = RecentChoices(serverId: "s1", bookId: nil, defaults: defaults)
        let family = RecentChoices(serverId: "s1", bookId: "2", defaults: defaults)

        mine.remember(type: TransactionType.expense, categoryId: "21", accountId: "107", destinationAccountId: nil)
        mine.rememberMerchant(" Corner Café ", categoryId: "21", accountId: "108")
        mine.rememberCard("1234", accountId: "109")

        XCTAssertEqual(mine.accountForCategory("21", destination: false), "107")
        XCTAssertEqual(mine.accountForType(TransactionType.expense, destination: false), "107")
        XCTAssertNil(mine.accountForType(TransactionType.expense, destination: true))
        XCTAssertEqual(mine.categoryForMerchant("corner café"), "21")
        XCTAssertEqual(mine.accountForMerchant("CORNER CAFÉ"), "108")
        XCTAssertEqual(mine.accountForCard("1234"), "109")
        XCTAssertNil(mine.accountForCard(""))
        XCTAssertNil(family.accountForMerchant("Corner Café"))
        XCTAssertNil(family.accountForCategory("21", destination: false))
    }

    private func serverWithUser(_ json: String) -> Server {
        var server = Server(name: "", url: "http://localhost:8080")
        server.userJson = json
        return server
    }
}
