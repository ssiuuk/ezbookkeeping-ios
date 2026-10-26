import XCTest
@testable import EzBookkeeping

final class PurchaseTests: XCTestCase {
    func testApplePayAutomationValues() throws {
        let purchase = try XCTUnwrap(Purchase.from(merchant: " Corner Café ", amount: "£4.50", card: "Visa •••• 1234"))
        XCTAssertEqual(purchase.amount, 450)
        XCTAssertEqual(purchase.currency, "GBP")
        XCTAssertEqual(purchase.merchant, "Corner Café")
        XCTAssertEqual(purchase.card, "Visa •••• 1234")
        XCTAssertEqual(purchase.cardKey, "1234")
        XCTAssertFalse(purchase.refund)
    }

    func testAmountsInOtherShapes() throws {
        XCTAssertEqual(Purchase.from(merchant: "", amount: "HK$12.50", card: "")?.currency, "HKD")
        XCTAssertEqual(Purchase.from(merchant: "", amount: "12,50 €", card: "")?.amount, 1250)
        XCTAssertEqual(Purchase.from(merchant: "", amount: "USD 1,234.56", card: "")?.amount, 123456)

        // a bare number leaves the currency to the account
        let plain = try XCTUnwrap(Purchase.from(merchant: "", amount: "4.50", card: "Amex"))
        XCTAssertEqual(plain.amount, 450)
        XCTAssertEqual(plain.currency, "")
        XCTAssertEqual(plain.cardKey, "amex")

        XCTAssertTrue(Purchase.from(merchant: "", amount: "-£3.20", card: "")?.refund ?? false)
        XCTAssertNil(Purchase.from(merchant: "Shop", amount: "free", card: ""))
        XCTAssertNil(Purchase.from(merchant: "Shop", amount: "£0.00", card: ""))
    }

    func testPaymentMessages() throws {
        let wallet = try XCTUnwrap(Purchase.parse(title: "Corner Café", text: "HK$12.50 with Visa •••• 1234"))
        XCTAssertEqual(wallet.amount, 1250)
        XCTAssertEqual(wallet.currency, "HKD")
        XCTAssertEqual(wallet.merchant, "Corner Café")
        XCTAssertEqual(wallet.card, "Visa •••• 1234")
        XCTAssertEqual(wallet.cardKey, "1234")

        let bank = try XCTUnwrap(Purchase.parse(title: "", text: "You spent £8.20 at Green Grocer"))
        XCTAssertEqual(bank.amount, 820)
        XCTAssertEqual(bank.merchant, "Green Grocer")

        XCTAssertNil(Purchase.parse(title: "Hello", text: "See you at 5"))
    }

    func testNumbers() {
        XCTAssertEqual(Purchase.parseNumber("1,234"), 123400)
        XCTAssertEqual(Purchase.parseNumber("1.234"), 123400)
        XCTAssertEqual(Purchase.parseNumber("12,5"), 1250)
        XCTAssertEqual(Purchase.parseNumber("1 234,56"), 123456)
    }

    func testPendingListKeepsRepeatsApartFromDoubleRuns() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "pending-purchases-test"))
        defaults.removePersistentDomain(forName: "pending-purchases-test")
        let coffee = try XCTUnwrap(Purchase.from(merchant: "Corner Café", amount: "£4.50", card: "Visa •••• 1234"))
        let now = Date()

        let first = try XCTUnwrap(PendingPurchases.add(coffee, time: now, source: "test", defaults: defaults))
        // the same automation running twice for one tap
        XCTAssertNil(PendingPurchases.add(coffee, time: now.addingTimeInterval(2), source: "test", defaults: defaults))
        // a second coffee later on is a purchase of its own
        XCTAssertNotNil(PendingPurchases.add(coffee, time: now.addingTimeInterval(600), source: "test", defaults: defaults))
        XCTAssertEqual(PendingPurchases.list(defaults: defaults).count, 2)

        PendingPurchases.remove(first.id, defaults: defaults)
        XCTAssertEqual(PendingPurchases.list(defaults: defaults).count, 1)

        PendingPurchases.restore(first, defaults: defaults)
        XCTAssertEqual(PendingPurchases.list(defaults: defaults).map(\.id).last, first.id)
    }
}
