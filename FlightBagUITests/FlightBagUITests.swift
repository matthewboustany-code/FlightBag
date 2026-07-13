//
//  FlightBagUITests.swift
//  FlightBagUITests
//

import XCTest

final class FlightBagUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSearchKAUSViewWeatherAndPlate() throws {
        let app = XCUIApplication()
        // Pre-acknowledge the disclaimer via the argument defaults domain.
        app.launchArguments += ["-hasAcknowledgedDisclaimer", "YES"]
        app.launch()

        // Search for KAUS in the Airports tab. On iPad the search starts as
        // a toolbar button that reveals the field.
        var searchField = app.searchFields.firstMatch
        if !searchField.waitForExistence(timeout: 5) {
            let searchButton = app.buttons["Search"].firstMatch
            XCTAssertTrue(searchButton.waitForExistence(timeout: 10), "Search button should exist")
            searchButton.tap()
            searchField = app.searchFields.firstMatch
            XCTAssertTrue(searchField.waitForExistence(timeout: 10), "Search field should appear after tapping Search")
        }
        searchField.tap()
        searchField.typeText("KAUS")

        let resultCell = app.cells.containing(.staticText, identifier: "KAUS").firstMatch
        XCTAssertTrue(resultCell.waitForExistence(timeout: 10), "KAUS should appear in search results")
        attachScreenshot(app, name: "1-search-results")
        resultCell.tap()

        // Airport detail: static airport data must be present immediately.
        XCTAssertTrue(app.staticTexts["AUSTIN-BERGSTROM INTL"].waitForExistence(timeout: 10), "Airport name should display")
        XCTAssertTrue(app.staticTexts["18R/36L"].waitForExistence(timeout: 5), "Runways should display")

        // Live weather: raw METAR text contains the station id + Z-time group.
        let metarText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "KAUS ")).firstMatch
        XCTAssertTrue(metarText.waitForExistence(timeout: 20), "Live METAR should load")
        attachScreenshot(app, name: "2-airport-detail")

        // Open the approaches list and view a chart. The section is below the
        // fold in the lazy list, so scroll until it materializes.
        let approaches = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Approaches")).firstMatch
        for _ in 0..<6 where !approaches.exists {
            app.swipeUp()
        }
        XCTAssertTrue(approaches.waitForExistence(timeout: 5), "Approaches group should exist")
        approaches.tap()

        let ilsChart = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "ILS OR LOC RWY 18L")).firstMatch
        for _ in 0..<4 where !ilsChart.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(ilsChart.waitForExistence(timeout: 5), "ILS 18L chart should be listed")
        ilsChart.tap()

        // The viewer must actually open (nav title) and the PDF fetches from
        // FAA servers; allow generous time, then settle before the screenshot.
        let viewerTitle = app.navigationBars.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "ILS OR LOC RWY 18L")
        ).firstMatch
        XCTAssertTrue(viewerTitle.waitForExistence(timeout: 15), "Plate viewer should open")
        sleep(8)
        attachScreenshot(app, name: "3-plate-viewer")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
