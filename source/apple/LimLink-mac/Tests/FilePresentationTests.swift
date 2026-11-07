import Foundation
import XCTest
import LimLinkAppSupport

final class FilePresentationTests: XCTestCase {
    func testPreviewUsesOriginalFilenameAndDoesNotTreatProgramsAsMedia() {
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "Holiday.HEIC"), .image)
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "report.PDF"), .pdf)
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "clip.mp4"), .video)
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "voice.m4a"), .audio)
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "page.html"), .text)
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "invoice.pdf.exe"), .unsupported)
        XCTAssertEqual(FilePreviewPolicy.classify(fileName: "report.docx"), .unsupported)
    }

    func testTextPreviewReadsOnlyBoundedPrefixAndMarksTruncation() throws {
        let file = try temporaryFile(Data(repeating: 65, count: 400_000))
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try FilePreviewPolicy.readText(at: file)
        XCTAssertTrue(text.truncated)
        XCTAssertEqual(text.text.count, 262_144)
        XCTAssertEqual(text.text.prefix(4), "AAAA")
    }

    func testBinaryAndNonLocalURLsCannotBeTextPreviews() throws {
        let file = try temporaryFile(Data([0, 1, 2, 3, 0, 4]))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try FilePreviewPolicy.readText(at: file))
        XCTAssertThrowsError(try FilePreviewPolicy.readText(at: URL(string: "https://example.invalid/file.txt")!))
    }

    func testTextPreviewAcceptsUTF16BOMWithoutCallingItBinary() throws {
        let file = try temporaryFile(Data([0xFF, 0xFE, 0x41, 0, 0x42, 0]))
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try FilePreviewPolicy.readText(at: file).text, "AB")
    }

    func testBoundedUTF16PreviewDoesNotRejectASplitSurrogatePair() throws {
        var data = Data([0xFF, 0xFE])
        for _ in 0..<131_070 { data.append(contentsOf: [0x41, 0]) }
        data.append(contentsOf: [0x3D, 0xD8, 0, 0xDE])
        let file = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: file) }
        let text = try FilePreviewPolicy.readText(at: file)
        XCTAssertTrue(text.truncated)
        XCTAssertEqual(text.text.count, 131_070)
    }

    func testSelectedSnapshotPreviewRetainsItsOriginalExtension() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("photo.png")
        try Data([1, 2, 3]).write(to: input)
        let selected = try await TransferFileStore(inbox: root).load(input)
        let lease = try FilePreviewLease(file: selected)
        XCTAssertEqual(lease.url.lastPathComponent, "photo.png")
        XCTAssertEqual(try Data(contentsOf: lease.url), Data([1, 2, 3]))
        XCTAssertEqual(lease.originalURL, input)
    }

    func testPendingAndSavedPhotoExportsSurviveRestartWithoutAutomaticDuplicates() {
        var gate = PhotoExportGate()
        XCTAssertTrue(gate.begin("photo-1"))
        XCTAssertFalse(gate.begin("photo-1"))
        var restarted = PhotoExportGate(snapshot: gate.snapshot)
        XCTAssertFalse(restarted.begin("photo-1"))
        restarted.saved("photo-1", assetIdentifier: "asset-1")
        var saved = PhotoExportGate(snapshot: restarted.snapshot)
        XCTAssertFalse(saved.begin("photo-1"))
        XCTAssertEqual(saved.assetIdentifier(for: "photo-1"), "asset-1")
    }

    func testFailedPhotoExportCanRetryButNeverBecomesSaved() {
        var gate = PhotoExportGate()
        XCTAssertTrue(gate.begin("photo-1"))
        gate.failed("photo-1")
        XCTAssertNil(gate.assetIdentifier(for: "photo-1"))
        XCTAssertTrue(gate.begin("photo-1"))
    }

    func testInterruptedPhotoExportRequiresAnExplicitRetry() {
        var gate = PhotoExportGate(snapshot: ["photo-1": "pending"])
        XCTAssertFalse(gate.begin("photo-1"))
        XCTAssertTrue(gate.begin("photo-1", retryPending: true))
        XCTAssertTrue(gate.isPending("photo-1"))
    }

    func testRowSwipeSuppressesItsReleaseActivationWithoutDisablingLaterTapsOrOtherRows() {
        var swiped = FileActionActivationGate()
        let other = FileActionActivationGate()
        XCTAssertTrue(swiped.allowsActivation(uptime: 100))
        swiped.recordHorizontalSwipe(uptime: 100)
        XCTAssertFalse(swiped.allowsActivation(uptime: 100), "A recognized swipe must not also open the file")
        XCTAssertFalse(swiped.allowsActivation(uptime: 101), "A stationary swipe hold stays blocked")
        swiped.endHorizontalSwipe(uptime: 101)
        XCTAssertFalse(swiped.allowsActivation(uptime: 101.1), "The release of a long swipe stays suppressed")
        XCTAssertTrue(other.allowsActivation(uptime: 101.1), "Another row remains interactive")
        XCTAssertTrue(swiped.allowsActivation(uptime: 101.5), "A later deliberate tap may open the preview")
        swiped.recordHorizontalSwipe(uptime: 102)
        swiped.endHorizontalSwipe(uptime: 102.1) // Gesture cancellation uses the same balanced end.
        XCTAssertTrue(swiped.allowsActivation(uptime: 103))
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }
}
