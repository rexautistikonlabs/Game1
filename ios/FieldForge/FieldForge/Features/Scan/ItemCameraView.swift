//
//  ItemCameraView.swift
//  FieldForge
//
//  A plain camera, for photographing donated goods.
//
//  `UIImagePickerController` rather than a hand-rolled `AVCaptureSession`, and
//  that is a deliberate choice rather than laziness: it gives the system camera
//  UI with a retake step, flash control, and pinch zoom for free, all of which a
//  bespoke capture view would have to reimplement badly. It is also the control
//  a volunteer already knows. `AVCaptureSession` would only be worth it for a
//  custom viewfinder overlay, and photographing a pallet of tinned peaches does
//  not need one.
//
//  Downscaling happens here rather than at the point of use, because these
//  photographs end up in a PDF and in a CloudKit asset, and a 12-megapixel
//  original in both is a real cost to somebody on a metered plan.
//

import AVFoundation
import SwiftUI
import UIKit

struct ItemCameraView: UIViewControllerRepresentable {

    /// Called with JPEG data, already downscaled. Nil is never passed —
    /// cancelling simply dismisses.
    let onCapture: (Data) -> Void

    /// Longest edge of the stored image, in pixels. 1600 is plenty to show a
    /// pallet of goods clearly at PDF print size while staying well under a
    /// megabyte, which matters when it syncs.
    var maximumDimension: CGFloat = 1600
    var compressionQuality: CGFloat = 0.75

    @Environment(\.dismiss) private var dismiss

    /// Whether a camera exists at all. False on the simulator, which is worth
    /// knowing before presenting an empty black sheet.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    static var isPermissionDenied: Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        return status == .denied || status == .restricted
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            maximumDimension: maximumDimension,
            compressionQuality: compressionQuality,
            onCapture: onCapture,
            onFinish: { dismiss() }
        )
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {

        private let maximumDimension: CGFloat
        private let compressionQuality: CGFloat
        private let onCapture: (Data) -> Void
        private let onFinish: () -> Void

        init(
            maximumDimension: CGFloat,
            compressionQuality: CGFloat,
            onCapture: @escaping (Data) -> Void,
            onFinish: @escaping () -> Void
        ) {
            self.maximumDimension = maximumDimension
            self.compressionQuality = compressionQuality
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            defer { onFinish() }
            guard let original = info[.originalImage] as? UIImage else { return }
            guard let data = Self.downscaledJPEG(
                original,
                maximumDimension: maximumDimension,
                quality: compressionQuality
            ) else { return }
            onCapture(data)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }

        /// Downscales and re-encodes.
        ///
        /// Also normalises orientation: a camera image carries its rotation in
        /// EXIF, and drawing it into a fresh context bakes that in. Without this
        /// step a photo taken in portrait appears on its side in the PDF, which
        /// is the classic version of this bug.
        static func downscaledJPEG(
            _ image: UIImage,
            maximumDimension: CGFloat,
            quality: CGFloat
        ) -> Data? {
            let longestEdge = max(image.size.width, image.size.height)
            let scale = longestEdge > maximumDimension ? maximumDimension / longestEdge : 1
            let targetSize = CGSize(
                width: (image.size.width * scale).rounded(),
                height: (image.size.height * scale).rounded()
            )

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            format.opaque = true
            let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: targetSize))
            }
            return rendered.jpegData(compressionQuality: quality)
        }
    }
}
