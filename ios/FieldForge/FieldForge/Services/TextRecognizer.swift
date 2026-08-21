//
//  TextRecognizer.swift
//  FieldForge
//
//  Reading a business sign, an awning, or a business card with the camera and
//  turning it into a contact record.
//
//  Entirely on-device, via Vision. That is not a privacy footnote — it is the
//  reason this works at all. A staffer photographing a shop front in a basement
//  with no signal still gets the name and the address filled in.
//

import Foundation
import UIKit
import Vision

/// One recognised piece of text, with where it was and how confident Vision is.
struct RecognizedTextBlock {
    var text: String
    var confidence: Float
    /// Normalised bounding box, origin bottom-left, as Vision reports it.
    var boundingBox: CGRect

    /// Rough type-size proxy. On a shop sign the business name is the biggest
    /// text in the frame, which is a remarkably reliable signal.
    var relativeHeight: CGFloat { boundingBox.height }
}

enum TextRecognizer {

    enum RecognitionError: LocalizedError {
        case noImageData
        case visionFailed(String)
        case nothingFound

        var errorDescription: String? {
            switch self {
            case .noImageData: return "That photo could not be read."
            case .visionFailed(let detail): return "Text recognition failed: \(detail)"
            case .nothingFound: return "No text found. Try getting closer, or type it in."
            }
        }
    }

    /// Recognises text in an image.
    ///
    /// - Parameter fast: `true` uses the quicker, less accurate path. Used for
    ///   the live viewfinder hint; the captured still always uses `.accurate`.
    static func recognize(in image: UIImage, fast: Bool = false) async throws -> [RecognizedTextBlock] {
        guard let cgImage = image.cgImage else { throw RecognitionError.noImageData }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: RecognitionError.visionFailed(error.localizedDescription))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let blocks: [RecognizedTextBlock] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedTextBlock(
                        text: candidate.string,
                        confidence: candidate.confidence,
                        boundingBox: observation.boundingBox
                    )
                }
                continuation.resume(returning: blocks)
            }

            request.recognitionLevel = fast ? .fast : .accurate
            // Language correction fixes "Hardvvare" but occasionally mangles a
            // surname, so it is on for signs and handled leniently downstream.
            request.usesLanguageCorrection = true
            // Recognise in the languages the staffer actually reads, but only
            // those Vision supports on this OS — passing an unsupported
            // identifier makes `perform` throw, and a crash-free "no text
            // found" is not an acceptable failure mode at a doorstep.
            let preferred = Locale.preferredLanguages.map { String($0.prefix(2)) }
            let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(
                for: request.recognitionLevel,
                revision: VNRecognizeTextRequestRevision3
            )) ?? []
            let usable = preferred.filter { language in
                supported.contains { $0.hasPrefix(language) }
            }
            if !usable.isEmpty {
                request.recognitionLanguages = usable
            }

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: image.cgImagePropertyOrientation,
                options: [:]
            )
            // Vision is synchronous and slow enough to matter; keep it off the
            // main thread so the shutter animation does not stutter.
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: RecognitionError.visionFailed(error.localizedDescription))
                }
            }
        }
    }
}

extension UIImage {
    /// Vision needs the CGImage orientation, which `UIImage.imageOrientation`
    /// is not. Getting this wrong means sideways text and no matches.
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch imageOrientation {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
