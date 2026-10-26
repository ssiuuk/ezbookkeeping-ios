import XCTest

/// Walks through the main screens against a seeded test server and saves a screenshot of each,
/// so changes to the app can be reviewed without a phone. Mirrors the Android app's ScreenshotTest.
///
/// The server comes from `scripts/seed-test-server.sh` (user demo / demo123456, with a "Family" book,
/// projects and a shared credit card). CI passes `TEST_RUNNER_SERVER_URL` and `TEST_RUNNER_SCREENSHOTS_DIR`,
/// which reach this test as `SERVER_URL` and `SCREENSHOTS_DIR`. Screenshots are also kept as attachments
/// in the test result bundle.
final class ScreenshotTests: XCTestCase {
    private struct WalkthroughError: Error, CustomStringConvertible {
        let description: String
    }

    private var app: XCUIApplication!
    private var screenshotDir: URL?
    private let timeout: TimeInterval = 30

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let path = environment["SCREENSHOTS_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("ezb-screens")
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        screenshotDir = dir
    }

    override func tearDownWithError() throws {
        if let run = testRun, !run.hasSucceeded, app != nil {
            shot("99-failure")

            if let dir = screenshotDir {
                try? app.debugDescription.write(to: dir.appendingPathComponent("99-hierarchy.txt"), atomically: true, encoding: .utf8)
            }
        }
    }

    func testTourOfTheApp() throws {
        let environment = ProcessInfo.processInfo.environment
        let serverURL = environment["SERVER_URL"].flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:8080"
        // a retried run talks to the same server, so this run's transaction gets its own description
        let lunch = "Lunch \(Int.random(in: 1000...9999))"

        app = XCUIApplication()
        app.launchArguments = ["-resetForUITesting", "-disableAnimations"]
        app.launch()

        // MARK: Server and sign-in

        let address = app.textFields["server_address"]
        try waitFor(address, "server address field")
        settle()
        shot("01-welcome")
        try type(serverURL, into: address)
        // the keyboard's Go key connects, so the test doesn't depend on the keyboard leaving the button visible
        try type("Home\n", into: app.textFields["server_name"])

        let loginName = app.textFields["login_name"]

        // checking the server can take a while; only fall back to the button while the form is still showing
        if !loginName.waitForExistence(timeout: 20) && address.exists {
            try tap(app.buttons["connect_button"], "Connect button")
        }

        try waitFor(loginName, "sign-in form")
        settle()
        shot("02-sign-in")
        try type("demo", into: loginName)
        try type("demo123456\n", into: app.secureTextFields["password"])

        let overviewTab = app.tabBars.buttons["Overview"]

        if !overviewTab.waitForExistence(timeout: 20) && app.buttons["sign_in_button"].exists {
            try tap(app.buttons["sign_in_button"], "Sign in button")
        }

        try waitFor(overviewTab, "tab bar")

        // MARK: Main screens

        try waitFor(element(containing: "Weekly shop"), "the seeded transactions on the overview")
        settle()
        shot("03-overview")

        try tap(app.tabBars.buttons["Transactions"], "Transactions tab")
        try waitFor(element(containing: "Dinner with friends"), "the transactions list")
        settle()
        shot("04-transactions")

        try tap(app.tabBars.buttons["Accounts"], "Accounts tab")
        try waitFor(element(containing: "Savings"), "the accounts list")
        settle()
        shot("05-accounts")

        try tap(app.tabBars.buttons["More"], "More tab")
        try waitFor(app.buttons["Reports"], "the More list")
        settle()
        shot("06-more")

        // MARK: Add a transaction

        try tap(overviewTab, "Overview tab")
        try openEditor(app.buttons["add_transaction"])
        // the test server has a shared "Family" book, so the book row is offered
        try waitFor(app.buttons["book"], "book row")
        settle()
        shot("07-add-transaction")

        // the amount has the app's own number pad, with + − × ÷ for working out a sum: 10 + 2.50
        let amount = app.buttons["amount"]
        try waitFor(app.buttons["pad_ok"], "the number pad")
        try typeOnPad("10+2.50")
        try waitFor(app.staticTexts["amount_sum"], "the sum's result")
        settle()
        shot("07b-amount-sum")
        try tap(app.buttons["pad_ok"], "the = key")
        try waitForValue(of: amount, toContain: "12.50")
        try tap(app.buttons["pad_ok"], "the OK key")
        try waitForGone(app.buttons["pad_ok"], "the number pad closing")
        try choose("category", "Restaurants", screenshot: "08-choose-category")
        try choose("account", "Credit card", screenshot: "09-choose-account")
        try waitForValue(of: app.buttons["account"], toContain: "Credit card")

        try choose("project", "Holiday")
        try waitForValue(of: app.buttons["project"], toContain: "Holiday")

        try openChoices("merchant", until: app.buttons["add_merchant"])
        try tap(app.buttons["add_merchant"], "Add a merchant")
        try typeInAlert("Corner Cafe")
        try waitForValue(of: app.buttons["merchant"], toContain: "Corner Cafe")

        let comment = app.textFields["comment"]
        try scrollTo(comment, "description field")
        try type(lunch, into: comment)
        dismissKeyboard()
        settle()
        shot("10-filled-transaction")
        try tap(app.buttons["save_button"], "Save button")

        try waitForGone(app.buttons["save_button"], "the add form closing")
        try waitFor(element(containing: lunch), "the new transaction on the overview")
        settle()
        shot("11-overview-after-adding")

        // MARK: Edit it

        try openEditor(element(containing: lunch))
        try waitForValue(of: app.buttons["merchant"], toContain: "Corner Cafe")
        try waitForValue(of: app.buttons["project"], toContain: "Holiday")
        settle()
        shot("12-edit-transaction")
        try closeEditor()

        // MARK: Remembered account and adding a category

        // a new expense in the same category starts with the account used last time
        try openEditor(app.buttons["add_transaction"])
        try choose("category", "Restaurants")
        try waitForValue(of: app.buttons["account"], toContain: "Credit card")
        settle()
        shot("13-remembered-account")

        // a new category can be added to a group straight from the category list
        try openChoices("category", until: app.buttons["add_category"])
        try tap(app.buttons["add_category"], "Add a category")
        try tap(app.buttons["choice:Food"], "the Food group")
        try typeInAlert("Bakery")
        try waitForValue(of: app.buttons["category"], toContain: "Bakery")
        settle()
        shot("14-new-category")
        try closeEditor()

        // MARK: Settings, dark theme and a web page

        try tap(app.tabBars.buttons["More"], "More tab")
        try tap(app.buttons["settings"], "Settings")
        // a menu picker; depending on the iOS version its identifier lands on a button or on the row
        let theme = app.descendants(matching: .any).matching(identifier: "theme").firstMatch
        try waitFor(theme, "theme setting")
        settle()
        shot("15-settings")

        try tap(theme, "theme setting")
        try tap(app.buttons["Dark"], "Dark theme")
        settle()
        shot("16-settings-dark")
        try goBack()

        try tap(app.buttons["Reports"], "Reports")
        try waitFor(app.webViews.firstMatch, "the reports web page")
        // the web app is a large bundle, so give it time to start and draw the report
        _ = app.webViews.firstMatch.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Expense")).firstMatch
            .waitForExistence(timeout: 20)
        Thread.sleep(forTimeInterval: 3)
        shot("17-web-reports")
        try tap(app.buttons["web_done"], "Done")

        try tap(overviewTab, "Overview tab")
        try waitFor(element(containing: lunch), "the overview")
        settle()
        shot("18-overview-dark")

        // MARK: Move to the family book

        // the category and card have the same names in the family book
        try openEditor(element(containing: lunch))
        try waitForValue(of: app.buttons["merchant"], toContain: "Corner Cafe")
        try scrollTo(app.buttons["book"], "book row", up: true)
        try openChoices("book", until: app.buttons["choice:Family"])
        try tap(app.buttons["choice:Family"], "the Family book")
        try tap(app.alerts.buttons["Change"], "Change")
        try waitForValue(of: app.buttons["book"], toContain: "Family")
        try waitForValue(of: app.buttons["category"], toContain: "Restaurants")
        try waitForValue(of: app.buttons["account"], toContain: "Credit card")
        settle()
        shot("19-move-to-family")
        try tap(app.buttons["save_button"], "Save button")
        try waitForGone(app.buttons["save_button"], "the edit form closing")
        try waitForGone(element(containing: lunch), "the moved transaction leaving my book")
        settle()
        shot("20-overview-after-moving")

        // MARK: A purchase to review

        // stands in for an Apple Pay automation in Shortcuts, which can't run in a UI test
        app.terminate()
        app.launchArguments = ["-disableAnimations", "-pendingPurchaseForUITesting"]
        app.launch()

        let purchase = app.buttons["pending:Corner Cafe"]
        try waitFor(purchase, "the purchase to review on the overview")
        settle()
        shot("21-to-review")

        try openEditor(purchase)
        try waitFor(app.navigationBars["Review purchase"], "the review form")
        try waitForValue(of: app.buttons["merchant"], toContain: "Corner Cafe")
        try waitForValue(of: app.buttons["amount"], toContain: "4.50")
        settle()
        shot("22-review-purchase")

        try choose("category", "Restaurants")
        let takePhoto = app.buttons["take_photo"]

        // the server says whether it takes photos
        if takePhoto.waitForExistence(timeout: 5) {
            try scrollTo(takePhoto, "photos section")
            settle()
            shot("23-review-photos")
        }

        try tap(app.buttons["save_button"], "Save button")
        try waitForGone(app.buttons["save_button"], "the review form closing")
        try waitForGone(purchase, "the purchase leaving the To review list")
        settle()
        shot("24-overview-after-review")
    }

    // MARK: - Steps

    /// Opens the add or edit form, tapping again if the first tap was swallowed.
    private func openEditor(_ opener: XCUIElement) throws {
        let amount = app.buttons["amount"]

        for _ in 1...3 {
            try tap(opener, "add or edit")

            if amount.waitForExistence(timeout: 10) {
                // wait until the book's accounts and categories are in
                _ = app.buttons["save_button"].waitForExistence(timeout: 10)
                waitUntilEnabled(app.buttons["save_button"])
                return
            }
        }

        throw WalkthroughError(description: "The transaction form didn't open")
    }

    private func closeEditor() throws {
        try tap(app.buttons["cancel_button"], "Cancel")
        try waitForGone(app.buttons["amount"], "the form closing")
    }

    /// Opens a choice list from a form row, tapping again if it didn't open.
    private func openChoices(_ row: String, until marker: XCUIElement) throws {
        let element = app.buttons[row]
        try scrollTo(element, row + " row")

        for _ in 1...3 {
            try tap(element, row + " row")

            if marker.waitForExistence(timeout: 8) {
                return
            }
        }

        throw WalkthroughError(description: "The \(row) list didn't open")
    }

    private func choose(_ row: String, _ title: String, screenshot: String? = nil) throws {
        let choice = app.buttons["choice:" + title]
        try openChoices(row, until: choice)

        if let screenshot {
            settle()
            shot(screenshot)
        }

        try tap(choice, title)
        try waitForGone(choice, "the \(row) list closing")
    }

    private func typeInAlert(_ text: String) throws {
        let field = app.alerts.textFields.firstMatch
        try waitFor(field, "the alert's text field")

        if !hasKeyboardFocus(field) {
            field.tap()
        }

        field.typeText(text)
        try tap(app.alerts.buttons["Add"], "Add")
        try waitForGone(app.alerts.firstMatch, "the alert closing")
    }

    private func goBack() throws {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        try tap(back, "Back")
    }

    // MARK: - Helpers

    /// Something on screen whose label contains the text, such as a transaction row.
    private func element(containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, _ description: String, timeout: TimeInterval? = nil) throws -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)

        while Date() < deadline {
            if element.waitForExistence(timeout: 2) {
                return element
            }

            dismissSystemPrompts()
        }

        throw WalkthroughError(description: "Not found on screen: \(description)")
    }

    private func waitForGone(_ element: XCUIElement, _ description: String) throws {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if !element.exists {
                return
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        throw WalkthroughError(description: "Still on screen: \(description)")
    }

    private func waitForValue(of element: XCUIElement, toContain text: String) throws {
        try waitFor(element, text)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let value = (element.value as? String) ?? ""

            if value.contains(text) || element.label.contains(text) {
                return
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        throw WalkthroughError(description: "\(element) doesn't show \(text) but \(String(describing: element.value))")
    }

    private func waitUntilEnabled(_ element: XCUIElement) {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline && element.exists && !element.isEnabled {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    /// Taps what the query finds, finding it again and scrolling it into view if needed.
    private func tap(_ element: XCUIElement, _ description: String) throws {
        for attempt in 1...3 {
            dismissSystemPrompts()
            try waitFor(element, description)

            if element.isHittable {
                element.tap()
                return
            }

            if attempt < 3 {
                dismissKeyboard()
                Thread.sleep(forTimeInterval: 1)
            }
        }

        // not reported as hittable (for example under a material), but on screen: tap its middle
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// XCUIElement has no public keyboard focus property, but answers this key.
    private func hasKeyboardFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// Types digits, "." and + − × ÷ on the editor's number pad.
    private func typeOnPad(_ text: String) throws {
        for character in text {
            let name = "+−×÷".contains(character) ? "operator:\(character)" : "key:\(character)"
            try tap(app.buttons[name], "the \(character) key")
        }
    }

    private func type(_ text: String, into element: XCUIElement) throws {
        try waitFor(element, "text field")

        for _ in 1...3 where !hasKeyboardFocus(element) {
            element.tap()
            Thread.sleep(forTimeInterval: 0.5)
        }

        element.typeText(text)
    }

    /// Scrolls the form until the element can be tapped, since the add screen is taller than the phone.
    private func scrollTo(_ element: XCUIElement, _ description: String, up: Bool = false) throws {
        for _ in 0..<8 {
            if element.exists && element.isHittable {
                return
            }

            dismissKeyboard()
            let scrollable = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch

            if up {
                scrollable.swipeDown()
            } else {
                scrollable.swipeUp()
            }

            Thread.sleep(forTimeInterval: 0.5)
        }

        try waitFor(element, description, timeout: 5)
    }

    private func dismissKeyboard() {
        let hidePad = app.buttons["pad_hide"]

        if hidePad.exists && hidePad.isHittable {
            hidePad.tap()
            return
        }

        guard app.keyboards.firstMatch.exists else {
            return
        }

        for name in ["Return", "return", "Done", "done"] {
            let key = app.keyboards.buttons[name]

            if key.exists && key.isHittable {
                key.tap()
                return
            }
        }

        // the decimal pad has no return key; the editor adds a Done button above the keyboard.
        // Never swipe down here: the editor is a sheet and a swipe closes it.
        let done = app.buttons["keyboard_done"]

        if done.exists && done.isHittable {
            done.tap()
        }
    }

    /// Closes prompts that can cover the app on a fresh simulator, such as offering to save the password.
    private func dismissSystemPrompts() {
        for title in ["Not Now", "Not now"] {
            let button = app.buttons[title]

            if button.exists && button.isHittable {
                button.tap()
            }
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch

        if alert.exists {
            for title in ["Allow", "OK", "Not Now"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                break
            }
        }
    }

    private func settle() {
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        if let dir = screenshotDir {
            try? screenshot.pngRepresentation.write(to: dir.appendingPathComponent(name + ".png"))
        }
    }
}
