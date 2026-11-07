#!/usr/bin/env python3
"""Execute the app's actual state/lifecycle methods without a Simulator runtime.

The slices are compiled, not compared as source text. Only UIKit presentation and
external picker/network boundaries are replaced; filesystem ownership stays real.
Run from any directory with Python 3 and the active Xcode Swift compiler.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'LimLink-iOS/App'
SHARE = ROOT / 'LimLink-iOS/ShareExtension'


def declaration(source, signature):
    start = source.index(signature)
    start = source.rfind('\n', 0, start) + 1
    opening = source.index('{', start)
    depth, quoted, escaped, comment = 0, False, False, False
    for index in range(opening, len(source)):
        char = source[index]
        if comment:
            if char == '\n':
                comment = False
            continue
        if quoted:
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                quoted = False
            continue
        if char == '"':
            quoted = True
        elif source[index:index + 2] == '//':
            comment = True
        elif char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1].replace('@objc ', '')
    raise ValueError(f'Unclosed declaration: {signature}')


model = (APP / 'TransferModel.swift').read_text()
controller = (SHARE / 'ShareViewController.swift').read_text()
# Keep the real stored lifecycle properties, while replacing only UIKit layout.
fields = controller[controller.index('    private var file:'):controller.index('    override func viewDidLoad')]
fields = '\n'.join(line for line in fields.splitlines() if 'UIStackView' not in line)
selection_methods = '\n'.join(declaration(model, signature) for signature in [
    'func importSharedFile(', 'func importFile(', 'func importPhoto(', 'func importDroppedFile('
])
if 'func selectImportedFile(' in model:
    selection_methods += '\n' + declaration(model, 'func selectImportedFile(')
share_methods = '\n'.join(declaration(controller, signature) for signature in [
    'func receiveSharedItem(', 'func didReceive(', 'func chooseDevice(',
    'func deviceTapped(', 'func cancel(', 'func finishNow(', 'func showError(', 'func copyToScratch('
])
shared_file = declaration(controller, 'class SharedFile' if 'class SharedFile' in controller else 'struct SharedFile')

prefix = r'''
import Foundation

enum TransferFileStoreError: Error {}
struct TransferFile: Sendable { let name: String }
actor ImportStore {
    func load(_ url: URL) throws -> TransferFile {
        _ = try Data(contentsOf: url)
        return TransferFile(name: url.lastPathComponent)
    }
}
struct TransferProgress { enum State { case completed, cancelled, failed; var isFinished: Bool { true } }; var state: State }
struct UserMessage { init(text: String) {} }
enum PhotoImportError: Error { case unavailable }
struct PickedPhoto: Sendable { let url: URL }
struct PickedFile: Sendable { let url: URL }
struct PhotosPickerItem {
    let url: URL
    func loadTransferable(type: PickedPhoto.Type) async throws -> PickedPhoto? { PickedPhoto(url: url) }
}
enum TransferLimits { static let maximumFileBytes = 5_000_000_000 }
enum ShareInboxError: Error { case notAFile, tooLarge }
enum L10n { static func text(_ key: String, _ arguments: String...) -> String { key }; static func message(_ key: String) -> String { key } }

@MainActor final class Model {
    var isSending = false
    var importing = false
    var selectedFile: TransferFile?
    var transfer: TransferProgress?
    var message: UserMessage?
    let files = ImportStore()
    static func fileMessage(_ error: Error) -> String { "import failed" }
'''
selection_end = r'''
}

struct DiscoveredService: Sendable { let instanceName: String }
@MainActor final class UIActivityIndicatorView { enum Style { case medium }; init(style: Style) {}; func stopAnimating() {} }
@MainActor final class UIButton { var tag = 0 }
struct UTType { let identifier: String; static let item = UTType(identifier: "public.item"); init(identifier: String) { self.identifier = identifier }; init?(_ identifier: String) { self.identifier = identifier }; func conforms(to: UTType) -> Bool { true } }
final class Provider: @unchecked Sendable {
    var suggestedName: String? = "shared.txt"
    var registeredTypeIdentifiers = ["public.item"]
    let progress = Progress(totalUnitCount: 1)
    var completion: (@Sendable (URL?, Error?) -> Void)?
    func hasItemConformingToTypeIdentifier(_ type: String) -> Bool { true }
    @discardableResult func loadFileRepresentation(forTypeIdentifier: String, completionHandler: @escaping @Sendable (URL?, Error?) -> Void) -> Progress { completion = completionHandler; return progress }
}
final class NSExtensionItem { let attachments: [Provider]?; init(_ provider: Provider) { attachments = [provider] } }
@MainActor final class Context {
    var inputItems: [NSExtensionItem] = []
    var completed = false
    var completionCount = 0
    func completeRequest(returningItems: [Any]?) { completed = true; completionCount += 1 }
}
@MainActor enum ShareSender {
    static var started = false
    static var delivered = false
    static var cancelled = false
    static var sourceExistsWhileCancelling = false
    static var discoveryStarted = false
    static var discoveryCancelled = false
    static func reset() { started = false; delivered = false; cancelled = false; sourceExistsWhileCancelling = false }
    static func discover() async throws -> [DiscoveredService] {
        discoveryStarted = true
        do { try await Task.sleep(for: .seconds(30)); return [] }
        catch { discoveryCancelled = true; throw error }
    }
    static func send(fileURL: URL, name: String, to: DiscoveredService) async throws {
        started = true
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch {
            cancelled = true
            sourceExistsWhileCancelling = FileManager.default.fileExists(atPath: fileURL.path)
            throw error
        }
        delivered = true
    }
}

@MainActor final class ShareViewController {
    var extensionContext: Context? = Context()
    var latePresentation = false
    var presentations = 0
    func showLoading(_ text: String) {}
    func showMessage(title: String, text: String, doneTitle: String) { presentations += 1; if extensionContext?.completed == true { latePresentation = true } }
    func showActions() { presentations += 1; if extensionContext?.completed == true { latePresentation = true } }
    private func showDevices(_ devices: [DiscoveredService], file: SharedFile) {}
    private func showProgress(file: SharedFile) {}
    private func showSent(file: SharedFile) { presentations += 1; if extensionContext?.completed == true { latePresentation = true } }
    static func message(for error: Error) -> String { "failure" }
'''

suffix = r'''
    func receiveForTest(_ provider: Provider) { extensionContext?.inputItems = [NSExtensionItem(provider)]; receiveSharedItem() }
    func beginSendForTest(_ source: URL) throws -> URL {
        let staged = try Self.copyToScratch(source, name: "shared.txt")
        file = staged
        devices = [DiscoveredService(instanceName: "receiver")]
        deviceTapped(UIButton())
        return staged.url
    }
    func beginDiscoveryForTest(_ source: URL) throws -> URL {
        let staged = try Self.copyToScratch(source, name: "shared.txt")
        file = staged
        chooseDevice()
        return staged.url
    }
    func closeForTest() { cancel() }
    var selectedURLForTest: URL? { file?.url }
}
'''

# The ownership type is production code as well, including its deinitializer.
suffix += shared_file
suffix += r'''

@main struct RegressionTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LimLinkBehaviorTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("next-file.txt")
        try Data("keep original".utf8).write(to: source)
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures.append(name) }
        }
        for path in ["file", "shared", "photo", "drop"] {
            let model = Model()
            model.transfer = TransferProgress(state: .completed)
            switch path {
            case "file": await model.importFile(source)
            case "shared": _ = await model.importSharedFile(source)
            case "photo": await model.importPhoto(PhotosPickerItem(url: source))
            default: await model.importDroppedFile(PickedFile(url: source))
            }
            check(model.selectedFile?.name == "next-file.txt" && model.transfer == nil,
                  "\(path) import starts a new composer instead of the previous completion")
        }
        let failed = Model()
        failed.transfer = TransferProgress(state: .completed)
        await failed.importFile(root.appendingPathComponent("missing.txt"))
        check(failed.transfer != nil, "a failed import preserves the previous completion")

        ShareSender.reset()
        let active = ShareViewController()
        let staged = try active.beginSendForTest(source)
        for _ in 0..<100 where !ShareSender.started { await Task.yield() }
        check(ShareSender.started, "send reached the cancellable transport boundary")
        active.closeForTest()
        try await Task.sleep(for: .milliseconds(200))
        check(ShareSender.cancelled && !ShareSender.delivered, "closing cancels the active send before delivery")
        check(ShareSender.sourceExistsWhileCancelling, "the active operation retains its owned scratch until cancellation unwinds")
        check(!FileManager.default.fileExists(atPath: staged.path), "closed send removes its scratch after the operation unwinds")
        active.closeForTest()
        check(active.extensionContext?.completionCount == 1 && !active.latePresentation, "closed send completes once without late UI")

        let discovering = ShareViewController()
        let discoveredScratch = try discovering.beginDiscoveryForTest(source)
        for _ in 0..<100 where !ShareSender.discoveryStarted { await Task.yield() }
        discovering.closeForTest()
        try await Task.sleep(for: .milliseconds(100))
        check(ShareSender.discoveryCancelled && !discovering.latePresentation, "closing cancels discovery without late UI")
        check(!FileManager.default.fileExists(atPath: discoveredScratch.path), "cancelled discovery releases its scratch")

        let provider = Provider()
        let late = ShareViewController()
        late.receiveForTest(provider)
        late.closeForTest()
        check(provider.progress.isCancelled, "closing cancels the outstanding provider load")
        provider.completion?(source, nil)
        try await Task.sleep(for: .milliseconds(100))
        check(late.selectedURLForTest == nil && !late.latePresentation, "a late provider result cannot reselect a file or update closed UI")
        let failedProvider = Provider()
        let lateFailure = ShareViewController()
        lateFailure.receiveForTest(failedProvider)
        lateFailure.closeForTest()
        failedProvider.completion?(nil, CocoaError(.userCancelled))
        try await Task.sleep(for: .milliseconds(100))
        check(!lateFailure.latePresentation, "a provider error after closing cannot update UI")
        check(try Data(contentsOf: source) == Data("keep original".utf8), "closing never removes the provider's original file")

        if !failures.isEmpty { exit(1) }
    }
}
'''

with tempfile.TemporaryDirectory(prefix='limlink-behavior-build-') as scratch:
    source = Path(scratch) / 'BehaviorTests.swift'
    binary = Path(scratch) / 'BehaviorTests'
    source.write_text(prefix + selection_methods + selection_end + fields + share_methods + suffix)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6', str(source), '-o', str(binary)], check=True)
    raise SystemExit(subprocess.run([str(binary)]).returncode)
