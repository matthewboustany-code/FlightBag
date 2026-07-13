//
//  MapUITests.swift
//  FlightBagUITests
//

import XCTest

final class MapUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSectionalRadarAndOwnship() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hasAcknowledgedDisclaimer", "YES"]
        app.launch()

        // Switch to the Map tab.
        let mapTab = app.buttons["Map"].firstMatch
        XCTAssertTrue(mapTab.waitForExistence(timeout: 10), "Map tab should exist")
        mapTab.tap()

        // Sectional overlay should be active (status strip names the chart).
        let chartBadge = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "San Antonio Sectional")
        ).firstMatch
        XCTAssertTrue(chartBadge.waitForExistence(timeout: 10), "Sectional chart should be loaded")

        // Grant location permission if the system alert appears, then follow ownship.
        addUIInterruptionMonitor(withDescription: "Location permission") { alert in
            let allow = alert.buttons["Allow While Using App"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        let follow = app.buttons["map.follow"].firstMatch
        XCTAssertTrue(follow.waitForExistence(timeout: 5))
        follow.tap()
        app.tap()  // deliver any pending interruption
        sleep(6)   // tiles render + camera settles
        attachScreenshot(app, name: "1-sectional-ownship")

        // Enable radar through the layers panel.
        app.buttons["map.layers"].firstMatch.tap()
        let radarToggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Radar (NEXRAD)"))
            .firstMatch
        XCTAssertTrue(radarToggle.waitForExistence(timeout: 5), "Radar toggle should exist")
        radarToggle.tap()
        app.buttons["map.layers"].firstMatch.tap()  // dismiss popover
        sleep(5)
        attachScreenshot(app, name: "2-radar-overlay")
    }

    @MainActor
    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
