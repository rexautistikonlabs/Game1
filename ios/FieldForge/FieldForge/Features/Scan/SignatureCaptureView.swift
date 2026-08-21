//
//  SignatureCaptureView.swift
//  FieldForge
//
//  The signature pad.
//
//  Two details that matter more than they sound:
//
//    * Landscape hint. A signature drawn in a wide box looks like a signature;
//      one squeezed into a portrait square looks like a scrawl. The pad uses the
//      full width and suggests turning the phone.
//    * A baseline. People sign *on* a line. Drawing one makes the result
//      markedly better, and it costs one rectangle.
//

import SwiftUI

struct SignatureCaptureView: View {

    /// Called with PNG data. Nil is never passed — cancelling just dismisses.
    let onCapture: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var drawing = SignatureDrawing()
    @State private var canvasSize: CGSize = .zero
    @State private var showsTooLittleInkWarning = false
    /// True between the first and last touch event of one stroke.
    @State private var isStrokeInProgress = false

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.md) {
                Text("Sign inside the box")
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)

                canvas

                if showsTooLittleInkWarning {
                    InlineBanner(
                        kind: .caution,
                        message: "That looks like a stray tap rather than a signature. Try again — it does not have to be neat."
                    )
                }

                HStack(spacing: Space.sm) {
                    Button {
                        Haptics.selection()
                        drawing.undoLastStroke()
                        showsTooLittleInkWarning = false
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Space.minimumTarget)
                    }
                    .buttonStyle(.bordered)
                    .disabled(drawing.strokes.isEmpty)

                    Button {
                        Haptics.selection()
                        drawing.clear()
                        showsTooLittleInkWarning = false
                    } label: {
                        Label("Clear", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            .frame(minHeight: Space.minimumTarget)
                    }
                    .buttonStyle(.bordered)
                    .disabled(drawing.strokes.isEmpty)
                }

                Spacer(minLength: 0)

                PrimaryButton(
                    title: "Use this signature",
                    systemImage: "checkmark",
                    isEnabled: !drawing.isEmpty
                ) {
                    capture()
                }
            }
            .padding(Space.screenEdge)
            .background(Palette.background)
            .navigationTitle("Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { proxy in
            ZStack {
                RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                    .fill(Palette.surface)
                RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                    .strokeBorder(Palette.separator, lineWidth: 1)

                // The baseline. People sign on a line, so give them one.
                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 1)
                    .padding(.horizontal, Space.lg)
                    .offset(y: proxy.size.height * 0.22)

                if drawing.isEmpty {
                    Text("Sign here")
                        .font(Type.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .offset(y: proxy.size.height * 0.30)
                        .allowsHitTesting(false)
                }

                // `Canvas` rather than a stack of Paths: it redraws in one pass
                // and keeps a fast scribble smooth instead of dropping points.
                Canvas { graphicsContext, _ in
                    for stroke in drawing.strokes {
                        draw(stroke: stroke, in: graphicsContext)
                    }
                }
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                // `minimumDistance: 0` so a deliberate dot or a very short mark
                // still registers. `DragGesture` has no "began" phase, so the
                // first `onChanged` of each touch starts the stroke.
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isStrokeInProgress {
                            isStrokeInProgress = true
                            drawing.beginStroke(at: value.startLocation)
                        }
                        drawing.extendStroke(to: value.location)
                        showsTooLittleInkWarning = false
                    }
                    .onEnded { _ in
                        isStrokeInProgress = false
                        drawing.endStroke()
                    }
            )
            .onAppear { canvasSize = proxy.size }
            .onChange(of: proxy.size) { _, size in canvasSize = size }
        }
        .frame(height: 220)
        .accessibilityElement()
        .accessibilityLabel("Signature pad")
        .accessibilityValue(drawing.isEmpty ? "Empty" : "Signed")
        .accessibilityHint("Draw your signature with one finger")
    }

    private func draw(stroke: SignatureStroke, in graphicsContext: GraphicsContext) {
        guard stroke.points.count > 1 else { return }
        for index in 0..<(stroke.points.count - 1) {
            let start = stroke.points[index]
            let end = stroke.points[index + 1]
            let previous = stroke.points[max(0, index - 1)]
            let next = stroke.points[min(stroke.points.count - 1, index + 2)]

            var path = Path()
            path.move(to: start)
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + (end.x - previous.x) / 6, y: start.y + (end.y - previous.y) / 6),
                control2: CGPoint(x: end.x - (next.x - start.x) / 6, y: end.y - (next.y - start.y) / 6)
            )

            let width = stroke.widths.indices.contains(index + 1)
                ? (stroke.widths[index] + stroke.widths[index + 1]) / 2
                : SignatureDrawing.baseWidth

            graphicsContext.stroke(
                path,
                with: .color(Palette.textPrimary),
                style: StrokeStyle(lineWidth: max(0.8, width), lineCap: .round, lineJoin: .round)
            )
        }
    }

    // MARK: Capture

    private func capture() {
        guard drawing.hasEnoughInk else {
            showsTooLittleInkWarning = true
            Haptics.warning()
            return
        }
        guard let data = SignatureRasterizer.pngData(from: drawing, canvasSize: canvasSize) else {
            showsTooLittleInkWarning = true
            return
        }
        Haptics.success()
        onCapture(data)
        dismiss()
    }
}

#Preview("Signature") {
    SignatureCaptureView { _ in }
}
