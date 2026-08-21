//
//  PDFLayout.swift
//  FieldForge
//
//  A small, honest page-layout engine on top of Core Text and
//  UIGraphicsPDFRenderer.
//
//  Why not just render a SwiftUI view with ImageRenderer? Because a receipt
//  is not a screenshot. A donor acknowledgment has to paginate properly, keep
//  its signature block off an orphaned page, select as real text so an
//  accountant can copy the amount out of it, and print at the right physical
//  size on both US Letter and A4. Core Text does all of that; a rasterised
//  view does none of it.
//
//  Everything here is synchronous and side-effect free apart from drawing, so
//  the two renderers on top of it read like documents rather than like code.
//

import CoreText
import Foundation
import UIKit

// MARK: - Page geometry

/// Physical page size, in PostScript points (1/72").
enum PageSize {
    case usLetter
    case a4

    var size: CGSize {
        switch self {
        case .usLetter: return CGSize(width: 612, height: 792)   // 8.5" x 11"
        case .a4: return CGSize(width: 595.28, height: 841.89)   // 210mm x 297mm
        }
    }

    /// US Letter in the US and Canada, A4 everywhere else. A nonprofit in
    /// Manchester should not get a letter that prints with a strip cut off.
    static var forCurrentLocale: PageSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "PR", "SV", "VE"]
        let region = Locale.current.region?.identifier ?? "US"
        return letterRegions.contains(region) ? .usLetter : .a4
    }
}

// MARK: - Text styling

/// A named text style. Deliberately a value type with no dependency on the
/// canvas, so the two document templates can define their own type scales.
struct TextStyle {
    var font: UIFont
    var color: UIColor = .black
    var alignment: NSTextAlignment = .natural
    var lineHeightMultiple: CGFloat = 1.15
    var paragraphSpacing: CGFloat = 0
    var kerning: CGFloat = 0
    /// Upper-cased small label styling, used for field captions on the receipt.
    var isUppercased: Bool = false

    func attributes() -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineHeightMultiple = lineHeightMultiple
        paragraph.paragraphSpacing = paragraphSpacing
        // Without this, a long unbroken token (a URL in a footer, say) pushes
        // past the margin instead of wrapping.
        paragraph.lineBreakMode = .byWordWrapping
        return [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
            .kern: kerning,
        ]
    }

    func attributed(_ text: String) -> NSAttributedString {
        NSAttributedString(
            string: isUppercased ? text.uppercased() : text,
            attributes: attributes()
        )
    }

    // MARK: Fonts

    /// The letter body uses a serif, because a formal acknowledgment printed in
    /// the system sans reads like a push notification. `.serif` here is New
    /// York, which ships with the OS and needs no font licence.
    static func serif(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func sans(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.systemFont(ofSize: size, weight: weight)
    }

    /// Tabular figures, so a column of amounts lines up on the decimal point.
    static func monospacedDigits(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
    }
}

// MARK: - The canvas

/// A paginating drawing surface for one PDF document.
///
/// Usage is deliberately imperative and top-to-bottom: the caller draws
/// blocks in reading order and the canvas handles cursor advance, page breaks,
/// and running headers and footers.
final class PDFCanvas {

    /// Page margins. Letters use wider side margins than receipts.
    struct Margins {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat

        static let letter = Margins(top: 60, left: 72, bottom: 64, right: 72)
        static let receipt = Margins(top: 48, left: 52, bottom: 56, right: 52)
    }

    let pageSize: CGSize
    let margins: Margins

    /// Drawn at the top of every page after the first. Returns the height it
    /// consumed. Nil for documents that only need a first-page letterhead.
    var runningHeader: ((PDFCanvas, Int) -> CGFloat)?

    /// Drawn at the bottom of every page. Receives the page index and the total
    /// page count, which is why rendering happens in two passes.
    var runningFooter: ((PDFCanvas, Int, Int) -> Void)?

    private let context: UIGraphicsPDFRendererContext
    private(set) var pageIndex: Int = -1
    private(set) var cursorY: CGFloat = 0

    /// Set on the second pass so footers can print "Page 1 of 2".
    var knownTotalPages: Int = 0

    init(
        context: UIGraphicsPDFRendererContext,
        pageSize: CGSize,
        margins: Margins
    ) {
        self.context = context
        self.pageSize = pageSize
        self.margins = margins
    }

    var cgContext: CGContext { context.cgContext }

    /// The drawable area on a page.
    var contentRect: CGRect {
        CGRect(
            x: margins.left,
            y: margins.top,
            width: pageSize.width - margins.left - margins.right,
            height: pageSize.height - margins.top - margins.bottom
        )
    }

    var contentWidth: CGFloat { contentRect.width }

    /// Vertical room left on the current page.
    var remainingHeight: CGFloat {
        max(0, contentRect.maxY - cursorY)
    }

    var isAtTopOfPage: Bool {
        abs(cursorY - contentRect.minY) < 0.5
    }

    // MARK: Pages

    /// Starts a new page and resets the cursor below the running header.
    @discardableResult
    func beginPage() -> Int {
        finishPageFooter()
        context.beginPage()
        pageIndex += 1
        cursorY = contentRect.minY
        if pageIndex > 0, let runningHeader {
            let consumed = runningHeader(self, pageIndex)
            cursorY += consumed
        }
        return pageIndex
    }

    /// Ensures `height` points are available, breaking the page if not.
    ///
    /// Use this to keep a block together — a signature block split across two
    /// pages looks like a mistake, because it is one.
    func reserve(_ height: CGFloat) {
        guard pageIndex >= 0 else {
            beginPage()
            return
        }
        if height > remainingHeight, !isAtTopOfPage {
            beginPage()
        }
    }

    /// Called once, after all content, to stamp the last page's footer.
    func finish(totalPages: Int) {
        knownTotalPages = totalPages
        finishPageFooter()
    }

    private func finishPageFooter() {
        guard pageIndex >= 0, let runningFooter else { return }
        runningFooter(self, pageIndex, max(knownTotalPages, pageIndex + 1))
    }

    /// Number of pages drawn so far, 1-based.
    var pageCount: Int { pageIndex + 1 }

    // MARK: Vertical rhythm

    func advance(_ points: CGFloat) {
        cursorY += points
    }

    /// Moves the cursor to an absolute y, used for footers and for pinning a
    /// block to the bottom of a page.
    func moveCursor(to y: CGFloat) {
        cursorY = y
    }

    // MARK: Text

    /// Measures a block of text at a given width without drawing it.
    func measure(_ text: NSAttributedString, width: CGFloat? = nil) -> CGSize {
        guard text.length > 0 else { return .zero }
        let constraintWidth = width ?? contentWidth
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let constraints = CGSize(width: constraintWidth, height: .greatestFiniteMagnitude)
        var fitRange = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, 0),
            nil,
            constraints,
            &fitRange
        )
        // Core Text rounds down; the extra point avoids a clipped descender on
        // the last line, which is very visible on a printed page.
        return CGSize(width: ceil(size.width), height: ceil(size.height) + 1)
    }

    /// Draws text, flowing it across as many pages as it needs.
    ///
    /// Returns the y position immediately below the last line drawn.
    @discardableResult
    func drawText(
        _ text: NSAttributedString,
        x: CGFloat? = nil,
        width: CGFloat? = nil,
        spacingAfter: CGFloat = 0
    ) -> CGFloat {
        guard text.length > 0 else { return cursorY }
        if pageIndex < 0 { beginPage() }

        let originX = x ?? contentRect.minX
        let blockWidth = width ?? (contentRect.maxX - originX)
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        var drawnCharacters = 0

        while drawnCharacters < text.length {
            // A page with less than one line of room left is not worth using.
            if remainingHeight < 14, !isAtTopOfPage {
                beginPage()
            }
            let available = CGSize(width: blockWidth, height: remainingHeight)
            let rect = CGRect(
                x: originX,
                y: cursorY,
                width: available.width,
                height: available.height
            )
            let consumed = drawFrame(
                framesetter,
                startingAt: drawnCharacters,
                in: rect
            )
            if consumed <= 0 {
                // Nothing fit on this page. If we are already at the top of a
                // fresh page the text can never fit — bail rather than loop.
                if isAtTopOfPage { break }
                beginPage()
                continue
            }
            drawnCharacters += consumed

            let subrange = NSRange(location: drawnCharacters - consumed, length: consumed)
            let drawnHeight = measure(text.attributedSubstring(from: subrange), width: blockWidth).height
            cursorY += min(drawnHeight, available.height)

            if drawnCharacters < text.length {
                beginPage()
            }
        }

        cursorY += spacingAfter
        return cursorY
    }

    /// Convenience for a styled string.
    @discardableResult
    func drawText(
        _ string: String,
        style: TextStyle,
        x: CGFloat? = nil,
        width: CGFloat? = nil,
        spacingAfter: CGFloat = 0
    ) -> CGFloat {
        drawText(style.attributed(string), x: x, width: width, spacingAfter: spacingAfter)
    }

    /// Draws one line of text without paginating, at an absolute rect. Used for
    /// footers, table cells, and anything positioned rather than flowed.
    func drawLine(
        _ text: NSAttributedString,
        in rect: CGRect
    ) {
        guard text.length > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        _ = drawFrame(framesetter, startingAt: 0, in: rect)
    }

    func drawLine(_ string: String, style: TextStyle, in rect: CGRect) {
        drawLine(style.attributed(string), in: rect)
    }

    /// Core Text draws bottom-up; UIGraphicsPDFRenderer hands us a top-down
    /// UIKit context. This is the one place that reconciles the two.
    ///
    /// - Returns: the number of characters that fit in `rect`.
    private func drawFrame(
        _ framesetter: CTFramesetter,
        startingAt index: Int,
        in rect: CGRect
    ) -> Int {
        guard rect.height > 1, rect.width > 1 else { return 0 }
        let cg = cgContext
        cg.saveGState()
        cg.textMatrix = .identity
        cg.translateBy(x: 0, y: pageSize.height)
        cg.scaleBy(x: 1, y: -1)

        let flipped = CGRect(
            x: rect.minX,
            y: pageSize.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        let path = CGPath(rect: flipped, transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(index, 0), path, nil)
        CTFrameDraw(frame, cg)
        cg.restoreGState()

        let visible = CTFrameGetVisibleStringRange(frame)
        return visible.length
    }

    // MARK: Rules and fills

    /// A horizontal hairline. The single most useful piece of document
    /// furniture there is.
    func drawRule(
        color: UIColor,
        thickness: CGFloat = 0.75,
        width: CGFloat? = nil,
        x: CGFloat? = nil,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0
    ) {
        if pageIndex < 0 { beginPage() }
        cursorY += spacingBefore
        reserve(thickness + spacingAfter)
        let originX = x ?? contentRect.minX
        let ruleWidth = width ?? (contentRect.maxX - originX)
        cgContext.setFillColor(color.cgColor)
        cgContext.fill(CGRect(x: originX, y: cursorY, width: ruleWidth, height: thickness))
        cursorY += thickness + spacingAfter
    }

    /// Filled rectangle, optionally rounded. Used for the header band and for
    /// the total callout.
    func fill(rect: CGRect, color: UIColor, cornerRadius: CGFloat = 0) {
        cgContext.setFillColor(color.cgColor)
        if cornerRadius > 0 {
            let path = UIBezierPath(roundedRect: rect, cornerRadius: cornerRadius)
            cgContext.addPath(path.cgPath)
            cgContext.fillPath()
        } else {
            cgContext.fill(rect)
        }
    }

    func stroke(rect: CGRect, color: UIColor, thickness: CGFloat = 0.75, cornerRadius: CGFloat = 0) {
        cgContext.setStrokeColor(color.cgColor)
        cgContext.setLineWidth(thickness)
        if cornerRadius > 0 {
            let path = UIBezierPath(roundedRect: rect.insetBy(dx: thickness / 2, dy: thickness / 2), cornerRadius: cornerRadius)
            cgContext.addPath(path.cgPath)
            cgContext.strokePath()
        } else {
            cgContext.stroke(rect.insetBy(dx: thickness / 2, dy: thickness / 2))
        }
    }

    // MARK: Images

    /// Draws an image scaled to fit a box, preserving aspect ratio, and
    /// advances the cursor. Returns the rect actually drawn into.
    @discardableResult
    func drawImage(
        _ image: UIImage,
        maxSize: CGSize,
        x: CGFloat? = nil,
        alignment: NSTextAlignment = .left,
        spacingAfter: CGFloat = 0,
        advancesCursor: Bool = true
    ) -> CGRect {
        if pageIndex < 0 { beginPage() }
        let scale = min(
            maxSize.width / max(image.size.width, 1),
            maxSize.height / max(image.size.height, 1),
            1  // never upscale — a 40pt logo blown up to 120pt looks terrible
        )
        let drawnSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        var originX = x ?? contentRect.minX
        switch alignment {
        case .center: originX = contentRect.midX - drawnSize.width / 2
        case .right: originX = contentRect.maxX - drawnSize.width
        default: break
        }

        if advancesCursor { reserve(drawnSize.height + spacingAfter) }
        let rect = CGRect(origin: CGPoint(x: originX, y: cursorY), size: drawnSize)
        image.draw(in: rect)
        if advancesCursor { cursorY += drawnSize.height + spacingAfter }
        return rect
    }

    /// Draws an image at an exact rect without touching the cursor.
    func drawImage(_ image: UIImage, in rect: CGRect) {
        image.draw(in: rect)
    }

    // MARK: Two-column and table helpers

    /// A label/value row, label left, value right-aligned. The workhorse of the
    /// receipt template.
    func drawFieldRow(
        label: String,
        value: String,
        labelStyle: TextStyle,
        valueStyle: TextStyle,
        labelWidth: CGFloat = 150,
        spacingAfter: CGFloat = 6
    ) {
        if pageIndex < 0 { beginPage() }
        let labelAttributed = labelStyle.attributed(label)
        var rightStyle = valueStyle
        rightStyle.alignment = .right
        let valueAttributed = rightStyle.attributed(value)

        let valueWidth = contentWidth - labelWidth - 12
        let height = max(
            measure(labelAttributed, width: labelWidth).height,
            measure(valueAttributed, width: valueWidth).height
        )
        reserve(height + spacingAfter)

        drawLine(labelAttributed, in: CGRect(
            x: contentRect.minX, y: cursorY, width: labelWidth, height: height
        ))
        drawLine(valueAttributed, in: CGRect(
            x: contentRect.maxX - valueWidth, y: cursorY, width: valueWidth, height: height
        ))
        cursorY += height + spacingAfter
    }

    /// Two independent blocks of text side by side — "From" and "To" on the
    /// receipt, or the signature block and the date line.
    func drawColumns(
        left: NSAttributedString,
        right: NSAttributedString,
        gutter: CGFloat = 24,
        spacingAfter: CGFloat = 0
    ) {
        if pageIndex < 0 { beginPage() }
        let columnWidth = (contentWidth - gutter) / 2
        let leftHeight = measure(left, width: columnWidth).height
        let rightHeight = measure(right, width: columnWidth).height
        let height = max(leftHeight, rightHeight)
        reserve(height + spacingAfter)

        drawLine(left, in: CGRect(x: contentRect.minX, y: cursorY, width: columnWidth, height: leftHeight))
        drawLine(right, in: CGRect(
            x: contentRect.minX + columnWidth + gutter,
            y: cursorY,
            width: columnWidth,
            height: rightHeight
        ))
        cursorY += height + spacingAfter
    }
}

// MARK: - Rendering entry point

/// Renders a document in two passes so footers can say "Page 1 of 2".
///
/// The first pass draws into a throwaway context purely to count pages. PDF
/// generation here takes single-digit milliseconds, so the second pass is not
/// a performance concern and the honest page numbers are worth it.
enum PDFDocumentBuilder {

    /// - Parameter draw: called with a fresh canvas. Must draw the whole
    ///   document. Called twice.
    static func build(
        pageSize: CGSize,
        margins: PDFCanvas.Margins,
        metadata: [String: Any],
        draw: (PDFCanvas) -> Void
    ) -> Data {
        let bounds = CGRect(origin: .zero, size: pageSize)

        // Pass one: count pages.
        let countingFormat = UIGraphicsPDFRendererFormat()
        let countingRenderer = UIGraphicsPDFRenderer(bounds: bounds, format: countingFormat)
        var totalPages = 1
        _ = countingRenderer.pdfData { context in
            let canvas = PDFCanvas(context: context, pageSize: pageSize, margins: margins)
            draw(canvas)
            canvas.finish(totalPages: canvas.pageCount)
            totalPages = max(1, canvas.pageCount)
        }

        // Pass two: the real document, now that the page count is known.
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = metadata
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { context in
            let canvas = PDFCanvas(context: context, pageSize: pageSize, margins: margins)
            canvas.knownTotalPages = totalPages
            draw(canvas)
            canvas.finish(totalPages: totalPages)
        }
    }
}
