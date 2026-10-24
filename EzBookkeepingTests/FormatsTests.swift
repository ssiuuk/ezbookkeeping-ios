import SwiftUI
import XCTest
@testable import EzBookkeeping

final class FormatsTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let uk = Locale(identifier: "en_GB")

    func testAmountsAreCentsInTheAccountsCurrency() {
        XCTAssertEqual(Formats.amount(123456, currency: "USD", locale: us), "$1,234.56")
        XCTAssertEqual(Formats.amount(1250, currency: "GBP", locale: uk), "£12.50")
        XCTAssertEqual(Formats.amount(0, currency: "USD", locale: us), "$0.00")
        XCTAssertEqual(Formats.amount(7, currency: "USD", locale: us), "$0.07")
    }

    func testNegativeAmountsUseARealMinusSign() {
        XCTAssertEqual(Formats.amount(-500, currency: "USD", locale: us), "\u{2212}$5.00")
        XCTAssertEqual(Formats.signedAmount(-500, currency: "USD", negative: true, locale: us), "\u{2212}$5.00")
        XCTAssertEqual(Formats.signedAmount(500, currency: "USD", negative: false, locale: us), "+$5.00")
    }

    func testAmountWithoutCurrencyIsAPlainNumber() {
        XCTAssertEqual(Formats.amount(123456, currency: "", locale: us), "1,234.56")
    }

    func testParsingTypedAmounts() {
        XCTAssertEqual(Formats.parseAmount("12.50"), 1250)
        XCTAssertEqual(Formats.parseAmount("12.5"), 1250)
        XCTAssertEqual(Formats.parseAmount("12"), 1200)
        XCTAssertEqual(Formats.parseAmount("12,5"), 1250)
        XCTAssertEqual(Formats.parseAmount("1,234.56"), 123456)
        XCTAssertEqual(Formats.parseAmount("1.234,56"), 123456)
        XCTAssertEqual(Formats.parseAmount(" 1 234.56 "), 123456)
        XCTAssertEqual(Formats.parseAmount(".5"), 50)
        XCTAssertEqual(Formats.parseAmount("0.005"), 1)
        XCTAssertEqual(Formats.parseAmount("-3"), -300)
        XCTAssertNil(Formats.parseAmount(""))
        XCTAssertNil(Formats.parseAmount("abc"))
        XCTAssertNil(Formats.parseAmount("12abc"))
        XCTAssertNil(Formats.parseAmount("1.2.3"))
    }

    func testEditableAmount() {
        XCTAssertEqual(Formats.editableAmount(1250), "12.50")
        XCTAssertEqual(Formats.editableAmount(5), "0.05")
        XCTAssertEqual(Formats.editableAmount(-1234), "-12.34")
        XCTAssertEqual(Formats.parseAmount(Formats.editableAmount(987654)), 987654)
    }

    func testPeriodQueryCoversTheRightDays() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // Wednesday 15 May 2024, 10:00 UTC
        let now = Date(timeIntervalSince1970: 1_715_767_200)
        let query = Formats.periodQuery(now: now, firstDayOfWeek: 1, calendar: calendar)
        let parts = Dictionary(uniqueKeysWithValues: query.split(separator: "|").map { item -> (String, [Int64]) in
            let pieces = item.split(separator: "_")
            return (String(pieces[0]), pieces.dropFirst().compactMap { Int64($0) })
        })

        XCTAssertEqual(parts["today"], [1_715_731_200, 1_715_817_599])
        // the week starts on Monday 13 May
        XCTAssertEqual(parts["thisWeek"], [1_715_558_400, 1_716_163_199])
        XCTAssertEqual(parts["thisMonth"], [1_714_521_600, 1_717_199_999])
        XCTAssertEqual(parts["lastMonth"], [1_711_929_600, 1_714_521_599])
        XCTAssertEqual(parts["thisYear"], [1_704_067_200, 1_735_689_599])
    }

    func testPeriodQueryWeekStartingOnSunday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_715_767_200)
        let query = Formats.periodQuery(now: now, firstDayOfWeek: 0, calendar: calendar)
        // Sunday 12 May 2024
        XCTAssertTrue(query.contains("thisWeek_1715472000_"))
    }

    func testDayHeaders() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_715_767_200)
        XCTAssertEqual(Formats.dayHeader(now.addingTimeInterval(-3600), now: now, calendar: calendar), "Today")
        XCTAssertEqual(Formats.dayHeader(now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
    }

    func testInitialsAndColors() {
        XCTAssertEqual(Formats.initial("  restaurants"), "R")
        XCTAssertEqual(Formats.initial(""), "?")
        XCTAssertNotNil(Color(hex: "ff6b22"))
        XCTAssertNil(Color(hex: "zzz"))
    }
}
