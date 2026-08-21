//
//  SignatureCapture.swift
//  FieldForge
//
//  Fingertip signature capture that produces ink you would be happy to see on
//  a letter, not a jagged polyline.
//
//  Three things make the difference:
//
//    * Catmull-Rom smoothing through the sampled points, so a fast swipe is a
//      curve instead of a chain of straight segments.
//    * Width that varies with speed, which is what makes a stroke look like a
//      pen rather than a marker.
//    * A tight crop of the actual ink before it goes into the PDF, so the
//      signature sits on the baseline at a sensible size regardless of where
//      on the pad it was drawn.
//

import SwiftUI
import UIKit

/// One continuous stroke.
struct SignatureStroke: Identifiable, Equatable {
    let id = UUID()
    var points: [CGPoint] = []
    /// Per-point width, derived from drawing speed at sample time.
    var widths: [CGFloat] = []

    mutating func add(_ point: CGPoint, width: CGFloat) {
        points.append(point)
        widths.append(width)
    }
}

/// The drawn signature, independent of any view. Held by the capture view and
/// handed to `SignatureRasterizer` when the staffer taps Use.
@Observable
final class SignatureDrawing {
    var strokes: [SignatureStroke] = []
    private(set) var boundingBox: CGRect = .null

    var isEmpty: Bool {
        strokes.allSatisfy { $0.points.count < 2 }
    }

    /// Rejects a stray tap as a signature. A single dot is almost always the
    /// user's palm, and accepting it produces an empty-looking letter.
    var hasEnoughInk: Bool {
        let totalPoints = strokes.reduce(0) { $0 + $1.points.count }
        guard totalPoints >= 8 else { return false }
        return boundingBox.width > 24 || boundingBox.height > 12
    }

    func beginStroke(at point: CGPoint) {
        var stroke = SignatureStroke()
        stroke.add(point, width: Self.baseWidth)
        strokes.append(stroke)
        extendBounds(with: point)
    }

    func extendStroke(to point: CGPoint) {
        guard var stroke = strokes.popLast() else {
            beginStroke(at: point)
            return
        }
        // Drop samples that are essentially where we already are; they add
        // nothing and make the smoothing wobble.
        if let last = stroke.points.last, hypot(point.x - last.x, point.y - last.y) < 0.8 {
            strokes.append(stroke)
            return
        }
        let speed = stroke.points.last.map { hypot(point.x - $0.x, point.y - $0.y) } ?? 0
        stroke.add(point, width: Self.width(forSpeed: speed))
        strokes.append(stroke)
        extendBounds(with: point)
    }

    func endStroke() {
        // Discard a stroke that is a single point — a tap, not a mark.
        if let last = strokes.last, last.points.count < 2 {
            strokes.removeLast()
            recomputeBounds()
        }
    }

    func undoLastStroke() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        recomputeBounds()
    }

    func clear() {
        strokes.removeAll()
        boundingBox = .null
    }

    private func extendBounds(with point: CGPoint) {
        let dot = CGRect(x: point.x, y: point.y, width: 0.01, height: 0.01)
        boundingBox = boundingBox.isNull ? dot : boundingBox.union(dot)
    }

    private func recomputeBounds() {
        boundingBox = .null
        for stroke in strokes {
            for point in stroke.points { extendBounds(with: point) }
        }
    }

    // MARK: Pen dynamics

    static let baseWidth: CGFloat = 2.4

    /// Fast strokes are thin, slow strokes are thick — the same reason a
    /// fountain pen's line varies. Clamped so it never looks like a blob.
    static func width(forSpeed speed: CGFloat) -> CGFloat {
        let normalized = min(max(speed, 0), 28) / 28
        return baseWidth * (1.35 - 0.7 * normalized)
    }
}

/// Turns strokes into a `UIImage` with a transparent background.
enum SignatureRasterizer {

    /// - Parameters:
    ///   - drawing: the captured strokes, in the coordinate space of `canvasSize`.
    ///   - canvasSize: the size of the view the signature was drawn in.
    ///   - scale: output scale. 3× keeps the ink crisp when the PDF is printed
    ///     or zoomed; a signature is the one part of the page a donor squints at.
    static func image(
        from drawing: SignatureDrawing,
        canvasSize: CGSize,
        scale: CGFloat = 3,
        inkColor: UIColor = UIColor(red: 0.06, green: 0.09, blue: 0.22, alpha: 1),
        cropPadding: CGFloat = 6
    ) -> UIImage? {
        guard !drawing.isEmpty, canvasSize.width > 0, canvasSize.height > 0 else { return nil }

        // Crop to the ink, padded, and clamped to the canvas.
        let inkBounds = drawing.boundingBox.isNull
            ? CGRect(origin: .zero, size: canvasSize)
            : drawing.boundingBox.insetBy(dx: -cropPadding, dy: -cropPadding)
                .intersection(CGRect(origin: .zero, size: canvasSize))
        guard !inkBounds.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: inkBounds.size, format: format)

        return renderer.image { rendererContext in
            let cg = rendererContext.cgContext
            cg.translateBy(x: -inkBounds.minX, y: -inkBounds.minY)
            cg.setStrokeColor(inkColor.cgColor)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)

            for stroke in drawing.strokes {
                draw(stroke: stroke, in: cg)
            }
        }
    }

    /// Draws one stroke as a series of short, smoothed, variable-width
    /// segments. Varying width means we cannot use a single path — each
    /// segment is stroked at its own width.
    private static func draw(stroke: SignatureStroke, in cg: CGContext) {
        let points = stroke.points
        guard points.count > 1 else {
            if let single = points.first {
                cg.setLineWidth(SignatureDrawing.baseWidth)
                cg.move(to: single)
                cg.addLine(to: single)
                cg.strokePath()
            }
            return
        }

        for index in 0..<(points.count - 1) {
            let start = points[index]
            let end = points[index + 1]
            // Catmull-Rom control points, clamped at the ends.
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 2)]

            let control1 = CGPoint(
                x: start.x + (end.x - previous.x) / 6,
                y: start.y + (end.y - previous.y) / 6
            )
            let control2 = CGPoint(
                x: end.x - (next.x - start.x) / 6,
                y: end.y - (next.y - start.y) / 6
            )

            let width = stroke.widths.indices.contains(index + 1)
                ? (stroke.widths[index] + stroke.widths[index + 1]) / 2
                : SignatureDrawing.baseWidth

            cg.setLineWidth(max(0.6, width))
            cg.move(to: start)
            cg.addCurve(to: end, control1: control1, control2: control2)
            cg.strokePath()
        }
    }

    /// PNG for storage. PNG rather than JPEG because the signature needs a
    /// transparent background to sit over the letter's baseline rule.
    static func pngData(
        from drawing: SignatureDrawing,
        canvasSize: CGSize
    ) -> Data? {
        image(from: drawing, canvasSize: canvasSize)?.pngData()
    }
}
