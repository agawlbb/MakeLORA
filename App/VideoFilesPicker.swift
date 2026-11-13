import SwiftUI
import UniformTypeIdentifiers

/// Select references, then dismiss before starting any provider downloads or app work.
struct VideoFilesPicker: UIViewControllerRepresentable {
    let onSelection: ([URL]) -> Void
    let onCancel: () -> Void

    static func controller() -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.movie, .plainText], asCopy: false)
        picker.allowsMultipleSelection = true
        return picker
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = Self.controller()
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
        context.coordinator.parent = self
    }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var parent: VideoFilesPicker
        init(_ parent: VideoFilesPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { parent.onSelection(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.onCancel() }
    }
}

/// Retain access while the picker dismisses and the app stages its own copies.
final class VideoFileSelection {
    let urls: [URL]
    private let scoped: [URL]
    init(urls: [URL]) {
        self.urls = urls
        scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
}
