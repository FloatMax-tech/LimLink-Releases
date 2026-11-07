import XCTest

final class ConfigFileTests: XCTestCase {
    func testEntitlementsMatchTheMacPlanAndOmitMulticast() throws {
        let plist = try Self.plist(at: "App/LimLinkMac.entitlements")
        let required = [
            "com.apple.security.app-sandbox",
            "com.apple.security.network.server",
            "com.apple.security.network.client",
            "com.apple.security.files.downloads.read-write",
            "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope",
        ]
        for key in required {
            XCTAssertEqual(plist[key] as? Bool, true, key)
        }
        XCTAssertNil(plist["com.apple.developer.networking.multicast"])
        XCTAssertNil(plist["com.apple.security.files.user-selected.executable"])
    }

    func testInfoPlistDeclaresLocalNetworkAndBonjour() throws {
        let plist = try Self.plist(at: "App/Info.plist")
        let usage = try XCTUnwrap(plist["NSLocalNetworkUsageDescription"] as? String)
        XCTAssertTrue(usage.contains("Wi-Fi"))
        XCTAssertTrue(usage.contains("附近"))
        XCTAssertTrue(usage.contains("传输"))
        XCTAssertTrue(usage.contains("不经过互联网"))
        let services = try XCTUnwrap(plist["NSBonjourServices"] as? [String])
        XCTAssertEqual(services, ["_limlink._tcp"])
        XCTAssertNil(plist["LSUIElement"])
    }

    func testExportOptionsCoverAppStoreAndDeveloperID() throws {
        let appStore = try Self.plist(at: "ExportOptions/AppStore.plist")
        XCTAssertEqual(appStore["method"] as? String, "app-store-connect")
        XCTAssertEqual(appStore["teamID"] as? String, "J8PZU3W5VL")
        let developerID = try Self.plist(at: "ExportOptions/DeveloperID.plist")
        XCTAssertEqual(developerID["method"] as? String, "developer-id")
        XCTAssertEqual(developerID["teamID"] as? String, "J8PZU3W5VL")
    }

    func testPhotoSavingDeclaresAddOnlyUsageAndMacCapability() throws {
        let info = try Self.plist(at: "App/Info.plist")
        XCTAssertFalse(try XCTUnwrap(info["NSPhotoLibraryAddUsageDescription"] as? String).isEmpty)
        XCTAssertNil(info["NSPhotoLibraryUsageDescription"])
        let entitlements = try Self.plist(at: "App/LimLinkMac.entitlements")
        XCTAssertEqual(entitlements["com.apple.security.personal-information.photos-library"] as? Bool, true)
    }

    func testProjectDoesNotBundleAnUpdaterOrMulticast() throws {
        let root = Self.macRoot()
        let project = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(project.contains("com.limlink.dev"))
        XCTAssertTrue(project.contains("ENABLE_HARDENED_RUNTIME: YES"))
        XCTAssertTrue(project.contains("J8PZU3W5VL"))
        XCTAssertTrue(project.contains("MACOSX_DEPLOYMENT_TARGET: \"14.0\""))
        XCTAssertFalse(project.contains("multicast"))
        XCTAssertFalse(project.localizedCaseInsensitiveContains("sparkle"))

        for relative in ["App", "Sources", "ExportOptions"] {
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(relative),
                includingPropertiesForKeys: nil
            )!
            while let item = enumerator.nextObject() as? URL {
                guard ["swift", "plist", "entitlements"].contains(item.pathExtension) else { continue }
                let text = try String(contentsOf: item, encoding: .utf8)
                XCTAssertFalse(text.contains("com.apple.developer.networking.multicast"), item.lastPathComponent)
                XCTAssertFalse(text.localizedCaseInsensitiveContains("sparkle"), item.lastPathComponent)
            }
        }
    }

    private static func macRoot() -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("project.yml").path) {
            return source
        }
        return Bundle(for: ConfigFileTests.self).resourceURL!
    }

    private static func plist(at relativePath: String) throws -> [String: Any] {
        let url = macRoot().appendingPathComponent(relativePath)
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(object as? [String: Any])
    }
}
