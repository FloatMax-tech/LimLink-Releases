import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The system folder picker, used once to authorize Files › Downloads for received files.
struct FolderPicker: UIViewControllerRepresentable {
    let pick: (URL) -> Void
    let cancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(pick: pick, cancel: cancel) }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let pick: (URL) -> Void
        let cancel: () -> Void

        init(pick: @escaping (URL) -> Void, cancel: @escaping () -> Void) {
            self.pick = pick
            self.cancel = cancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { pick(url) } else { cancel() }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { cancel() }
    }
}
