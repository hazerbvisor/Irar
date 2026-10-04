// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UIKit

/// System Files export accepts files/directories without materializing their
/// contents in a SwiftUI FileDocument or copying them into RAM.
struct ExportPicker: UIViewControllerRepresentable {
    let urls: [URL]
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator(finish: { dismiss() }) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let finish: () -> Void
        init(finish: @escaping () -> Void) { self.finish = finish }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish() }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish() }
    }
}
