import Foundation
import LimLinkAppSupport
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import QuickLook
import UIKit
#else
import AppKit
import QuickLookUI
#endif

private struct FilePreviewRequest: Identifiable {
    let id = UUID()
    let lease: FilePreviewLease
    let name: String
    let size: Int
}

/// The filename/card and the explicit eye control share the same leased preview path.
struct FilePreviewButton<Content: View>: View {
    private let file: SavedFile?
    private let selection: TransferFile?
    private let content: Content
    @State private var request: FilePreviewRequest?
    @State private var failed = false
    @Environment(\.mayActivateReceivedFile) private var mayActivate

    init(file: SavedFile, @ViewBuilder label: () -> Content) { self.file = file; selection = nil; content = label() }
    init(selection: TransferFile, @ViewBuilder label: () -> Content) { self.selection = selection; file = nil; content = label() }

    var body: some View {
        Button {
            guard mayActivate() else { return }
            do {
                if let file {
                    request = FilePreviewRequest(lease: try FilePreviewLease(url: file.url, name: file.name, accessRoot: file.accessRoot), name: file.name, size: file.size)
                } else if let selection {
                    request = FilePreviewRequest(lease: try FilePreviewLease(file: selection), name: selection.name, size: selection.size)
                }
            } catch { failed = true }
        } label: { content }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("file.preview")
        .sheet(item: $request) { FilePreviewPanel(request: $0) }
        .alert(L10n.text("无法预览此文件"), isPresented: $failed) {
            Button(L10n.text("知道了"), role: .cancel) { }
        } message: { Text(L10n.text("文件可能已被移动或访问权限已变更，请重新选择。")) }
    }
}

extension FilePreviewButton where Content == Label<Text, Image> {
    init(file: SavedFile) { self.init(file: file) { Label(L10n.text("预览"), systemImage: "eye") } }
    init(selection: TransferFile) { self.init(selection: selection) { Label(L10n.text("预览"), systemImage: "eye") } }
}

struct FileLocationButton: View {
    let file: SavedFile
    @State private var showingLocation = false
    @Environment(\.mayActivateReceivedFile) private var mayActivate
    private var isImage: Bool { FilePreviewPolicy.classify(fileName: file.name) == .image }
    var body: some View {
        Button {
            guard mayActivate() else { return }
            if isImage { ReceivedPhotoLibrary.shared.openPhotos() }
            else {
                #if os(macOS)
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
                #else
                showingLocation = true
                #endif
            }
        } label: {
            Label(L10n.text(isImage ? "打开相册" : "打开所在文件夹"), systemImage: isImage ? "photo.on.rectangle" : "folder")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("file.openLocation")
        #if os(iOS)
        .sheet(isPresented: $showingLocation) { FileLocationPicker(directory: file.url.deletingLastPathComponent()) }
        #endif
    }
}

struct PhotoLibraryNotice: ViewModifier {
    @Bindable private var photos = ReceivedPhotoLibrary.shared
    func body(content: Content) -> some View {
        content.alert(L10n.text("相册"), isPresented: Binding(get: { photos.notice != nil }, set: { if !$0 { photos.notice = nil } })) {
            Button(L10n.text("知道了"), role: .cancel) { photos.notice = nil }
        } message: { Text(photos.notice ?? "") }
    }
}

private struct FilePreviewPanel: View {
    let request: FilePreviewRequest
    @Environment(\.dismiss) private var dismiss
    @Bindable private var photos = ReceivedPhotoLibrary.shared
    @State private var text: TextFilePreview?
    @State private var failed = false
    @State private var showingLocation = false
    @State private var confirmPhotoRetry = false
    private var kind: FilePreviewKind { FilePreviewPolicy.classify(fileName: request.name) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if kind == .unsupported || failed {
                        ContentUnavailableView(L10n.text("此格式暂不支持内置预览"), systemImage: "doc", description: Text(request.name))
                    } else if kind == .text {
                        if let text {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    Text(verbatim: text.text).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                    if text.truncated { Text(L10n.text("仅显示文件开头的部分内容")).font(.caption).foregroundStyle(.secondary) }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                            }
                        } else { ProgressView() }
                    } else { NativeFilePreview(url: request.lease.url, name: request.name) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 18) {
                        if kind == .image {
                            Button(L10n.text("打开相册"), systemImage: "photo.on.rectangle") { photos.openPhotos() }
                            Button(L10n.text("保存到相册"), systemImage: "square.and.arrow.down") {
                                if photos.states[request.lease.url] == .uncertain { confirmPhotoRetry = true }
                                else { savePhoto() }
                            }.disabled(photos.states[request.lease.url] == .saving || photos.states[request.lease.url] == .saved)
                        } else {
                            Button(L10n.text("打开所在文件夹"), systemImage: "folder") { openLocation() }
                        }
                        Spacer(minLength: 0)
                        ShareLink(item: request.lease.url) { Label(L10n.text("用其他应用打开"), systemImage: "square.and.arrow.up") }
                    }
                    .buttonStyle(.borderless)
                    if let status = photos.label(for: request.lease.url) { Text(status).font(.caption).foregroundStyle(.secondary) }
                    if photos.states[request.lease.url] == .denied {
                        Text(L10n.text("可在系统设置中允许添加照片，然后重试。")).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding()
            }
            .navigationTitle(request.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("关闭")) { dismiss() } } }
        }
        #if os(macOS)
        .frame(minWidth: 520, idealWidth: 760, minHeight: 440, idealHeight: 600)
        #else
        .sheet(isPresented: $showingLocation) { FileLocationPicker(directory: request.lease.originalURL.deletingLastPathComponent()) }
        #endif
        .task {
            if kind == .image {
                photos.refreshStatus(for: SavedFile(name: request.name, url: request.lease.url, size: request.size))
            }
            guard kind == .text else { return }
            let url = request.lease.url
            let lease = request.lease
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    defer { withExtendedLifetime(lease) { } }
                    try Task.checkCancellation()
                    return try FilePreviewPolicy.readText(at: url)
                }.value
                if !Task.isCancelled { text = loaded }
            }
            catch { failed = true }
        }
        .confirmationDialog(L10n.text("请先查看相册，确认是否已保存"), isPresented: $confirmPhotoRetry) {
            Button(L10n.text("保存到相册")) { savePhoto(explicitRetry: true) }
            Button(L10n.text("取消"), role: .cancel) { }
        }
        .alert(L10n.text("相册"), isPresented: Binding(get: { photos.notice != nil }, set: { if !$0 { photos.notice = nil } })) {
            Button(L10n.text("知道了"), role: .cancel) { photos.notice = nil }
        } message: { Text(photos.notice ?? "") }
    }

    private func openLocation() {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([request.lease.originalURL])
        #else
        showingLocation = true
        #endif
    }

    private func savePhoto(explicitRetry: Bool = false) {
        photos.save(SavedFile(name: request.name, url: request.lease.url, size: request.size), explicitRetry: explicitRetry, holding: request.lease)
    }
}

#if os(iOS)
private struct NativeFilePreview: UIViewControllerRepresentable {
    let url: URL
    let name: String
    func makeCoordinator() -> Coordinator { Coordinator(url: url, name: name) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) { }
    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let item: Item
        init(url: URL, name: String) { item = Item(url: url, name: name) }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }
        nonisolated func previewController(_ controller: QLPreviewController, shouldOpen url: URL, for item: any QLPreviewItem) -> Bool { false }
    }
    final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?
        init(url: URL, name: String) { previewItemURL = url; previewItemTitle = name }
    }
}

/// iOS does not expose Finder's reveal API; use the supported system document-location sheet.
private struct FileLocationPicker: UIViewControllerRepresentable {
    let directory: URL
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(close: { dismiss() }) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.directoryURL = directory
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { close() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { close() }
    }
}
#else
private struct NativeFilePreview: NSViewRepresentable {
    let url: URL
    let name: String
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
#endif
