//
//  BillifyUITests.swift
//  BillifyUITests
//
//  Created by Anush Rithvic on 28/08/26.
//

import XCTest

final class BillifyUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    /// End-to-end: home → Tax Invoice → paste a natural-language sentence →
    /// the clause reader maps it into the draft → the confirm-before-generate
    /// review card shows the mapped fields → confirm → PDF is produced.
    @MainActor
    func testBulkPasteToReviewCardToPDF() throws {
        let app = XCUIApplication()
        app.launch()

        // Home → Tax Invoice card (SwiftUI NavigationLink exposes the card's
        // texts inside a combined button label, so tap the title text itself)
        let taxTitle = app.staticTexts["Tax Invoice"].firstMatch
        XCTAssertTrue(taxTitle.waitForExistence(timeout: 30), "Tax Invoice card should appear on home")
        taxTitle.tap()
        XCTAssertTrue(app.navigationBars["Tax Invoice"].waitForExistence(timeout: 15),
                      "Chat should open for the chosen document type")

        // Paste the whole sentence into the chat composer
        let composer = app.textFields["composerField"]
        waitFor(composer, "Chat composer should appear")
        composer.tap()
        Thread.sleep(forTimeInterval: 1.5)
        composer.typeText("Create an invoice for Radhika Mills, SF NO 114/2 PAPPAMPALAYAM TIRUPUR - 641604, gstin 33AIMPM2628J1Z4 with 100 bales cotton yarn hsn 5205 4000 kgs rate 150 per kg with invoice number 2 date today")
        Thread.sleep(forTimeInterval: 1.0)
        app.buttons["sendButton"].tap()

        // The chat summary should show the mapped fields
        waitFor(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Buyer: Radhika Mills")).firstMatch,
            "Summary should name the buyer")
        waitFor(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "100 BALES")).firstMatch)
        waitFor(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "₹150/KG")).firstMatch)

        // Complete draft → preview card with Generate PDF
        let generate = app.buttons["Generate PDF"].firstMatch
        waitFor(generate, "Generate PDF should appear once the draft is complete")
        generate.tap()

        // Confirm-before-generate review card
        waitFor(app.navigationBars["Review before generating"].firstMatch,
                "Review card should appear before the PDF")
        // Mapped fields are editable + totals computed from the extracted numbers
        waitFor(app.staticTexts["₹630000"].firstMatch,
                "Grand total should be computed from extracted weight × rate + GST")

        // Confirm → PDF
        let confirm = app.buttons["Confirm & Generate PDF"].firstMatch
        waitFor(confirm)
        confirm.tap()
        waitFor(app.navigationBars["invoice_2.pdf"].firstMatch,
                "PDF preview should open with the invoice-numbered filename", timeout: 30)
    }

    /// Retry-based existence check: the simulator's accessibility snapshot
    /// occasionally times out while the app is mid-animation, so a single
    /// `waitForExistence` is flaky on this machine.
    @MainActor
    private func waitFor(_ element: XCUIElement,
                         _ message: String = "",
                         timeout: TimeInterval = 25,
                         file: StaticString = #filePath,
                         line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail(message.isEmpty ? "Timed out waiting for \(element)" : message, file: file, line: line)
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = XCUIApplication()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // XCUIAutomation Documentation
        // https://developer.apple.com/documentation/xcuiautomation
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
