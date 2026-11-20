import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Apple's document picker, opened in copy mode so the chosen files land
/// straight in the app and Open always hands them back.
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType]
    var multiple: Bool
    var onPick: ([URL]) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types.isEmpty ? [.item] : types, asCopy: true)
        vc.allowsMultipleSelection = multiple
        vc.shouldShowFileExtensions = true
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        init(_ p: DocumentPicker) { parent = p }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Move the picker's temporary copies somewhere that lasts for this session.
            let kept = urls.compactMap { FileStore.importCopy($0) }
            parent.onPick(kept)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }
    }
}

extension View {
    func documentPicker(isPresented: Binding<Bool>, types: [UTType], multiple: Bool = false, onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            DocumentPicker(types: types, multiple: multiple, onPick: { urls in
                isPresented.wrappedValue = false
                onPick(urls)
            }, onCancel: { isPresented.wrappedValue = false })
            .ignoresSafeArea()
        }
    }
}
