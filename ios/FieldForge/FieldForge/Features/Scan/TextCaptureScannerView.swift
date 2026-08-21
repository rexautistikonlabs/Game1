//
//  TextCaptureScannerView.swift
//  FieldForge
//
//  Point the camera at a shop sign or a business card and get a contact.
//
//  Uses VisionKit's `DataScannerViewController` where it is supported, because
//  live recognition with an on-screen highlight is a far better experience than
//  take-a-photo-and-wait: the staffer sees the app reading the sign and knows it
//  worked before they lower the phone.
//
//  Falls back to a single photo plus a Vision pass on older or unsupported
//  devices, and to the photo library if the camera is refused. All three paths
//  are fully offline.
//

import AVFoundation
import PhotosUI
import SwiftUI
import UIKit
import VisionKit

struct TextCaptureScannerView: View {

    enum Mode: String, Identifiable {
        case sign
        case businessCard

        var id: String { rawValue }

        var title: String {
            switch self {
            case .sign: return "Scan the sign"
            case .businessCard: return "Scan the card"
            }
        }

        var guidance: String {
            switch self {
            case .sign: return "Fill the frame with the business name. Getting closer beats zooming."
            case .businessCard: return "Lay the card flat and hold the phone parallel to it."
            }
        }

        var source: ContactSource {
            switch self {
            case .sign: return .signOCR
            case .businessCard: return .businessCard
            }
        }
    }

    let mode: Mode
    /// Hands back the parsed fields and, when it could be grabbed, the frame
    /// they were read from. A photo of the storefront outlives the OCR guess it
    /// produced, so it is worth keeping even when the parse was perfect.
    let onCapture: (ParsedContactCandidate, Data?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var liveBlocks: [RecognizedTextBlock] = []
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var pickedItem: PhotosPickerItem?
    @State private var cameraDenied = false
    /// Set by the live scanner so `finish` can grab a still on confirm.
    @State private var frameProvider: (() async -> Data?)?
    @State private var capturedFrame: Data?
    /// Set when the live scanner has produced nothing for a while, so the
    /// screen can suggest something rather than showing a viewfinder that
    /// looks broken.
    @State private var hasStruggled = false
    @State private var scannerFailed = false

    /// `DataScanner` needs a device with the Neural Engine and camera
    /// permission; `isAvailable` covers the permission half.
    private var canUseLiveScanner: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if canUseLiveScanner {
                    LiveTextScanner(
                        recognizesMultipleItems: true,
                        onRecognize: { blocks in
                            liveBlocks = blocks
                        },
                        onReady: { provider in
                            frameProvider = provider
                        },
                        onUnavailable: {
                            scannerFailed = true
                        }
                    )
                    .ignoresSafeArea()
                } else {
                    fallbackView
                }

                VStack {
                    Spacer()
                    guidanceCard
                }
                .padding(Space.screenEdge)
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    PhotosPicker(selection: $pickedItem, matching: .images) {
                        Image(systemName: "photo.on.rectangle")
                    }
                    .accessibilityLabel("Choose a photo instead")
                }
            }
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task { await recognizeFromLibrary(item) }
            }
            .onChange(of: liveBlocks.isEmpty) { _, isEmpty in
                // Any successful read clears the hint; it should not linger
                // once the scanner is clearly working.
                if !isEmpty { hasStruggled = false }
            }
            .task {
                // Six seconds of nothing is long enough to be a problem and
                // short enough that the advice still feels responsive.
                try? await Task.sleep(for: .seconds(6))
                if liveBlocks.isEmpty { hasStruggled = true }
            }
        }
    }

    // MARK: Guidance and confirm

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if let errorMessage {
                InlineBanner(kind: .caution, message: errorMessage)
            }

            if scannerFailed {
                InlineBanner(
                    kind: .caution,
                    message: "The camera stopped. Close this and try again, or choose a photo instead."
                )
            } else if hasStruggled, liveBlocks.isEmpty {
                // The single most useful thing to say when a scan is not
                // catching: the fix is almost always distance or glare, and
                // neither is obvious from an empty viewfinder.
                InlineBanner(
                    kind: .info,
                    message: mode == .sign
                        ? "Not catching it. Get closer so the name fills the frame, and try an angle that avoids glare."
                        : "Not catching it. Lay the card on a flat surface in even light, parallel to the phone."
                )
            }

            if let preview = livePreviewName {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reading")
                        .font(Type.label)
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textSecondary)
                    Text(preview)
                        .font(Type.section)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(mode.guidance)
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            PrimaryButton(
                title: "Use this",
                systemImage: "checkmark",
                isLoading: isProcessing,
                isEnabled: !liveBlocks.isEmpty
            ) {
                Task { await confirm(blocks: liveBlocks) }
            }
        }
        .padding(Space.md)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
    }

    /// The name we would extract right now, shown live so the staffer can adjust
    /// the framing instead of discovering a bad read afterwards.
    private var livePreviewName: String? {
        guard !liveBlocks.isEmpty else { return nil }
        let candidate = mode == .sign
            ? ContactParser.parseSign(liveBlocks)
            : ContactParser.parseBusinessCard(liveBlocks)
        return candidate.name.trimmedOrNil ?? candidate.personName.trimmedOrNil
    }

    // MARK: Fallback

    private var fallbackView: some View {
        VStack(spacing: Space.lg) {
            Spacer()
            EmptyStateView(
                symbol: cameraDenied ? "camera.badge.ellipsis" : "photo.badge.plus",
                title: cameraDenied ? "Camera access is off" : "Live scanning is not available here",
                message: cameraDenied
                    ? "Turn the camera on for FieldForge in Settings, or choose a photo you have already taken."
                    : "This iPhone cannot scan live, but a photo works just as well.",
                actionTitle: "Choose a photo"
            ) {}
            Spacer()
        }
        .task {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            cameraDenied = status == .denied || status == .restricted
        }
    }

    // MARK: Recognition

    private func recognizeFromLibrary(_ item: PhotosPickerItem) async {
        isProcessing = true
        errorMessage = nil
        defer { isProcessing = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                errorMessage = "That photo could not be opened."
                return
            }
            let blocks = try await TextRecognizer.recognize(in: image)
            guard !blocks.isEmpty else {
                errorMessage = "No text found in that photo. Try one taken closer in."
                return
            }
            finish(with: blocks, frame: image.jpegData(compressionQuality: 0.7))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Grabs a still, then hands everything back. The still is best-effort: a
    /// failed capture must never cost the staffer the parse.
    private func confirm(blocks: [RecognizedTextBlock]) async {
        guard !blocks.isEmpty else { return }
        isProcessing = true
        let frame = capturedFrame ?? (await frameProvider?())
        isProcessing = false
        finish(with: blocks, frame: frame)
    }

    private func finish(with blocks: [RecognizedTextBlock], frame: Data?) {
        guard !blocks.isEmpty else { return }
        let candidate = mode == .sign
            ? ContactParser.parseSign(blocks)
            : ContactParser.parseBusinessCard(blocks)
        Haptics.success()
        onCapture(candidate, frame)
        dismiss()
    }
}

// MARK: - VisionKit bridge

/// `DataScannerViewController` wrapped for SwiftUI.
///
/// The delegate reports items as they appear, disappear, and update. We keep a
/// dictionary keyed by the scanner's own item IDs rather than replacing the
/// whole set each time, because text flickers in and out as the phone moves and
/// a naive replace makes the live preview unreadable.
struct LiveTextScanner: UIViewControllerRepresentable {

    var recognizesMultipleItems: Bool = true
    var onRecognize: ([RecognizedTextBlock]) -> Void
    /// Called once the scanner exists, handing back a closure that grabs a
    /// still frame. Keeps `DataScannerViewController` out of the SwiftUI view.
    var onReady: ((@escaping () async -> Data?) -> Void)?
    /// Called if the scanner becomes unavailable mid-session — camera taken by
    /// another app, thermal shutdown, permission revoked in Settings.
    var onUnavailable: (() -> Void)?

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.text()],
            qualityLevel: .balanced,
            recognizesMultipleItems: recognizesMultipleItems,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        onReady?({ @MainActor in
            // `capturePhoto()` returns the current viewfinder frame at full
            // resolution. JPEG at 0.7 keeps a storefront photo well under a
            // megabyte, which matters when it syncs.
            guard let image = try? await scanner.capturePhoto() else { return nil }
            return image.jpegData(compressionQuality: 0.7)
        })
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            // A silent failure here is a black viewfinder with no explanation,
            // which is the worst possible outcome at a doorstep.
            AppLog.capture.error("Could not start scanning: \(error.localizedDescription, privacy: .public)")
            onUnavailable?()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        // Leaving the camera running behind a dismissed sheet is a battery bug
        // and a privacy indicator that never goes away.
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onRecognize: onRecognize, onUnavailable: onUnavailable)
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {

        private let onRecognize: ([RecognizedTextBlock]) -> Void
        private let onUnavailable: (() -> Void)?
        private var items: [UUID: RecognizedTextBlock] = [:]

        init(
            onRecognize: @escaping ([RecognizedTextBlock]) -> Void,
            onUnavailable: (() -> Void)? = nil
        ) {
            self.onRecognize = onRecognize
            self.onUnavailable = onUnavailable
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            update(with: allItems, in: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didUpdate updatedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            update(with: allItems, in: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didRemove removedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            update(with: allItems, in: dataScanner)
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            AppLog.capture.error("Live scanning became unavailable: \(String(describing: error), privacy: .public)")
            onRecognize([])
            onUnavailable?()
        }

        private func update(with allItems: [RecognizedItem], in scanner: DataScannerViewController) {
            items.removeAll(keepingCapacity: true)
            let viewSize = scanner.view.bounds.size

            for item in allItems {
                guard case .text(let text) = item else { continue }
                // The scanner reports a quadrilateral in view coordinates.
                // Convert to a normalised, bottom-left-origin box so the parser
                // sees the same geometry Vision would give it — the "biggest
                // text is the business name" heuristic depends on it.
                let bounds = item.bounds
                let minX = min(bounds.topLeft.x, bounds.bottomLeft.x)
                let maxX = max(bounds.topRight.x, bounds.bottomRight.x)
                let minY = min(bounds.topLeft.y, bounds.topRight.y)
                let maxY = max(bounds.bottomLeft.y, bounds.bottomRight.y)

                guard viewSize.width > 0, viewSize.height > 0 else { continue }
                let normalized = CGRect(
                    x: minX / viewSize.width,
                    y: 1 - (maxY / viewSize.height),
                    width: (maxX - minX) / viewSize.width,
                    height: (maxY - minY) / viewSize.height
                )

                items[item.id] = RecognizedTextBlock(
                    text: text.transcript,
                    // The live scanner does not expose a confidence, and its
                    // transcripts are already filtered, so treat them as good.
                    confidence: 0.9,
                    boundingBox: normalized
                )
            }
            onRecognize(Array(items.values))
        }
    }
}
