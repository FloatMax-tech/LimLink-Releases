import UIKit
import XCTest

@MainActor
final class TransferFlowUITests: XCTestCase {
    // Cloud screenshot jobs exercise the real localized views with demo file/device data.
    // Do not capture simulated transfer speeds as marketing evidence.
    func testStoreScreenshotsEnglish() { captureStoreScreenshots(language: "en", locale: "en_US") }
    func testStoreScreenshotsSimplifiedChinese() { captureStoreScreenshots(language: "zh-Hans", locale: "zh_CN") }
    func testStoreScreenshotsTraditionalChinese() { captureStoreScreenshots(language: "zh-Hant", locale: "zh_TW") }
    func testStoreScreenshotsJapanese() { captureStoreScreenshots(language: "ja", locale: "ja_JP") }
    func testStoreScreenshotsKorean() { captureStoreScreenshots(language: "ko", locale: "ko_KR") }
    func testStoreScreenshotsFrench() { captureStoreScreenshots(language: "fr", locale: "fr_FR") }
    func testStoreScreenshotsGerman() { captureStoreScreenshots(language: "de", locale: "de_DE") }
    func testStoreScreenshotsSpanish() { captureStoreScreenshots(language: "es", locale: "es_ES") }
    func testStoreScreenshotsItalian() { captureStoreScreenshots(language: "it", locale: "it_IT") }

    private func captureStoreScreenshots(language: String, locale: String) {
        let app = XCUIApplication()
        defer {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", locale]
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "devices"
        app.launchEnvironment["LIMLINK_STORE_SCREENSHOTS"] = "1"
        app.launch()
        let card = app.buttons["transfer.file.choose"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        XCTAssertTrue(element("transfer.file.selected", in: app).waitForExistence(timeout: 10))
        let size = app.windows.firstMatch.frame.size
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let prefix = "Store-\(language)-\(device)-\(Int(size.width))x\(Int(size.height))"
        // Wait for the real entrance animation before preserving each attachment.
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in card.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        attachScreenshot("\(prefix)-01-file")
        let send = app.buttons["transfer.send"]
        if send.exists {
            tapStable(send, through: app)
        }
        XCTAssertTrue(recipientButtons(in: app).firstMatch.waitForExistence(timeout: 10))
        let recipientTitle = app.staticTexts["transfer.recipientTitle"]
        let multiSelect = app.buttons["transfer.multiSelect"]
        if recipientTitle.exists && multiSelect.exists {
            XCTAssertFalse(recipientTitle.frame.intersects(multiSelect.frame),
                           "Localized recipient title must not overlap multi-select (\(language))")
        }
        attachScreenshot("\(prefix)-02-devices")

        // Physical device orientation is not directly tied to the app's UI orientation:
        // https://developer.apple.com/documentation/xcuiautomation/xcuidevice/orientation
        // Duo's current inner-display pose may keep a portrait-shaped scene after rotation.
        // Capture the real scene; this does not certify unexercised unfolded/wide poses.
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft)
        var previousFrame = CGRect.null
        var stableSince = Date()
        let responsiveScene = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            guard app.state == .runningForeground, frame.width > 0, frame.height > 0,
                  self.recipientButtons(in: app).firstMatch.exists,
                  self.recipientButtons(in: app).firstMatch.isEnabled,
                  self.recipientButtons(in: app).firstMatch.isHittable else { return false }
            if frame != previousFrame {
                previousFrame = frame
                stableSince = Date()
                return false
            }
            return Date().timeIntervalSince(stableSince) >= 0.8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [responsiveScene], timeout: 10), .completed,
                       "The actual app scene must settle with available recipients after device rotation")
        let frame = app.windows.firstMatch.frame
        // Match TransferHomeView's production window breakpoint exactly.
        let wide = frame.width >= 700 && frame.width > frame.height
        if wide {
            XCTAssertTrue(card.waitForExistence(timeout: 10))
            XCTAssertTrue(recipientButtons(in: app).firstMatch.exists)
            XCTAssertFalse(app.buttons["transfer.send"].exists)
        } else {
            XCTAssertTrue(fileNameIsPresented(in: app, name: "LimLink.pdf"))
            XCTAssertTrue(recipientTitle.waitForExistence(timeout: 5))
            XCTAssertTrue(multiSelect.exists)
            XCTAssertFalse(recipientTitle.frame.intersects(multiSelect.frame),
                           "Localized recipient title must not overlap multi-select (\(language))")
        }
        let layout = wide ? "shared-wide-layout" : "compact-recipients"
        attachScreenshot("\(prefix)-03-current-scene-\(Int(frame.width))x\(Int(frame.height))-\(layout)")
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testLanguageSwitchKeepsSelectedFileAndPersists() {
        let app = launch(scenario: "file")
        openIdentity(in: app)
        let picker = app.buttons["settings.language"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        app.buttons["transfer.identity.close"].tap()
        XCTAssertTrue(element("transfer.file.selected", in: app).exists)
        XCTAssertTrue(fileNameIsPresented(in: app))
        attachScreenshot("Language — English preserves selected file")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "LIMLINK_UI_TEST_RESET_LANGUAGE")
        app.launch()
        openIdentity(in: app)
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.language"].label.contains("English"))
    }

    func testCustomDeviceNamePersistsAndKeepsSelectedFile() {
        let app = launch(scenario: "file")
        openIdentity(in: app)
        let field = app.textFields["transfer.deviceName.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let name = "Travel iPhone \(Int.random(in: 1000...9999))"
        replaceText(in: field, with: name)
        app.buttons["transfer.deviceName.save"].tap()
        XCTAssertTrue(element("transfer.deviceName.saved", in: app).waitForExistence(timeout: 10))
        attachScreenshot("Identity — custom device name saved")
        app.buttons["transfer.identity.close"].tap()
        XCTAssertTrue(element("transfer.file.selected", in: app).exists)
        XCTAssertTrue(fileNameIsPresented(in: app))

        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["transfer.identity"].waitForExistence(timeout: 10))
        openIdentity(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, name)
    }

    func testClosingDeviceNameEditorDiscardsUnsavedChanges() {
        let app = launch(scenario: "empty")
        openIdentity(in: app)
        let field = app.textFields["transfer.deviceName.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        let original = field.value as? String
        replaceText(in: field, with: "")
        let emptyNameError = app.staticTexts["transfer.deviceName.error"]
        XCTAssertTrue(emptyNameError.waitForExistence(timeout: 5), "Cleared field: \(field.debugDescription)")
        XCTAssertEqual(emptyNameError.label, "设备名称不能为空。")
        XCTAssertFalse(app.buttons["transfer.deviceName.save"].isEnabled, "Cleared field: \(field.debugDescription)")
        attachScreenshot("Identity — after clearing the device name")
        field.typeText("Unsaved name")
        app.buttons["transfer.identity.close"].tap()
        openIdentity(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, original)
    }

    private func replaceText(in field: XCUIElement, with text: String) {
        tapStable(field, through: XCUIApplication())
        let previous = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + text)
    }

    func testFileCanBeChosenBeforeAnyRecipientExists() {
        let app = launch(scenario: "empty")

        let chooseFile = app.buttons["transfer.file.choose"]
        XCTAssertTrue(chooseFile.waitForExistence(timeout: 5))
        XCTAssertTrue(chooseFile.isEnabled, "Choosing a file must not require a nearby device.")
        XCTAssertTrue(chooseFile.isHittable)
        XCTAssertTrue(element("transfer.file.limit", in: app).label.contains("5 GB"))
        XCTAssertFalse(app.buttons["transfer.send"].isEnabled)
        XCTAssertFalse(element("transfer.file.selected", in: app).exists)
        assertNoRecipientsOnHome(in: app)
        attachScreenshot("Home — choose a file first")
    }

    func testFileCardOffersFilesAndPhotosWithoutSeparateChooseButton() {
        let app = launch(scenario: "empty")
        let card = app.buttons["transfer.file.choose"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(card.frame.height, 150)
        XCTAssertEqual(app.buttons.matching(identifier: "transfer.file.choose").count, 1)
        XCTAssertFalse(app.buttons["选择文件"].exists)
        card.tap()
        XCTAssertTrue(app.buttons["文件"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["照片"].exists)
        attachScreenshot("Card — file and photo choices")
        // iOS 27 presents this as a popover without a separate cancel row.
        XCTAssertFalse(app.buttons["transfer.send"].isEnabled)
    }

    func testPhotoPickerImportsAnImageFromTheCard() {
        // The dedicated verification simulator is seeded with a small PNG before this test.
        let app = launch(scenario: "empty")
        app.buttons["transfer.file.choose"].tap()
        XCTAssertTrue(app.buttons["照片"].waitForExistence(timeout: 5))
        app.buttons.matching(identifier: "transfer.source.photos").firstMatch.tap()
        let image = app.images.matching(NSPredicate(format: "label BEGINSWITH %@", "照片")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 20), app.debugDescription)
        image.tap()
        let add = app.buttons["添加"]
        if add.waitForExistence(timeout: 2) { add.tap() }
        XCTAssertTrue(element("transfer.file.selected", in: app).waitForExistence(timeout: 20), app.debugDescription)
        XCTAssertTrue(app.buttons["transfer.send"].isEnabled)
        attachScreenshot("Photo — imported as a sendable file")
    }

    func testSelectedFileOpensEmptyRecipientPageAndSurvivesReturningHome() {
        let app = launch(scenario: "file")
        let selectedFile = element("transfer.file.selected", in: app)
        XCTAssertTrue(selectedFile.waitForExistence(timeout: 5))
        XCTAssertTrue(fileNameIsPresented(in: app))
        assertNoRecipientsOnHome(in: app)

        let send = app.buttons["transfer.send"]
        XCTAssertTrue(send.isEnabled, "Searching for a recipient must not require one to be selected already.")
        send.tap()

        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("transfer.recipientPicker", in: app).exists)
        XCTAssertTrue(element("transfer.discovery.empty", in: app).exists)
        attachScreenshot("Recipients — waiting for nearby devices")

        tapBack(in: app, title: "选择设备")

        XCTAssertTrue(app.navigationBars["LimLink"].waitForExistence(timeout: 5))
        XCTAssertTrue(selectedFile.exists, "Back navigation must preserve the selected file.")
        XCTAssertTrue(fileNameIsPresented(in: app))
        XCTAssertTrue(app.buttons["transfer.send"].isEnabled)
        assertNoRecipientsOnHome(in: app)
        attachScreenshot("Home — selected file preserved")
    }

    func testNearbyDevicesAreShownOnlyAfterEnteringRecipientPage() {
        let app = launch(scenario: "devices")
        XCTAssertTrue(element("transfer.file.selected", in: app).waitForExistence(timeout: 5))
        assertNoRecipientsOnHome(in: app)
        XCTAssertFalse(app.staticTexts["书房 iPad"].exists)
        XCTAssertFalse(app.staticTexts["随身 iPhone"].exists)
        attachScreenshot("Home — recipients deferred")

        app.buttons["transfer.send"].tap()

        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(element("transfer.recipientPicker", in: app).exists)
        XCTAssertFalse(element("transfer.discovery.empty", in: app).exists)
        let recipients = recipientButtons(in: app)
        XCTAssertEqual(recipients.count, 2)
        XCTAssertTrue(recipients.matching(NSPredicate(format: "label CONTAINS %@", "书房 iPad")).firstMatch.exists)
        XCTAssertTrue(recipients.matching(NSPredicate(format: "label CONTAINS %@", "随身 iPhone")).firstMatch.exists)
        XCTAssertTrue(recipients.element(boundBy: 0).isHittable)
        XCTAssertTrue(recipients.element(boundBy: 1).isHittable)
        attachScreenshot("Recipients — available iPad and iPhone")
    }

    func testIncomingFileShowsNameAndReceiveConsentWithoutFingerprint() {
        let app = launch(scenario: "incoming")
        XCTAssertTrue(element("transfer.offer", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["来自：书房 iPad"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "旅行视频.mov")).firstMatch.exists)
        let accept = app.buttons["transfer.offer.accept"]
        XCTAssertTrue(accept.exists, app.debugDescription)
        XCTAssertTrue(accept.isEnabled)
        XCTAssertTrue(accept.isHittable)
        XCTAssertTrue(accept.label.contains("确认接收"))
        XCTAssertTrue(app.buttons["transfer.offer.reject"].exists)
        XCTAssertFalse(element("transfer.verification", in: app).exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "指纹")).firstMatch.exists)
        attachScreenshot("Receive — sender name and explicit consent")
    }

    func testReceivePanelShowsSaveLocationCountdownAndQueue() {
        let app = launch(scenario: "incoming")
        XCTAssertTrue(element("transfer.offer", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "保存到")).firstMatch.exists)
        let countdown = element("transfer.offer.countdown", in: app)
        XCTAssertTrue(countdown.exists)
        XCTAssertTrue(countdown.label.hasSuffix("秒后自动拒绝"), countdown.label)
        XCTAssertTrue(element("transfer.offer.queue", in: app).exists)
        attachScreenshot("Receive — bottom panel with countdown and queue")

        app.buttons["transfer.offer.reject"].tap()
        XCTAssertTrue(app.staticTexts["来自：随身 iPhone"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("transfer.offer.queue", in: app).exists)
        app.buttons["transfer.offer.accept"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("transfer.offer", in: app))
        waitForExpectations(timeout: 5)
    }

    func testFirstReceiveAcceptsWithoutAskingForAFolder() {
        let app = launch(scenario: "first-receive")
        XCTAssertTrue(element("transfer.offer", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "› LimLink")).firstMatch.exists,
                      "The default location is the app folder in the Files app.")
        app.buttons["transfer.offer.accept"].tap()
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: element("transfer.offer", in: app))
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["DOCPicker.actionButton"].exists, "No folder picker on first receive.")
    }

    func testReceivedFileSwipesLeftToDelete() {
        let app = launch(scenario: "received")
        let first = app.otherElements["transfer.received.row.会议纪要.pdf"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["IMG_2041.HEIC"].exists)

        let fileName = first.buttons["file.preview.received.会议纪要.pdf"]
        XCTAssertTrue(fileName.exists, app.debugDescription)

        // Drag over the actual filename button: it must swipe without also opening preview.
        fileName.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: fileName.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)),
                   withVelocity: .slow, thenHoldForDuration: 0.5)
        XCTAssertFalse(app.navigationBars["会议纪要.pdf"].exists, "A swipe must not also open the file preview")
        XCTAssertFalse(app.buttons["关闭"].exists, "No preview sheet may obstruct deletion")
        attachScreenshot("Received — swipe left to delete")
        // A long swipe deletes at once; a shorter one reveals the button.
        if first.exists {
            let delete = first.buttons["transfer.received.delete"]
            XCTAssertTrue(delete.waitForExistence(timeout: 3), app.debugDescription)
            tapStable(delete, through: app)
        }

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: first)
        waitForExpectations(timeout: 5)
        XCTAssertTrue(app.staticTexts["IMG_2041.HEIC"].exists, "Only the swiped file is deleted.")
        attachScreenshot("Received — after deleting")
    }

    func testSelectedFileAndReceivedNameOpenOfflineTextPreview() {
        let app = launch(scenario: "preview")
        let selectedCard = app.buttons["transfer.file.choose"]
        tapStable(selectedCard, through: app)
        XCTAssertTrue(app.staticTexts["LimLink offline preview fixture."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["打开所在文件夹"].exists)
        attachScreenshot("Preview — selected local text")
        app.buttons["关闭"].tap()

        let received = app.buttons["file.preview.received.Readme.txt"]
        XCTAssertTrue(received.waitForExistence(timeout: 5), app.debugDescription)
        tapStable(received, through: app)
        XCTAssertTrue(app.staticTexts["LimLink offline preview fixture."].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.buttons["用其他应用打开"].exists)
        attachScreenshot("Preview — received filename opens local text")
    }

    func testVerifiedReceiptHasVisibleCheckmarkCompletion() {
        let orientation = XCUIDevice.shared.orientation
        let app = XCUIApplication()
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "preview"
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launchEnvironment["LIMLINK_UI_TEST_COMPLETION_TRIGGER"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        XCUIDevice.shared.orientation = orientation

        let trigger = app.buttons["ui.fixture.receipt.complete"]
        guard trigger.waitForExistence(timeout: 10) else {
            XCTFail("Completion fixture did not become ready: \(app.debugDescription)")
            return
        }
        let completion = element("transfer.completion.received", in: app)
        XCTAssertFalse(completion.exists, "Completion must be triggered after launch, not expire during startup")
        // Only presentation is simulated; the production banner owns animation and dismissal.
        // Verified publication and ACK behavior have separate transport tests.
        tapStable(trigger, through: app)
        guard completion.waitForExistence(timeout: 2) else {
            XCTFail("Triggered receipt completion is missing: \(app.debugDescription)")
            return
        }
        XCTAssertTrue(completion.label.contains("Readme.txt"), completion.debugDescription)
        attachScreenshot("Receipt — completion checkmark")
    }

    func testActiveTransferShowsDialStepsAndCancel() {
        let app = launch(scenario: "sending")
        let row = element("transfer.progress", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["transfer.cancel"].exists)
        row.tap()

        XCTAssertTrue(app.navigationBars["正在发送"].waitForExistence(timeout: 5))
        let steps = element("transfer.progress.steps", in: app)
        XCTAssertTrue(steps.exists)
        XCTAssertTrue((steps.value as? String ?? "").contains("传输"), String(describing: steps.value))
        attachScreenshot("Sending — dial, speed and steps")

        app.buttons["transfer.cancel"].tap()
        XCTAssertTrue(app.buttons["transfer.retry"].waitForExistence(timeout: 5))
        app.buttons["transfer.retry"].tap()
        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 5))
        XCTAssertEqual(recipientButtons(in: app).count, 2)
    }

    func testDeliveredTransferFinishesBackToHome() {
        let app = launch(scenario: "delivered")
        let row = element("transfer.progress", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.buttons["transfer.finish"].waitForExistence(timeout: 5))
        attachScreenshot("Sending — delivered")
        app.buttons["transfer.finish"].tap()
        XCTAssertTrue(app.navigationBars["LimLink"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("transfer.progress", in: app).exists)
        XCTAssertFalse(fileNameIsPresented(in: app), "A finished send clears the file card.")
        XCTAssertTrue(app.staticTexts["选择要发送的内容"].exists)
        XCTAssertFalse(app.buttons["transfer.send"].isEnabled)
    }

    func testNewSharedFileAfterBackingOutOfCompletionOpensRecipients() {
        let app = XCUIApplication()
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "delivered"
        app.launchEnvironment["LIMLINK_UI_TEST_SHARE_ON_BACKGROUND"] = "1"
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        let completed = element("transfer.progress", in: app)
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        completed.tap()
        XCTAssertTrue(app.buttons["transfer.finish"].waitForExistence(timeout: 5))
        tapBack(in: app, title: "正在发送")
        XCTAssertTrue(app.navigationBars["LimLink"].waitForExistence(timeout: 5))

        // The existing fixture writes through the real App Group handoff while backgrounded.
        background(app)
        app.activate()

        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(fileNameIsPresented(in: app, name: "分享示例.txt"))
        XCTAssertFalse(app.buttons["transfer.finish"].exists, "The previous completion must not own the new file.")
        XCTAssertEqual(recipientButtons(in: app).count, 2)
        tapBack(in: app, title: "选择设备")
        XCTAssertTrue(fileNameIsPresented(in: app, name: "分享示例.txt"))
        XCTAssertTrue(app.buttons["transfer.send"].isEnabled)
    }

    func testIPadLandscapeShowsDevicesBesideTheFileAndSendsOnTap() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(scenario: "sending")
        XCTAssertTrue(element("transfer.file.selected", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["附近设备"].exists)
        XCTAssertFalse(app.buttons["transfer.send"].exists, "Wide layout sends by tapping a device.")
        XCTAssertEqual(recipientButtons(in: app).count, 2)
        XCTAssertTrue(element("transfer.progress", in: app).exists)
        attachScreenshot("iPad landscape — sending")

        app.buttons["transfer.cancel"].tap()
        app.buttons["transfer.dismiss"].tap()
        let device = recipientButtons(in: app).element(boundBy: 1)
        XCTAssertTrue(device.isEnabled)
        attachScreenshot("iPad landscape — ready to send")

        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["transfer.send"].waitForExistence(timeout: 5), "Portrait falls back to the iPhone layout.")
        XCTAssertFalse(app.staticTexts["附近设备"].exists)
    }

    func testIdentityShowsTheAuthorizedSaveFolder() {
        let app = launch(scenario: "file")
        openIdentity(in: app)
        let current = element("transfer.saveFolder.current", in: app)
        XCTAssertTrue(current.waitForExistence(timeout: 5))
        XCTAssertTrue(current.label.contains("下载"), current.label)
        XCTAssertTrue(app.buttons["transfer.saveFolder.choose"].exists)
    }

    func testTransientStartupFailureRetriesWithoutUserAction() {
        let app = XCUIApplication()
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "retrying"
        app.launchEnvironment["LIMLINK_UI_TEST_STARTUP_FAILURES"] = "2"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launch()
        // Two forced bind failures are retried automatically; no tap on 重试 is needed.
        XCTAssertTrue(element("transfer.startup.ready", in: app).waitForExistence(timeout: 25), app.debugDescription)
        XCTAssertFalse(app.buttons["transfer.startup.retry"].exists)
        attachScreenshot("Startup — recovered automatically")
    }

    func testMultiSelectChoosesSeveralDevicesAndSendsTogether() {
        let app = launch(scenario: "devices")
        app.buttons["transfer.send"].tap()
        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["发送给谁？"].exists)

        app.buttons["transfer.multiSelect"].tap()
        let peers = recipientButtons(in: app)
        XCTAssertEqual(peers.count, 2)
        let sendMultiple = app.buttons["transfer.sendMultiple"]
        XCTAssertTrue(sendMultiple.waitForExistence(timeout: 3))
        XCTAssertFalse(sendMultiple.isEnabled, "Nothing selected yet.")

        peers.element(boundBy: 0).tap()
        peers.element(boundBy: 1).tap()
        XCTAssertTrue(sendMultiple.isEnabled)
        XCTAssertTrue(sendMultiple.label.contains("2 台"), sendMultiple.label)
        attachScreenshot("Recipients — two devices selected")

        app.buttons["transfer.multiSelect"].tap()
        XCTAssertFalse(app.buttons["transfer.sendMultiple"].exists, "Closing multi-select clears the selection.")
    }

    func testIPadSourceChoiceAnchorsNearTheFileCard() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(scenario: "file")
        let card = app.buttons["transfer.file.choose"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        let replace = app.buttons["transfer.file.replace"]
        XCTAssertTrue(replace.exists)
        tapStable(replace, through: app)

        let files = app.buttons["transfer.source.files"].firstMatch
        XCTAssertTrue(files.waitForExistence(timeout: 5), app.debugDescription)
        attachScreenshot("iPad — source choice anchored to the card")
        // A popover anchored to the card sits beside it, not at the top centre of the window.
        XCTAssertLessThan(abs(files.frame.midX - card.frame.midX), 400)
        XCTAssertGreaterThan(files.frame.minY, card.frame.minY - 60)
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.1)).tap()
        XCTAssertTrue(app.buttons["transfer.file.choose"].exists)
    }

    func testIPadWideTitleStaysPutWhileRefreshing() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad layout only") }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(scenario: "devices")
        XCTAssertTrue(app.staticTexts["LimLink"].waitForExistence(timeout: 5))
        let title = app.staticTexts["LimLink"].firstMatch
        let before = title.frame
        app.staticTexts["附近设备"].swipeDown()
        attachScreenshot("iPad — pull to refresh")
        XCTAssertEqual(title.frame.minY, before.minY, accuracy: 1, "The title must not move with pull-to-refresh.")
        XCTAssertTrue(app.staticTexts["附近设备"].exists)
    }

    func testSharedFileOpensTheRecipientPicker() {
        let app = XCUIApplication()
        app.launchEnvironment["LIMLINK_UI_TEST_SHARE"] = "1"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launch()

        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(fileNameIsPresented(in: app, name: "分享示例.txt"))
        attachScreenshot("Share — file handed over from the share sheet")
    }

    func testBindingPickerOpensBeforeChoosingAFile() {
        let app = launch(scenario: "empty")
        XCTAssertFalse(app.buttons["binding.open"].exists)
        openIdentity(in: app)
        let binding = app.buttons["binding.open"]
        for _ in 0..<4 where !binding.isHittable { app.swipeUp() }
        XCTAssertTrue(binding.waitForExistence(timeout: 5))
        binding.tap()
        XCTAssertTrue(app.navigationBars["设备绑定"].waitForExistence(timeout: 5))
        // Physical-device runs use real discovery; only Simulator has an empty fixture.
        XCTAssertTrue(app.staticTexts["附近设备"].exists)
        XCTAssertTrue(app.staticTexts["已绑定设备"].exists)
        app.buttons["binding.done"].tap()
        XCTAssertTrue(app.buttons["transfer.identity.close"].waitForExistence(timeout: 5))
        app.buttons["transfer.identity.close"].tap()
        XCTAssertTrue(app.buttons["transfer.file.choose"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["binding.open"].exists)
    }

    func testPrivacyPolicyOpensOfflineAndReturnsToIdentity() {
        let app = launch(scenario: "empty")
        openIdentity(in: app)
        let policy = app.buttons["privacy.open"]
        for _ in 0..<4 where !policy.isHittable { app.swipeUp() }
        XCTAssertTrue(policy.waitForExistence(timeout: 5))
        policy.tap()

        XCTAssertTrue(element("privacy.policy", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["本地处理"].exists)
        XCTAssertTrue(app.staticTexts["设备之间的传输"].exists)
        XCTAssertTrue(element("privacy.developer", in: app).label.contains("周甫俊"))
        let discovery = element("privacy.discovery", in: app)
        XCTAssertTrue(discovery.label.contains("加密连接后"), discovery.label)
        XCTAssertTrue(discovery.label.contains("公开身份指纹"), discovery.label)
        XCTAssertTrue(discovery.label.contains("其他设备逐文件确认"), discovery.label)
        XCTAssertTrue(element("privacy.binding", in: app).label.contains("绑定不完整时仍逐文件确认"))
        let email = element("privacy.email", in: app)
        for _ in 0..<6 where !email.isHittable { app.swipeUp() }
        XCTAssertTrue(email.exists)
        XCTAssertTrue(email.isHittable)
        XCTAssertTrue(email.label.contains("limlink@floatmax-tech.com"))
        XCTAssertTrue(element("privacy.online", in: app).exists)
        XCTAssertTrue(element("privacy.support", in: app).exists)
        XCTAssertTrue(element("privacy.notifications", in: app).label.contains("控制预览"))
        XCTAssertTrue(element("privacy.storage", in: app).label.contains("最近删除"))
        app.buttons["privacy.close"].tap()
        closeIdentityAfterLegalSheet(in: app)
        XCTAssertTrue(app.navigationBars["LimLink"].waitForExistence(timeout: 5))
    }

    func testUsageTermsOpenOfflineAndReturnToIdentity() {
        let app = launch(scenario: "empty")
        openIdentity(in: app)
        let terms = app.buttons["terms.open"]
        for _ in 0..<4 where !terms.isHittable { app.swipeUp() }
        XCTAssertTrue(terms.waitForExistence(timeout: 5))
        terms.tap()

        XCTAssertTrue(element("terms.usage", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("terms.developer", in: app).label.contains("周甫俊"))
        XCTAssertTrue(element("terms.license", in: app).label.contains("Apple 标准最终用户许可协议"))
        XCTAssertTrue(element("terms.eula", in: app).exists)
        let email = element("terms.email", in: app)
        for _ in 0..<16 where !email.isHittable { app.swipeUp() }
        XCTAssertTrue(email.exists)
        XCTAssertTrue(email.isHittable)
        XCTAssertTrue(email.label.contains("limlink@floatmax-tech.com"))
        XCTAssertTrue(element("terms.online", in: app).exists)
        XCTAssertTrue(element("terms.support", in: app).exists)
        app.buttons["terms.close"].tap()
        closeIdentityAfterLegalSheet(in: app)
        XCTAssertTrue(app.navigationBars["LimLink"].waitForExistence(timeout: 5))
    }

    func testReturningToRunningAppImportsTheShareSavedWhileItWasInBackground() {
        let app = XCUIApplication()
        app.launchEnvironment["LIMLINK_UI_TEST_SHARE_ON_BACKGROUND"] = "1"
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = "empty"
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launch()
        XCTAssertTrue(app.navigationBars["LimLink"].waitForExistence(timeout: 10))
        XCTAssertFalse(fileNameIsPresented(in: app, name: "分享示例.txt"))

        background(app)
        app.activate()

        XCTAssertTrue(app.navigationBars["选择设备"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertTrue(fileNameIsPresented(in: app, name: "分享示例.txt"))
        attachScreenshot("Share — returning to an already running app")
    }

    func testClosingShareExtensionPreservesTheClipboard() {
        let sentinel = "LimLink clipboard regression \(UUID().uuidString)"
        UIPasteboard.general.string = sentinel
        let app = launch(scenario: "received")
        let share = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "分享或存储 ")
        ).firstMatch
        for _ in 0..<4 where !share.exists { app.swipeUp() }
        XCTAssertTrue(share.waitForExistence(timeout: 5), app.debugDescription)
        share.tap()
        let shareSheet = XCUIApplication(bundleIdentifier: "com.apple.SharingUIService")
        let extensionButton = shareSheet.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "LimLink")
        ).firstMatch
        if !extensionButton.waitForExistence(timeout: 5) {
            let more = shareSheet.buttons.matching(NSPredicate(format: "label IN %@", ["更多", "More"])).firstMatch
            XCTAssertTrue(more.waitForExistence(timeout: 5), shareSheet.debugDescription)
            more.tap()
        }
        XCTAssertTrue(extensionButton.waitForExistence(timeout: 10), shareSheet.debugDescription)
        extensionButton.tap()
        let shareExtension = XCUIApplication(bundleIdentifier: "com.limlink.dev.share")
        let close = shareExtension.buttons["关闭"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), shareExtension.debugDescription)
        // XCTest tries to launch an extension as an app when tapping its element directly.
        // Send the event through its existing host using the observed button frame.
        tapStable(close, through: app)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: close)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertEqual(UIPasteboard.general.string, sentinel)
    }

    /// Adaptive toolbars may place Back beside the content instead of inside its title bar.
    private func tapBack(in app: XCUIApplication, title: String) {
        let navigationBack = app.navigationBars[title].buttons.firstMatch
        let back = navigationBack.exists ? navigationBack : app.buttons["BackButton"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), app.debugDescription)
        tapStable(back, through: app)
    }

    /// Scrolling legal links into view can collapse the identity sheet's adaptive toolbar.
    private func closeIdentityAfterLegalSheet(in app: XCUIApplication) {
        let close = app.buttons["transfer.identity.close"]
        for _ in 0..<4 {
            if close.exists && close.isHittable { break }
            app.swipeDown()
        }
        guard close.waitForExistence(timeout: 5), close.isHittable else {
            attachScreenshot("Identity Close unavailable after legal sheet")
            XCTFail("Identity Close did not reappear after scrolling: \(app.debugDescription)")
            return
        }
        tapStable(close, through: app)
    }

    private func background(_ app: XCUIApplication) {
        XCUIDevice.shared.press(.home)
        if app.state == .runningForeground {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        let backgrounded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.state == .runningBackground || app.state == .runningBackgroundSuspended
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [backgrounded], timeout: 5), .completed,
                       "The running app must enter the background before testing share import")
    }

    private func openIdentity(in app: XCUIApplication) {
        let button = app.buttons["transfer.identity"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        tapStable(button, through: app)
        let opened = app.buttons["transfer.identity.close"].waitForExistence(timeout: 5)
        if !opened { attachScreenshot("Identity did not open") }
        XCTAssertTrue(opened)
    }

    /// Sheet elements can exist while their entrance animation is still moving them.
    /// Tap only after the observed hit target has stopped moving, without disabling animations.
    private func tapStable(_ element: XCUIElement, through app: XCUIApplication) {
        var previous = CGRect.null
        var stableSince = Date()
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard element.exists, element.isHittable else { stableSince = Date(); return false }
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

    private func launch(scenario: String) -> XCUIApplication {
        let orientation = XCUIDevice.shared.orientation
        let app = XCUIApplication()
        app.launchEnvironment["LIMLINK_UI_TEST_SCENARIO"] = scenario
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launchEnvironment["LIMLINK_UI_TEST_RESET_LANGUAGE"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(app.buttons["transfer.file.choose"].waitForExistence(timeout: 10), app.debugDescription)
        let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
        let oriented = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            return landscape ? frame.width > frame.height : frame.height > frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [oriented], timeout: 10), .completed, "Unexpected launch orientation")
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func recipientButtons(in app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transfer.peer."))
    }

    private func fileNameIsPresented(in app: XCUIApplication, name: String = "示例资料.pdf") -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists
    }

    private func assertNoRecipientsOnHome(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(app.staticTexts["附近设备"].exists, file: file, line: line)
        XCTAssertEqual(recipientButtons(in: app).count, 0, file: file, line: line)
        XCTAssertFalse(element("transfer.recipientPicker", in: app).exists, file: file, line: line)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
