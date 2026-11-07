import Foundation

enum WebsiteUpdateError: Error, Equatable { case unpublished, invalid }

struct WebsiteUpdate: Equatable {
    static let downloadURL = URL(string: "https://limlink.floatmax-tech.com/download/macos")!
    let version: String
    let notes: String
    var url: URL { Self.downloadURL }
}

enum WebsiteUpdateManifest {
    static let maxBytes = 131_072

    static func parse(_ data: Data, installed: String) throws -> WebsiteUpdate? {
        guard data.count <= maxBytes else { throw WebsiteUpdateError.invalid }
        let current = try components(installed)
        struct Entry: Decodable {
            let version: String
            let url: String
            let size: Int64
            let sha256: String
            let notes: String?
        }
        struct Index: Decodable { let macos: Entry? }
        let index: Index
        do { index = try JSONDecoder().decode(Index.self, from: data) }
        catch { throw WebsiteUpdateError.invalid }
        guard let entry = index.macos else { throw WebsiteUpdateError.unpublished }
        let next = try components(entry.version)
        guard entry.url == "/download/macos", entry.size > 0,
              entry.sha256.utf8.count == 64,
              entry.sha256.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              (entry.notes?.count ?? 0) <= 8000 else { throw WebsiteUpdateError.invalid }
        return current.lexicographicallyPrecedes(next) ? WebsiteUpdate(version: entry.version, notes: entry.notes ?? "") : nil
    }

    private static func components(_ version: String) throws -> [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { throw WebsiteUpdateError.invalid }
        var values = try parts.map { part -> Int in
            guard (1...5).contains(part.utf8.count), part.utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(part), value <= 65535 else { throw WebsiteUpdateError.invalid }
            return value
        }
        if values.count == 2 { values.append(0) }
        return values
    }
}

#if LIMLINK_DIRECT_DISTRIBUTION
/// Only compiled into the website edition. No startup caller or background schedule.
private final class WebsiteNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum WebsiteUpdateClient {
    static func check(installed: String) async throws -> WebsiteUpdate? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: WebsiteNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://limlink.floatmax-tech.com/version.json")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("LimLink/\(installed) (macOS)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebsiteUpdateError.invalid }
        if http.statusCode == 404 { throw WebsiteUpdateError.unpublished }
        guard http.statusCode == 200, response.expectedContentLength <= Int64(WebsiteUpdateManifest.maxBytes) else {
            throw WebsiteUpdateError.invalid
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < WebsiteUpdateManifest.maxBytes else { throw WebsiteUpdateError.invalid }
            data.append(byte)
        }
        return try WebsiteUpdateManifest.parse(data, installed: installed)
    }
}
#endif
