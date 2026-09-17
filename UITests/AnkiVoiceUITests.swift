import XCTest

/// UI smoke tests driving the real app through onboarding into the deck list
/// and deck detail. These verify the actual rendered interface via the
/// accessibility tree (the simulator framebuffer is not capturable headless).
final class AnkiVoiceUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    func testOnboardingFlowReachesDeckList() throws {
        let app = XCUIApplication()
        // Force the onboarding flow even if a previous test completed it.
        app.launchArguments += ["-uiTestForceOnboarding"]
        app.launch()

        // Page 1: value proposition.
        let firstTitle = app.staticTexts["Study without touching your phone"]
        XCTAssertTrue(firstTitle.waitForExistence(timeout: 10))

        // Advance through the informational pages (4 advances reach the
        // final tutorial page).
        let continueButton = app.buttons["Continue"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Four ratings"].waitForExistence(timeout: 5))

        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Microphone access"].waitForExistence(timeout: 5))

        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Voice check"].waitForExistence(timeout: 5))

        continueButton.tap()
        XCTAssertTrue(app.staticTexts["Try a three-card tutorial"].waitForExistence(timeout: 5))

        // Skip the tutorial; land on the deck list.
        let skip = app.buttons["Skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10))
        skip.tap()

        let decksTitle = app.navigationBars["Decks"]
        XCTAssertTrue(decksTitle.waitForExistence(timeout: 10))
    }

    func testDeckDetailShowsStudyActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uiTestSkipOnboarding", "YES"]
        app.launch()

        let decksTitle = app.navigationBars["Decks"]
        XCTAssertTrue(decksTitle.waitForExistence(timeout: 10))

        // Sample decks are seeded on first deck-list load.
        let starterRow = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Starter'")).firstMatch
        XCTAssertTrue(starterRow.waitForExistence(timeout: 10))
        starterRow.tap()

        let handsFree = app.buttons["Start Hands-Free Study"]
        XCTAssertTrue(handsFree.waitForExistence(timeout: 15))

        // The management links live below the fold on small screens.
        let browse = app.buttons["Browse & search cards"]
        for _ in 0..<6 where !browse.exists {
            app.swipeUp()
        }
        XCTAssertTrue(browse.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Deck settings"].waitForExistence(timeout: 10))

        // Editors expose their actions in-content so assistive tech can
        // always reach Save/Cancel (audit fix).
        browse.tap()
        let firstCard = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'new' OR label CONTAINS 'learning' OR label CONTAINS 'review'")
        ).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 10))
        firstCard.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Save"].exists)
        app.buttons["Save"].tap()
    }
}
