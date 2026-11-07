import Foundation
import XCTest
@testable import LimLinkAppSupport

@MainActor
final class DeviceNamePreferenceTests: XCTestCase {
    func testSavedNamePersistsAcrossInstances() async throws {
        try withIsolatedDefaults { defaults, suiteName in
            let first = DeviceNamePreference(defaults: defaults)
            XCTAssertEqual(try first.save("  甫俊的 iPhone 📱  "), "甫俊的 iPhone 📱")

            let reloadedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            let second = DeviceNamePreference(defaults: reloadedDefaults)
            XCTAssertEqual(second.resolvedName(fallback: "iPhone"), "甫俊的 iPhone 📱")
        }
    }

    func testMissingPreferenceUsesProvidedFallback() async throws {
        try withIsolatedDefaults { defaults, _ in
            XCTAssertEqual(DeviceNamePreference(defaults: defaults).resolvedName(fallback: "iPad"), "iPad")
        }
    }

    func testValidationTrimsWhitespaceAndNormalizesToPrecomposedUnicode() async throws {
        let name = try DeviceNamePreference.validatedName(" \t\nCafe\u{301} 的手机\r\n ")
        XCTAssertEqual(Array(name.utf8), Array("Café 的手机".utf8))
    }

    func testValidationPreservesChineseAndJoinedEmoji() async throws {
        XCTAssertEqual(try DeviceNamePreference.validatedName("家里的手机 👨‍👩‍👧‍👦"), "家里的手机 👨‍👩‍👧‍👦")
    }

    func testASCIINameAllows63BytesAndRejects64WithoutTruncating() async throws {
        let accepted = String(repeating: "a", count: 63)
        XCTAssertEqual(try DeviceNamePreference.validatedName(accepted), accepted)
        XCTAssertThrowsError(try DeviceNamePreference.validatedName(accepted + "a"))
    }

    func testChineseNameLimitCountsUTF8BytesInsteadOfCharacters() async throws {
        let accepted = String(repeating: "中", count: 21)
        XCTAssertEqual(try DeviceNamePreference.validatedName(accepted), accepted)
        XCTAssertThrowsError(try DeviceNamePreference.validatedName(accepted + "a"))
        XCTAssertThrowsError(try DeviceNamePreference.validatedName(accepted + "中"))
    }

    func testByteLimitAppliesAfterNormalizationAndTrimming() async throws {
        let proposed = " " + String(repeating: "e\u{301}", count: 31) + "a\n"
        let accepted = String(repeating: "é", count: 31) + "a"
        XCTAssertEqual(Array(try DeviceNamePreference.validatedName(proposed).utf8), Array(accepted.utf8))
    }

    func testEmptyAndWhitespaceOnlyNamesAreRejectedWithChineseLocalizedErrors() async {
        for proposed in ["", " \n\r\t\u{3000}"] {
            XCTAssertThrowsError(try DeviceNamePreference.validatedName(proposed)) { error in
                XCTAssertNotNil(error as? LocalizedError)
                XCTAssertTrue(error.localizedDescription.contains("名称"))
            }
        }
    }

    func testInteriorControlsAndNewlinesAreRejectedWithChineseLocalizedErrors() async {
        for scalar in ["\u{0}", "\t", "\n", "\r", "\u{7F}", "\u{85}", "\u{2028}", "\u{2029}"] {
            XCTAssertThrowsError(try DeviceNamePreference.validatedName("我的" + scalar + "手机")) { error in
                XCTAssertNotNil(error as? LocalizedError)
                XCTAssertTrue(error.localizedDescription.contains("名称"))
            }
        }
        XCTAssertThrowsError(try DeviceNamePreference.validatedName("\u{0}手机"))
        XCTAssertThrowsError(try DeviceNamePreference.validatedName("手机\u{7F}"))
    }

    func testInvalidStoredValuesUseFallback() async throws {
        try withIsolatedDefaults { defaults, _ in
            let preference = DeviceNamePreference(defaults: defaults)
            for invalid in ["", " \n", "手机\n名称", String(repeating: "中", count: 22)] {
                defaults.set(invalid, forKey: "limlink.customDeviceName")
                XCTAssertEqual(preference.resolvedName(fallback: "iPhone"), "iPhone")
            }
            defaults.set(["unexpected": "object"], forKey: "limlink.customDeviceName")
            XCTAssertEqual(preference.resolvedName(fallback: "iPhone"), "iPhone")
        }
    }

    func testStoredValidNameIsNormalizedWhenResolved() async throws {
        try withIsolatedDefaults { defaults, _ in
            defaults.set("  Cafe\u{301}\n", forKey: "limlink.customDeviceName")
            let resolved = DeviceNamePreference(defaults: defaults).resolvedName(fallback: "iPhone")
            XCTAssertEqual(Array(resolved.utf8), Array("Café".utf8))
        }
    }

    func testFailedSavePreservesPreviousName() async throws {
        try withIsolatedDefaults { defaults, _ in
            let preference = DeviceNamePreference(defaults: defaults)
            try preference.save("旧手机名称")
            for invalid in ["", "手机\t名称", String(repeating: "a", count: 64)] {
                XCTAssertThrowsError(try preference.save(invalid))
                XCTAssertEqual(preference.resolvedName(fallback: "iPhone"), "旧手机名称")
                XCTAssertEqual(defaults.string(forKey: "limlink.customDeviceName"), "旧手机名称")
            }
        }
    }

    private func withIsolatedDefaults(_ body: (UserDefaults, String) throws -> Void) throws {
        let suiteName = "DeviceNamePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults, suiteName)
    }
}
