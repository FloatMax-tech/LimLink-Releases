import Foundation

/// Receiver-side name rules that the single-file path can apply without a filesystem.
public enum FileNameSafety {
    /// Last extension only, compared without case. A warning, not a block (protocol §0).
    public static let executableExtensions: Set<String> = [
        "exe", "msi", "msix", "appx", "bat", "cmd", "com", "scr", "ps1", "vbs", "lnk",
        "app", "dmg", "pkg", "command", "ipa",
        "apk", "apks", "xapk", "aab",
        "sh", "jar",
    ]

    public static func warnsExecutable(_ fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else { return false }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return executableExtensions.contains(String(ext))
    }

    /// NFC, then case-insensitive. Inserts ` (1)` before the last extension. Does not overwrite.
    public static func uniqueName(_ name: String, existing: Set<String>) -> String {
        let used = Set(existing.map(fold))
        var candidate = name
        var index = 1
        while used.contains(fold(candidate)) {
            candidate = numbered(name, index)
            index += 1
            if index > 10_000 { break }
        }
        return candidate
    }

    private static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func numbered(_ name: String, _ index: Int) -> String {
        let nfc = name.precomposedStringWithCanonicalMapping
        guard let dot = nfc.lastIndex(of: "."), dot != nfc.startIndex else {
            return "\(nfc) (\(index))"
        }
        return "\(nfc[..<dot]) (\(index))\(nfc[dot...])"
    }
}
