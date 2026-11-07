import Foundation
import Observation
import XCTest
@testable import LimLinkAppSupport

final class LocalizationTests: XCTestCase {
    func testRegionalLanguageResolutionAndFallback() {
        XCTAssertEqual(AppLanguage.resolve(["zh-TW"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.resolve(["zh-HK"]), "zh-Hant")
        XCTAssertEqual(AppLanguage.resolve(["zh-Hans-SG"]), "zh-Hans")
        XCTAssertEqual(AppLanguage.resolve(["fr-CA"]), "fr")
        XCTAssertEqual(AppLanguage.resolve(["pt-BR", "ja-JP"]), "ja")
        XCTAssertEqual(AppLanguage.resolve(["ar"]), "en")
        XCTAssertEqual(AppLanguage.resolve([]), "en")
    }

    func testDefaultSystemAndPersistedSelection() {
        let suite = "LimLink.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = LanguagePreference(defaults: defaults, systemLanguages: { ["ja-JP"] })
        XCTAssertEqual(preference.selection, "system")
        XCTAssertEqual(preference.resolvedLanguage, "ja")
        preference.selection = "de"
        XCTAssertEqual(LanguagePreference(defaults: defaults).selection, "de")
        XCTAssertEqual(preference.resolvedLanguage, "de")
        preference.selection = "invalid"
        XCTAssertEqual(preference.selection, "system")
        XCTAssertEqual(preference.resolvedLanguage, "ja")
    }

    func testInterpolationDoesNotInterpretInsertedTextOrChangeNames() {
        XCTAssertEqual(L10n.interpolate("{1}: {0}", arguments: ["报告 {1}.pdf", "Jun 的 iPhone"]), "Jun 的 iPhone: 报告 {1}.pdf")
        XCTAssertEqual(L10n.interpolate("100% — {0}", arguments: ["a%@.zip"]), "100% — a%@.zip")
    }

    func testLanguageChangeInvalidatesObservedTextWithoutReplacingPreference() {
        let suite = "LimLink.LocalizationObservation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preference = LanguagePreference(defaults: defaults)
        let changed = expectation(description: "language changed")
        _ = withObservationTracking { preference.resolvedLanguage } onChange: { changed.fulfill() }
        preference.selection = "it"
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(preference.resolvedLanguage, "it")
    }

    func testExplicitBundleLanguageAndEnglishFallback() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: folder) }
        for (language, value) in [("en", "Sent {0}"), ("ja", "送信済み {0}")] {
            let localized = folder.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
            try "\"sent\" = \"\(value)\";".write(to: localized.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let bundle = try XCTUnwrap(Bundle(path: folder.path))
        XCTAssertEqual(L10n.localized("sent", arguments: ["报告.pdf"], language: "ja", bundle: bundle), "送信済み 报告.pdf")
        XCTAssertEqual(L10n.localized("sent", arguments: ["报告.pdf"], language: "fr", bundle: bundle), "Sent 报告.pdf")
    }

    func testMissingTranslationFallsBackToSource() {
        XCTAssertEqual(L10n.text("未知测试 {0}", "file.zip"), "未知测试 file.zip")
    }

    func testTransferStepAccessibilityDescriptionsUseCompleteSentencesInEveryLanguage() throws {
        try withCatalogBundle { bundle in
            let expected = [
                ("zh-Hans", "当前第 3 步，共 4 步：传输", "停在第 3 步，共 4 步：传输"),
                ("zh-Hant", "目前第 3 步，共 4 步：傳輸", "停在第 3 步，共 4 步：傳輸"),
                ("en", "Current step 3 of 4: Transfer", "Stopped at step 3 of 4: Transfer"),
                ("ja", "現在のステップ 3/4：転送", "ステップ 3/4 で停止：転送"),
                ("ko", "현재 4단계 중 3단계: 전송", "4단계 중 3단계에서 중단: 전송"),
                ("fr", "Étape actuelle 3 sur 4 : Transfert", "Arrêté à l’étape 3 sur 4 : Transfert"),
                ("de", "Aktueller Schritt 3 von 4: Übertragung", "Angehalten bei Schritt 3 von 4: Übertragung"),
                ("es", "Paso actual 3 de 4: Transferencia", "Detenido en el paso 3 de 4: Transferencia"),
                ("it", "Passaggio attuale 3 di 4: Trasferimento", "Interrotto al passaggio 3 di 4: Trasferimento"),
            ]
            for (language, active, stopped) in expected {
                let title = L10n.localized("传输", language: language, bundle: bundle)
                XCTAssertEqual(L10n.localized("当前第 {0} 步，共 4 步：{1}", arguments: ["3", title], language: language, bundle: bundle), active, language)
                XCTAssertEqual(L10n.localized("停在第 {0} 步，共 4 步：{1}", arguments: ["3", title], language: language, bundle: bundle), stopped, language)
            }
        }
    }

    func testCatalogLocalizationPreservesFileAndUserNamesVerbatim() throws {
        try withCatalogBundle { bundle in
            let fileName = "报告 {1} 100%@.pdf"
            let userName = "Léa {0} 的 iPhone %@"
            XCTAssertEqual(L10n.localized("已收到 {0}", arguments: [fileName], language: "en", bundle: bundle), "Received 报告 {1} 100%@.pdf")
            XCTAssertEqual(L10n.localized("已收到 {0}", arguments: [fileName], language: "fr", bundle: bundle), "报告 {1} 100%@.pdf reçu")
            XCTAssertEqual(L10n.localized("{0} 想发送文件", arguments: [userName], language: "en", bundle: bundle), "Léa {0} 的 iPhone %@ wants to send a file")
            XCTAssertEqual(L10n.localized("{0} 想发送文件", arguments: [userName], language: "fr", bundle: bundle), "Léa {0} 的 iPhone %@ souhaite envoyer un fichier")
        }
    }

    /// Exercise the shipped catalog with the same bundle lookup and interpolation as the apps.
    private func withCatalogBundle(_ assertions: (Bundle) throws -> Void) throws {
        let appleDirectory = (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
        let catalogURL = appleDirectory.appendingPathComponent("Shared/Localization/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: catalogURL))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        defer { try? FileManager.default.removeItem(at: folder) }
        for language in AppLanguage.supported {
            let localized = folder.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: localized, withIntermediateDirectories: true)
            let translations = catalog.strings.compactMapValues { $0.localizations[language]?.stringUnit.value }
            let data = try PropertyListSerialization.data(fromPropertyList: translations, format: .xml, options: 0)
            try data.write(to: localized.appendingPathComponent("Localizable.strings"))
        }
        try assertions(XCTUnwrap(Bundle(path: folder.path)))
    }

    private struct Catalog: Decodable {
        let strings: [String: Entry]
        struct Entry: Decodable {
            let localizations: [String: Translation]
        }
        struct Translation: Decodable {
            let stringUnit: Unit
        }
        struct Unit: Decodable {
            let value: String
        }
    }
}
