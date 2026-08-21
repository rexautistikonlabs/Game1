//
//  LetterRenderer.swift
//  FieldForge
//
//  The formal acknowledgment letter. Same gift, same data, completely
//  different object: this is the piece of paper a donor's accountant wants in
//  April, and the one that makes a $2,500 gift deductible.
//
//  Design intent: a real block letter. Serif body, generous leading, a proper
//  inside address, a date line, a salutation, warm human paragraphs, the
//  substantiation language set apart so it cannot be missed, a real signature,
//  and a footer with the EIN. It paginates properly and keeps the signature
//  block whole.
//

import Foundation
import UIKit

struct LetterRenderer {

    let content: DocumentContent

    /// Optional personal sentence the staffer typed in the capture flow. This
    /// is the difference between a form letter and a letter — "Thank you for
    /// the forty blankets; they went out the same afternoon."
    var personalNote: String = ""

    // MARK: Type scale — serif body, sans furniture

    private var orgNameStyle: TextStyle {
        TextStyle(font: TextStyle.body(content.typeface, size: 16, weight: .semibold), color: .black, kerning: -0.2)
    }

    private var orgNameReversedStyle: TextStyle {
        TextStyle(font: TextStyle.body(content.typeface, size: 16, weight: .semibold), color: .white, kerning: -0.2)
    }

    private var letterheadStyle: TextStyle {
        TextStyle(font: TextStyle.sans(8.5), color: UIColor(white: 0.38, alpha: 1), lineHeightMultiple: 1.35)
    }

    private var letterheadReversedStyle: TextStyle {
        TextStyle(font: TextStyle.sans(8.5), color: UIColor(white: 1, alpha: 0.85), lineHeightMultiple: 1.35)
    }

    private var taglineStyle: TextStyle {
        TextStyle(font: TextStyle.body(content.typeface, size: 9.5), color: UIColor(white: 0.45, alpha: 1))
    }

    private var bodyStyle: TextStyle {
        // 11pt on ~15.4pt leading. Reads comfortably on paper and on a phone
        // screen, which is where most of these are actually read now.
        TextStyle(font: TextStyle.body(content.typeface, size: 11), color: UIColor(white: 0.08, alpha: 1), lineHeightMultiple: 1.4, paragraphSpacing: 11)
    }

    private var bodyEmphasisStyle: TextStyle {
        TextStyle(font: TextStyle.body(content.typeface, size: 11, weight: .semibold), color: .black, lineHeightMultiple: 1.4)
    }

    private var addressStyle: TextStyle {
        TextStyle(font: TextStyle.body(content.typeface, size: 11), color: UIColor(white: 0.12, alpha: 1), lineHeightMultiple: 1.3)
    }

    private var captionStyle: TextStyle {
        TextStyle(
            font: TextStyle.sans(7.5, weight: .semibold),
            color: UIColor(white: 0.45, alpha: 1),
            kerning: 0.8,
            isUppercased: true
        )
    }

    private var summaryValueStyle: TextStyle {
        TextStyle(font: TextStyle.monospacedDigits(12, weight: .semibold), color: .black)
    }

    private var fineStyle: TextStyle {
        TextStyle(font: TextStyle.sans(7.5), color: UIColor(white: 0.42, alpha: 1), lineHeightMultiple: 1.35)
    }

    private var rule: UIColor { UIColor(white: 0.86, alpha: 1) }

    // MARK: Render

    func render() -> Data {
        PDFDocumentBuilder.build(
            pageSize: content.pageSize.size,
            margins: .letter,
            metadata: [
                kCGPDFContextTitle as String: "\(content.documentTitle) \(content.documentNumber)",
                kCGPDFContextAuthor as String: content.organizationName,
                kCGPDFContextSubject as String: "Charitable contribution acknowledgment",
                kCGPDFContextCreator as String: "FieldForge",
                kCGPDFContextKeywords as String: "donation, acknowledgment, 501(c)(3), tax receipt",
            ]
        ) { canvas in
            // Pages after the first get a slim running header rather than the
            // full letterhead — that is how real letterhead stationery works.
            canvas.runningHeader = { canvas, _ in
                let text = [content.organizationName, content.documentNumber]
                    .compactMap { $0.trimmedOrNil }
                    .joined(separator: "  ·  ")
                let attributed = self.fineStyle.attributed(text)
                canvas.drawLine(attributed, in: CGRect(
                    x: canvas.contentRect.minX,
                    y: canvas.contentRect.minY,
                    width: canvas.contentWidth,
                    height: 12
                ))
                canvas.fill(
                    rect: CGRect(x: canvas.contentRect.minX, y: canvas.contentRect.minY + 16, width: canvas.contentWidth, height: 0.5),
                    color: self.rule
                )
                return 30
            }

            canvas.runningFooter = { canvas, pageIndex, totalPages in
                self.drawFooter(canvas, pageIndex: pageIndex, totalPages: totalPages)
            }

            canvas.beginPage()
            drawLetterhead(canvas)
            drawDateAndReference(canvas)
            drawInsideAddress(canvas)
            drawSalutation(canvas)
            drawBody(canvas)
            drawGiftSummaryBlock(canvas)
            drawInKindPhotos(canvas)
            drawSubstantiation(canvas)
            drawClosing(canvas)
            drawSignatureBlock(canvas)
        }
    }

    // MARK: Blocks

    private func drawLetterhead(_ canvas: PDFCanvas) {
        switch content.letterheadStyle {
        case .colorBand: drawColorBandLetterhead(canvas)
        case .classic: drawClassicLetterhead(canvas)
        case .split: drawSplitLetterhead(canvas)
        case .minimal: drawMinimalLetterhead(canvas)
        }
    }

    /// Logo left, contact block right, one rule under both. The most space
    /// efficient of the four, which matters on a letter that runs long.
    private func drawSplitLetterhead(_ canvas: PDFCanvas) {
        let topY = canvas.contentRect.minY
        var textTop = topY

        if let logo = content.logo {
            canvas.moveCursor(to: topY)
            let rect = canvas.drawImage(
                logo,
                maxSize: CGSize(width: 150, height: 50),
                x: canvas.contentRect.minX,
                advancesCursor: false
            )
            textTop = topY
            _ = rect
        }

        var rightStyle = letterheadStyle
        rightStyle.alignment = .right
        var lines = content.organizationAddressLines
        if let ein = content.einLine.trimmedOrNil { lines.append(ein) }

        let rightWidth = canvas.contentWidth * 0.45
        var nameStyle = orgNameStyle
        nameStyle.alignment = .right
        canvas.drawLine(
            nameStyle.attributed(content.organizationName),
            in: CGRect(x: canvas.contentRect.maxX - rightWidth, y: textTop, width: rightWidth, height: 22)
        )
        canvas.drawLine(
            rightStyle.attributed(lines.joined(separator: "\n")),
            in: CGRect(x: canvas.contentRect.maxX - rightWidth, y: textTop + 21, width: rightWidth, height: 56)
        )

        canvas.moveCursor(to: topY + 74)
        canvas.drawRule(color: content.brandColor.withAlphaComponent(0.5), thickness: 1, spacingAfter: 26)
    }

    /// Name and EIN in small type, nothing else. For organizations printing
    /// onto stationery that already carries their letterhead.
    private func drawMinimalLetterhead(_ canvas: PDFCanvas) {
        var lines = [content.organizationName]
        if let ein = content.einLine.trimmedOrNil { lines.append(ein) }
        canvas.drawText(lines.joined(separator: "  ·  "), style: letterheadStyle, spacingAfter: 30)
    }

    /// Full-width brand band with reversed text. Reads best when the
    /// organization has a logo worth showing.
    private func drawColorBandLetterhead(_ canvas: PDFCanvas) {
        let bandHeight: CGFloat = 104
        canvas.fill(
            rect: CGRect(x: 0, y: 0, width: canvas.pageSize.width, height: bandHeight),
            color: content.brandColor
        )
        let inset = canvas.margins.left
        var textX = inset
        if let logo = content.logo {
            canvas.moveCursor(to: 28)
            canvas.drawImage(logo, maxSize: CGSize(width: 120, height: 48), x: inset, advancesCursor: false)
            textX = inset + 136
        }
        let width = canvas.pageSize.width - textX - inset
        canvas.drawLine(
            orgNameReversedStyle.attributed(content.organizationName),
            in: CGRect(x: textX, y: 28, width: width, height: 22)
        )
        var lines = content.organizationAddressLines
        if let ein = content.einLine.trimmedOrNil { lines.append(ein) }
        canvas.drawLine(
            letterheadReversedStyle.attributed(lines.joined(separator: " · ")),
            in: CGRect(x: textX, y: 51, width: width, height: 40)
        )
        canvas.moveCursor(to: bandHeight + 34)
    }

    /// Classic centred letterhead. Understated on purpose: the letter is the
    /// message, the letterhead only has to establish that it is real.
    private func drawClassicLetterhead(_ canvas: PDFCanvas) {
        if let logo = content.logo {
            canvas.drawImage(logo, maxSize: CGSize(width: 170, height: 58), alignment: .center, spacingAfter: 10)
        }

        var centredName = orgNameStyle
        centredName.alignment = .center
        canvas.drawText(content.organizationName, style: centredName, spacingAfter: 3)

        if let tagline = content.tagline.trimmedOrNil {
            var style = taglineStyle
            style.alignment = .center
            canvas.drawText(tagline, style: style, spacingAfter: 5)
        }

        var centredAddress = letterheadStyle
        centredAddress.alignment = .center
        var lines = content.organizationAddressLines
        if let ein = content.einLine.trimmedOrNil { lines.append(ein) }
        if !lines.isEmpty {
            canvas.drawText(lines.joined(separator: "  ·  "), style: centredAddress, spacingAfter: 12)
        }

        canvas.drawRule(color: content.brandColor.withAlphaComponent(0.5), thickness: 1, spacingAfter: 28)
    }

    /// Date on the left, document number on the right. The number is what makes
    /// a phone call about "my receipt" resolvable in ten seconds.
    private func drawDateAndReference(_ canvas: PDFCanvas) {
        let left = NSMutableAttributedString(attributedString: bodyStyle.attributed(content.formattedIssuedDate))

        var rightCaption = captionStyle
        rightCaption.alignment = .right
        var rightValue = bodyStyle
        rightValue.alignment = .right
        let right = NSMutableAttributedString()
        right.append(rightCaption.attributed("Reference\n"))
        right.append(rightValue.attributed(content.documentNumber))

        canvas.drawColumns(left: left, right: right, spacingAfter: 26)
    }

    private func drawInsideAddress(_ canvas: PDFCanvas) {
        guard !content.isAnonymous else {
            canvas.drawText("Anonymous donor", style: addressStyle, spacingAfter: 26)
            return
        }
        let lines = content.recipientAddressLines.isEmpty
            ? [content.recipientName]
            : content.recipientAddressLines
        canvas.drawText(lines.joined(separator: "\n"), style: addressStyle, width: canvas.contentWidth * 0.6, spacingAfter: 26)
    }

    private func drawSalutation(_ canvas: PDFCanvas) {
        canvas.drawText(content.salutation, style: bodyStyle, spacingAfter: 14)
    }

    /// The human part. Written to be read by a person, and varied enough by
    /// gift type that it does not feel like a mail merge.
    private func drawBody(_ canvas: PDFCanvas) {
        var paragraphs: [String] = []

        if content.isInKind {
            let description = content.inKindDescription.trimmedOrNil ?? "your generous donation of goods"
            paragraphs.append(
                """
                Thank you for your gift of \(description) to \(content.organizationName). Donations \
                like yours arrive as something we can put directly into the hands of the people we \
                serve, which is why they matter so much to us.
                """
            )
        } else if content.providedGoodsOrServices {
            paragraphs.append(
                """
                Thank you for your support of \(content.organizationName). We received your payment \
                of \(content.amount.formattedCompact) on \(content.formattedGiftDate), and we are \
                grateful for your participation.
                """
            )
        } else {
            paragraphs.append(
                """
                Thank you for your generous contribution of \(content.amount.formattedCompact) to \
                \(content.organizationName), received on \(content.formattedGiftDate). Your support \
                makes our work possible, and we do not take it for granted.
                """
            )
        }

        if let fund = content.fundName.trimmedOrNil, !content.isInKind {
            paragraphs.append("Your gift has been designated to the \(fund).")
        }

        if let note = personalNote.trimmedOrNil {
            paragraphs.append(note)
        }

        paragraphs.append(
            "Please keep this letter with your tax records. It is your official acknowledgment of this gift."
        )

        // One attributed string so Core Text handles widow and orphan control
        // across the whole body rather than paragraph by paragraph.
        let body = NSMutableAttributedString()
        for (index, paragraph) in paragraphs.enumerated() {
            body.append(bodyStyle.attributed(paragraph))
            if index < paragraphs.count - 1 {
                body.append(bodyStyle.attributed("\n"))
            }
        }
        canvas.drawText(body, spacingAfter: 18)
    }

    /// A boxed summary of the gift facts. Not legally required, but it is the
    /// first thing a bookkeeper's eye goes to, and it keeps the prose readable
    /// by taking the numbers out of it.
    private func drawGiftSummaryBlock(_ canvas: PDFCanvas) {
        let rows: [(String, String)] = {
            var rows: [(String, String)] = [("Date of gift", content.formattedGiftDate)]
            if content.isInKind {
                rows.append(("Description", content.inKindDescription.trimmedOrNil ?? "Donated property"))
                if content.showsDonorEstimatedValue, content.donorEstimatedValue.isPositive {
                    rows.append(("Donor's estimated value", content.donorEstimatedValue.formatted))
                }
            } else {
                rows.append(("Amount received", content.amount.formatted))
                if content.providedGoodsOrServices {
                    rows.append(("Value of goods or services", content.goodsOrServicesValue.formatted))
                    rows.append(("Tax-deductible amount", content.deductibleAmount.formatted))
                }
            }
            rows.append(("Method", content.methodLabel))
            if let fund = content.fundName.trimmedOrNil { rows.append(("Designation", fund)) }
            return rows
        }()

        let rowHeight: CGFloat = 17
        let padding: CGFloat = 14
        let boxHeight = CGFloat(rows.count) * rowHeight + padding * 2

        canvas.reserve(boxHeight + 20)
        let box = CGRect(
            x: canvas.contentRect.minX,
            y: canvas.cursorY,
            width: canvas.contentWidth,
            height: boxHeight
        )
        canvas.fill(rect: box, color: content.brandColor.withAlphaComponent(0.06), cornerRadius: 6)

        // A colour bar on the leading edge, the one piece of decoration on the
        // page. It anchors the block without shouting.
        canvas.fill(
            rect: CGRect(x: box.minX, y: box.minY, width: 3, height: box.height),
            color: content.brandColor
        )

        var y = box.minY + padding
        var labelStyle = captionStyle
        labelStyle.isUppercased = false
        labelStyle.font = TextStyle.sans(9)
        labelStyle.kerning = 0
        var valueStyle = summaryValueStyle
        valueStyle.alignment = .right

        for (label, value) in rows {
            canvas.drawLine(labelStyle.attributed(label), in: CGRect(
                x: box.minX + padding + 6, y: y + 1, width: box.width * 0.5, height: rowHeight
            ))
            canvas.drawLine(valueStyle.attributed(value), in: CGRect(
                x: box.maxX - padding - box.width * 0.45,
                y: y,
                width: box.width * 0.45,
                height: rowHeight
            ))
            y += rowHeight
        }

        canvas.moveCursor(to: box.maxY + 20)
    }

    /// Photographs of the donated items.
    ///
    /// Placed after the summary and before the tax paragraph deliberately: the
    /// summary says "42 blankets", the photographs show them, and then the
    /// substantiation language has the last word — which is the order a donor's
    /// accountant reads in.
    ///
    /// The caption is careful. A photograph of donated goods sitting next to a
    /// number could easily read as the charity valuing the property, which is
    /// exactly what `TaxLanguage` is at pains not to do, so any value shown is
    /// explicitly labelled as the donor's own figure.
    private func drawInKindPhotos(_ canvas: PDFCanvas) {
        guard !content.inKindPhotos.isEmpty else { return }

        canvas.drawText("The donated items", style: captionStyle, spacingAfter: 7)

        var photoCaption = fineStyle
        photoCaption.alignment = .center
        canvas.drawImageGrid(
            content.inKindPhotos,
            columns: content.inKindPhotos.count == 1 ? 1 : 2,
            cellHeight: content.inKindPhotos.count == 1 ? 170 : 118,
            captionStyle: photoCaption,
            spacingAfter: 6
        )

        canvas.drawText(
            "Photographs are provided as a record of the property described above. Any value shown is the donor's own estimate.",
            style: fineStyle,
            spacingAfter: 16
        )
    }

    /// The substantiation language, set apart. This is the paragraph the IRS
    /// cares about, so it is visually distinct and never buried mid-page.
    private func drawSubstantiation(_ canvas: PDFCanvas) {
        canvas.drawText("For your tax records", style: captionStyle, spacingAfter: 7)

        var style = bodyStyle
        style.font = TextStyle.body(content.typeface, size: 9.5)
        style.color = UIColor(white: 0.18, alpha: 1)
        style.paragraphSpacing = 8

        canvas.drawText(content.substantiationParagraph, style: style, spacingAfter: 8)

        if let custom = content.customNote {
            canvas.drawText(custom, style: style, spacingAfter: 8)
        }
        canvas.advance(8)
    }

    private func drawClosing(_ canvas: PDFCanvas) {
        canvas.drawText("With gratitude,", style: bodyStyle, spacingAfter: 0)
    }

    /// Signature, name, title. Reserved as one block so the ink and the name it
    /// belongs to are never on different pages.
    private func drawSignatureBlock(_ canvas: PDFCanvas) {
        let blockHeight: CGFloat = 96
        canvas.reserve(blockHeight)
        canvas.advance(10)

        if let signature = content.signatureImage {
            let maxWidth: CGFloat = 200
            let maxHeight: CGFloat = 48
            let scale = min(maxWidth / max(signature.size.width, 1), maxHeight / max(signature.size.height, 1), 1)
            let size = CGSize(width: signature.size.width * scale, height: signature.size.height * scale)
            canvas.drawImage(signature, in: CGRect(
                x: canvas.contentRect.minX,
                y: canvas.cursorY,
                width: size.width,
                height: size.height
            ))
            canvas.advance(size.height + 6)
        } else {
            // No signature captured: leave real room to sign by hand rather
            // than closing the gap and looking like the letter forgot.
            canvas.advance(46)
        }

        if let name = content.signatoryName.trimmedOrNil {
            canvas.drawText(name, style: bodyEmphasisStyle, spacingAfter: 1)
        }
        if let title = content.signatoryTitle.trimmedOrNil {
            var style = bodyStyle
            style.font = TextStyle.body(content.typeface, size: 10)
            style.color = UIColor(white: 0.35, alpha: 1)
            canvas.drawText(title, style: style, spacingAfter: 1)
        }
        canvas.drawText(content.organizationName, style: {
            var style = bodyStyle
            style.font = TextStyle.body(content.typeface, size: 10)
            style.color = UIColor(white: 0.35, alpha: 1)
            return style
        }(), spacingAfter: 0)
    }

    /// Legal footer plus page numbering, on every page.
    private func drawFooter(_ canvas: PDFCanvas, pageIndex: Int, totalPages: Int) {
        guard content.footerStyle != .none else {
            // Still print page numbers on a multi-page letter: a donor holding
            // page two of two needs to know that is what they have.
            if totalPages > 1 {
                var right = fineStyle
                right.alignment = .right
                canvas.drawLine(
                    right.attributed("Page \(pageIndex + 1) of \(totalPages)"),
                    in: CGRect(
                        x: canvas.contentRect.minX,
                        y: canvas.pageSize.height - canvas.margins.bottom + 16,
                        width: canvas.contentWidth,
                        height: 12
                    )
                )
            }
            return
        }

        var components: [String?] = [
            content.organizationLegalName.trimmedOrNil,
            content.einLine.trimmedOrNil,
        ]
        switch content.footerStyle {
        case .withMission:
            components.append(content.missionStatement.trimmedOrNil)
        case .withContactDetails:
            components.append(contentsOf: content.organizationAddressLines.map { Optional($0) })
        case .legalMinimum, .none:
            break
        }
        components.append(content.footerNote.trimmedOrNil)

        let legalLine = components
            .compactMap { $0 }
            .joined(separator: "  ·  ")

        var centred = fineStyle
        centred.alignment = .center
        let footerY = canvas.pageSize.height - canvas.margins.bottom + 16

        canvas.fill(
            rect: CGRect(x: canvas.contentRect.minX, y: footerY - 12, width: canvas.contentWidth, height: 0.5),
            color: rule
        )

        canvas.drawLine(centred.attributed(legalLine), in: CGRect(
            x: canvas.contentRect.minX, y: footerY, width: canvas.contentWidth, height: 12
        ))

        if totalPages > 1 {
            var right = fineStyle
            right.alignment = .right
            canvas.drawLine(
                right.attributed("Page \(pageIndex + 1) of \(totalPages)"),
                in: CGRect(x: canvas.contentRect.minX, y: footerY + 12, width: canvas.contentWidth, height: 12)
            )
        }

        // The "not tax advice" line only needs to appear once, on the last page.
        if pageIndex == totalPages - 1 {
            var centredSmall = fineStyle
            centredSmall.alignment = .center
            centredSmall.font = TextStyle.sans(6.5)
            centredSmall.color = UIColor(white: 0.58, alpha: 1)
            canvas.drawLine(
                centredSmall.attributed(TaxLanguage.disclaimerFooter),
                in: CGRect(x: canvas.contentRect.minX, y: footerY + (totalPages > 1 ? 24 : 12), width: canvas.contentWidth, height: 12)
            )
        }
    }
}
