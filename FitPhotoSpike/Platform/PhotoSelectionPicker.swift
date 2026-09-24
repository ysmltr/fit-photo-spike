import PhotosUI
import SwiftUI

/// The system picker grants access only to the selected items. Constructing
/// this configuration without a photo library avoids requesting asset IDs.
struct PhotoSelectionPicker: UIViewControllerRepresentable {
    let onComplete: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = .images
        configuration.selectionLimit = 20
        configuration.selection = .ordered
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onComplete: ([PHPickerResult]) -> Void

        init(onComplete: @escaping ([PHPickerResult]) -> Void) {
            self.onComplete = onComplete
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // SwiftUI owns the sheet's presentation and dismissal. An empty
            // selection is cancellation, not a request to convert no images.
            onComplete(results)
        }
    }
}
