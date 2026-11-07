import Foundation
import Observation
import Photos
#if os(iOS)
import UIKit
#else
import AppKit
#endif

public enum PhotoSaveState: Equatable { case saving, saved, denied, failed, uncertain }

/// Receipt is acknowledged before this independent, local-only Photos operation starts.
@MainActor @Observable
public final class ReceivedPhotoLibrary {
    public static let shared = ReceivedPhotoLibrary()
    public var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: Self.preferenceKey) }
    }
    public private(set) var states: [URL: PhotoSaveState] = [:]
    public var notice: String?
    @ObservationIgnored private var gate: PhotoExportGate
    @ObservationIgnored private var running: Set<String> = []
    private static let preferenceKey = "limlink.photos.auto-save"
    private static let ledgerKey = "limlink.photos.export-ledger.v1"

    private init() {
        automatic = UserDefaults.standard.object(forKey: Self.preferenceKey) as? Bool ?? true
        gate = PhotoExportGate(snapshot: UserDefaults.standard.dictionary(forKey: Self.ledgerKey) as? [String: String] ?? [:])
    }

    public func didReceive(_ file: SavedFile, sourceAccess: AnyObject? = nil) {
        guard automatic, FilePreviewPolicy.classify(fileName: file.name) == .image else { return }
        save(file, sourceAccess: sourceAccess)
    }

    public func refreshStatus(for file: SavedFile) {
        guard states[file.url] == nil, let key = try? exportKey(for: file) else { return }
        if gate.assetIdentifier(for: key) != nil { states[file.url] = .saved }
        else if gate.isPending(key) { states[file.url] = .uncertain }
    }

    private func exportKey(for file: SavedFile) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw FilePreviewError.unavailable }
        let created = (attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(file.url.absoluteString)|\(file.size)|\(created)|\(modified)"
    }

    public func save(_ file: SavedFile, explicitRetry: Bool = false, holding lease: FilePreviewLease? = nil, sourceAccess: AnyObject? = nil) {
        guard FilePreviewPolicy.classify(fileName: file.name) == .image else { return }
        let key: String
        do { key = try exportKey(for: file) }
        catch { states[file.url] = .failed; return }
        guard !running.contains(key) else { return }
        guard gate.begin(key, retryPending: explicitRetry) else {
            states[file.url] = gate.assetIdentifier(for: key) == nil ? .uncertain : .saved
            return
        }
        persist()
        running.insert(key)
        states[file.url] = .saving
        Task {
            defer { withExtendedLifetime((lease, sourceAccess)) { }; running.remove(key) }
            let granted = file.url.startAccessingSecurityScopedResource()
            defer { if granted { file.url.stopAccessingSecurityScopedResource() } }
            var authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if authorization == .notDetermined { authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly) }
            guard authorization == .authorized || authorization == .limited else {
                gate.failed(key); persist(); states[file.url] = .denied
                return
            }
            let captured = PhotoAssetCapture()
            do {
                let url = file.url
                let name = file.name
                try await PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = name
                    options.shouldMoveFile = false
                    request.addResource(with: .photo, fileURL: url, options: options)
                    captured.store(request.placeholderForCreatedAsset?.localIdentifier)
                }
                guard let identifier = captured.identifier else { throw FilePreviewError.unavailable }
                gate.saved(key, assetIdentifier: identifier)
                states[file.url] = .saved
            } catch {
                gate.failed(key)
                states[file.url] = .failed
            }
            persist()
        }
    }

    private func persist() { UserDefaults.standard.set(gate.snapshot, forKey: Self.ledgerKey) }

    @available(iOSApplicationExtension, unavailable)
    @available(macOSApplicationExtension, unavailable)
    public func openPhotos() {
        #if os(iOS)
        // System Photos may decline an external launch; keep the file available in that case.
        UIApplication.shared.open(URL(string: "photos-redirect://")!, options: [:]) { success in
            if !success { Task { @MainActor in self.notice = L10n.text("请打开系统相册查看收到的图片。") } }
        }
        #else
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") else {
            notice = L10n.text("请打开系统相册查看收到的图片。")
            return
        }
        NSWorkspace.shared.openApplication(at: app, configuration: .init()) { _, error in
            if error != nil { Task { @MainActor in self.notice = L10n.text("请打开系统相册查看收到的图片。") } }
        }
        #endif
    }

    public func label(for url: URL) -> String? {
        switch states[url] {
        case .saving: L10n.text("正在保存到相册…")
        case .saved: L10n.text("已保存到相册")
        case .denied: L10n.text("未获相册权限，文件仍在接收目录")
        case .failed: L10n.text("相册保存未完成，文件仍在接收目录")
        case .uncertain: L10n.text("请先查看相册，确认是否已保存")
        case nil: nil
        }
    }
}

private final class PhotoAssetCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func store(_ value: String?) { lock.lock(); self.value = value; lock.unlock() }
    var identifier: String? { lock.lock(); defer { lock.unlock() }; return value }
}
