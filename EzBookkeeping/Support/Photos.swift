import ImageIO
import SwiftUI
import UIKit

/// Shrinks photos before they are uploaded, as the Android app does (at most 2048 pixels, JPEG).
enum PhotoProcessing {
    static let maxSize = 2048
    static let thumbnailSize = 320

    /// The photo to upload and a small preview of it, or nil when the data isn't an image.
    static func prepare(_ data: Data) -> (jpeg: Data, thumbnail: Data?)? {
        guard let large = shrink(data, maxPixels: maxSize), let jpeg = large.jpegData(compressionQuality: 0.85) else {
            return nil
        }

        return (jpeg, thumbnail(data))
    }

    static func prepare(_ image: UIImage) -> (jpeg: Data, thumbnail: Data?)? {
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            return nil
        }

        return prepare(data)
    }

    static func thumbnail(_ data: Data) -> Data? {
        shrink(data, maxPixels: thumbnailSize)?.jpegData(compressionQuality: 0.8)
    }

    /// Decodes at most maxPixels on the long side, turned the way the camera held it.
    private static func shrink(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        return UIImage(cgImage: image)
    }
}

/// The camera, for photographing a receipt.
struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }

            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
