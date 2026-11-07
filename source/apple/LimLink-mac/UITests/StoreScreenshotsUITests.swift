import StoreKitTest
import XCTest

@MainActor
final class StoreScreenshotsUITests: XCTestCase {
    func testEnglish() { capture("en", "en_US") }
    func testSimplifiedChinese() { capture("zh-Hans", "zh_CN") }
    func testTraditionalChinese() { capture("zh-Hant", "zh_TW") }
    func testJapanese() { capture("ja", "ja_JP") }
    func testKorean() { capture("ko", "ko_KR") }
    func testFrench() { capture("fr", "fr_FR") }
    func testGerman() { capture("de", "de_DE") }
    func testSpanish() { capture("es", "es_ES") }
    func testItalian() { capture("it", "it_IT") }

    private func capture(_ language: String, _ locale: String) {
        continueAfterFailure = false
        let storeSession: SKTestSession
        do {
            let configuration = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "SupportTips", withExtension: "storekit"))
            storeSession = try SKTestSession(contentsOf: configuration)
            storeSession.resetToDefaultState()
            storeSession.disableDialogs = true
            storeSession.clearTransactions()
        } catch {
            XCTFail("Cannot initialize the real StoreKit test catalogue: \(error)")
            return
        }
        defer {
            // Keep the StoreKit session alive through every screen capture.
            storeSession.clearTransactions()
        }
        let app = XCUIApplication()
        // A previous hosted test may leave this one OS prompt on the disposable Cloud worker.
        // Decline only the observed LimLink Local Network request; this fixture never uses LAN.
        let localNetworkMonitor = addUIInterruptionMonitor(withDescription: "LimLink fixture Local Network permission") { interruption in
            let texts = [interruption.label] + interruption.staticTexts.allElementsBoundByIndex.flatMap {
                [$0.label, $0.value as? String ?? ""]
            }
            let title = "Allow \"LimLink\" to find devices on local networks?"
            let matchesRequest = texts.contains { text in
                let normalized = text.replacingOccurrences(of: "“", with: "\"")
                    .replacingOccurrences(of: "”", with: "\"")
                    .split(whereSeparator: \.isWhitespace).joined(separator: " ")
                return normalized.contains(title)
            }
            let decline = interruption.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Don’t Allow", "Don't Allow")).firstMatch
            guard matchesRequest, interruption.buttons["Allow"].exists,
                  decline.exists, decline.isEnabled, decline.isHittable else { return false }
            XCTContext.runActivity(named: "Decline identified Local Network interruption in screenshot fixture") { activity in
                let evidence = XCTAttachment(string: interruption.debugDescription)
                evidence.name = "Identified LimLink Local Network prompt"
                evidence.lifetime = .keepAlways
                activity.add(evidence)
            }
            decline.click()
            return true
        }
        defer {
            removeUIInterruptionMonitor(localNetworkMonitor)
            app.terminate()
        }
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-limlink.language", "system"]
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "devices"
        app.launchEnvironment["LIMLINK_STORE_SCREENSHOTS"] = "1"
        // The UI app starts after its SKTestSession, unlike the isolated app-hosted unit-test host.
        app.launchEnvironment["LIMLINK_ISOLATED_STOREKIT_HOST"] = "0"
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["send.chooseFile"].waitForExistence(timeout: 15))
        let selectedFileButtons = app.buttons.matching(identifier: "file.preview")
            .matching(NSPredicate(format: "label CONTAINS %@", "LimLink.pdf"))
        let selectedFile = selectedFileButtons.firstMatch
        XCTAssertTrue(selectedFile.waitForExistence(timeout: 10))
        XCTAssertEqual(selectedFileButtons.count, 1, "Only the filename preview button should match")
        // Interruption monitors run on interaction, not existence queries. Click an inert corner
        // outside the fixture controls so a lingering permission prompt is handled before readiness.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.94)).click()
        let fileReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            selectedFile.exists && selectedFile.isEnabled && selectedFile.isHittable
        }, object: nil)
        guard XCTWaiter.wait(for: [fileReady], timeout: 10) == .completed else {
            attachNavigationFailure(app, window: window, stage: "Selected filename preview button is blocked")
            XCTFail("The selected filename preview button must be enabled and hittable")
            return
        }
        XCTAssertTrue(selectedFile.isEnabled)
        XCTAssertTrue(selectedFile.isHittable)
        let sized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(window.frame.width - 1280) < 2 && abs(window.frame.height - 800) < 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sized], timeout: 20), .completed, "Actual window: \(window.frame)")
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Store-\(language)-Mac-01-devices"
        attachment.lifetime = .keepAlways
        add(attachment)
        let settings = app.buttons["network.status"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        // The 28-point capsule sits inside 52-point full-screen AX bounds. Build 17's
        // 0.8 offset clicked below it; 0.65 stays inside and below the system menu bar.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).hover()
        guard clickStable(settings, lowerInterior: true) else { return }
        let nameField = app.textFields["deviceName.field"]
        guard nameField.waitForExistence(timeout: 10) else {
            attachNavigationFailure(app, window: window, stage: "Device identity did not open")
            XCTFail("Toolbar click did not present device identity")
            return
        }
        let support = app.buttons["support.open"]
        XCTAssertTrue(support.waitForExistence(timeout: 10))
        guard clickStable(support) else { return }
        for id in ["com.limlink.tip.small", "com.limlink.tip.medium", "com.limlink.tip.large"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 20), "Cloud scheme must select SupportTips.storekit: \(id)")
        }
        let supportAttachment = XCTAttachment(screenshot: window.screenshot())
        supportAttachment.name = "Support-\(language)-Mac"
        supportAttachment.lifetime = .keepAlways
        add(supportAttachment)
    }

    /// Native mouse interaction after SwiftUI/full-screen geometry has settled.
    private func clickStable(_ element: XCUIElement, lowerInterior: Bool = false) -> Bool {
        var previous = CGRect.null
        var stableSince = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists, element.isHittable, element.isEnabled else {
                stableSince = Date()
                return false
            }
            let frame = element.frame
            guard !frame.isEmpty, !frame.isNull else { return false }
            if frame != previous {
                previous = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.8
        }, object: nil)
        guard XCTWaiter.wait(for: [settled], timeout: 10) == .completed else {
            XCTFail("Mouse target did not settle: \(element.debugDescription)")
            return false
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: lowerInterior ? 0.65 : 0.5)).click()
        return true
    }

    private func attachNavigationFailure(_ app: XCUIApplication, window: XCUIElement, stage: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = stage + " hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: window.screenshot())
        screenshot.name = stage
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
