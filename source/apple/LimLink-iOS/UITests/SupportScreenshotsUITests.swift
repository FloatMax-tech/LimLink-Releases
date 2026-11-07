import StoreKitTest
import XCTest
import UIKit

/// Uses the real support view and StoreKit products. The Cloud UI-test scheme selects SupportTips.storekit.
@MainActor
final class SupportScreenshotsUITests: XCTestCase {
    func testSupportEnglish() { capture("en", "en_US") }
    func testSupportSimplifiedChinese() { capture("zh-Hans", "zh_CN") }
    func testSupportTraditionalChinese() { capture("zh-Hant", "zh_TW") }
    func testSupportJapanese() { capture("ja", "ja_JP") }
    func testSupportKorean() { capture("ko", "ko_KR") }
    func testSupportFrench() { capture("fr", "fr_FR") }
    func testSupportGerman() { capture("de", "de_DE") }
    func testSupportSpanish() { capture("es", "es_ES") }
    func testSupportItalian() { capture("it", "it_IT") }

    private func capture(_ language: String, _ locale: String) {
        continueAfterFailure = false
        let storeSession: SKTestSession
        do {
            storeSession = try SKTestSession(configurationFileNamed: "SupportTips")
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
        defer { app.terminate() }
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale, "-limlink.language", "system"]
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "devices"
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launchEnvironment["LIMLINK_STORE_SCREENSHOTS"] = "1"
        app.launch()
        let identity = app.buttons["transfer.identity"]
        XCTAssertTrue(identity.waitForExistence(timeout: 20))
        tapStable(identity, through: app)
        let open = app.buttons["support.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let identityScroll = app.scrollViews.containing(.button, identifier: "support.open").firstMatch
        guard identityScroll.waitForExistence(timeout: 10) else {
            attachCatalogueFailure(app, language: language, stage: "Identity scroll view missing")
            XCTFail("The identity scroll view containing the support entry is missing")
            return
        }
        for _ in 0..<8 {
            if isFullyVisible(open, inside: identityScroll, in: app) { break }
            identityScroll.swipeUp()
        }
        guard isFullyVisible(open, inside: identityScroll, in: app) else {
            attachCatalogueFailure(app, language: language, stage: "Support entry not fully visible")
            XCTFail("The full support entry must be inside the identity scroll viewport before tapping")
            return
        }
        tapStable(open, through: app, inside: identityScroll)
        guard app.buttons["support.close"].waitForExistence(timeout: 10) else {
            attachCatalogueFailure(app, language: language, stage: "Support page did not open")
            XCTFail("The support page did not open after tapping its visible entry")
            return
        }
        let productIDs = ["com.limlink.tip.small", "com.limlink.tip.medium", "com.limlink.tip.large"]
        let retry = app.buttons["support.retry"]
        let allProductsReady = { productIDs.allSatisfy { app.buttons[$0].exists } }
        // Cloud's first cold StoreKit session may return an unavailable catalogue. Exercise the
        // same visible retry a person uses; never replace real products or retry automatically in a loop.
        let loadedOrRetry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            allProductsReady() || (retry.exists && retry.isHittable && retry.isEnabled)
        }, object: nil)
        guard XCTWaiter.wait(for: [loadedOrRetry], timeout: 20) == .completed else {
            attachCatalogueFailure(app, language: language, stage: "No products or available retry")
            XCTFail("StoreKit catalogue did not become ready or expose the retry button")
            return
        }
        if !allProductsReady() {
            tapStable(retry, through: app)
        }
        let catalogueReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            allProductsReady()
        }, object: nil)
        guard XCTWaiter.wait(for: [catalogueReady], timeout: 20) == .completed else {
            attachCatalogueFailure(app, language: language, stage: "Products missing after one visible retry")
            XCTFail("StoreKit products missing after at most one visible retry: \(productIDs.filter { !app.buttons[$0].exists })")
            return
        }
        for id in productIDs {
            XCTAssertTrue(app.buttons[id].exists, "StoreKit product missing: \(id)")
        }
        XCTAssertFalse(app.otherElements["support.status"].exists, "Screenshot must not imply a completed payment")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Support-\(language)-\(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func attachCatalogueFailure(_ app: XCUIApplication, language: String, stage: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Support-\(language)-\(stage)-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Support-\(language)-\(stage)"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func isFullyVisible(_ element: XCUIElement, inside scrollView: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists, element.isHittable, scrollView.exists else { return false }
        let frame = element.frame
        let viewport = scrollView.frame.intersection(app.frame).insetBy(dx: 4, dy: 12)
        return !frame.isEmpty && !frame.isNull && !viewport.isEmpty && !viewport.isNull && viewport.contains(frame)
    }

    private func tapStable(_ element: XCUIElement, through app: XCUIApplication, inside scrollView: XCUIElement? = nil) {
        var previous = CGRect.null
        var stableSince = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists, element.isHittable else { stableSince = Date(); return false }
            if let scrollView, !self.isFullyVisible(element, inside: scrollView, in: app) {
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
            XCTFail("Hit target did not settle: \(element.debugDescription)")
            return
        }
        let frame = element.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX - app.frame.minX, dy: frame.midY - app.frame.minY)).tap()
    }

}
