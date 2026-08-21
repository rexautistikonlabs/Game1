//
//  ReceiptRenderer.swift
//  FieldForge
//
//  The business-style receipt. This is the document you hand across a counter.
//
//  Design intent: it should look like it came out of an accounts department,
//  not out of an app. That means a real letterhead, a single unmissable total,
//  payment details a bookkeeper can reconcile against a card statement, and a
//  signature. One page, always — if a receipt needs two pages something has
//  gone wrong upstream.
//

import Foundation
import UIKit

struct ReceiptRenderer {

    let content: DocumentContent

    // MARK: Type scale
    //
    // Deliberately restrained: three sizes and two weights. Documents that use
    // five typefaces look like ransom notes.

    private var titleStyle: TextStyle {
        TextStyle(font: TextStyle.sans(22, weight: .bold), color: .black, kerning: -0.3)
    }

    private var orgNameStyle: TextStyle {
        TextStyle(font: TextStyle.sans(15, weight: .semibold), color: .black)
    }

    private var orgNameReversedStyle: TextStyle {
        TextStyle(font: TextStyle.sans(15, weight: .semibold), color: .white)
    }

    private var letterheadStyle: TextStyle {
        TextStyle(font: TextStyle.sans(8.5), color: UIColor(white: 0.35, alpha: 1), lineHeightMultiple: 1.3)
    }

    private var letterheadReversedStyle: TextStyle {
        TextStyle(font: TextStyle.sans(8.5), color: UIColor(white: 1, alpha: 0.85), lineHeightMultiple: 1.3)
    }

    private var captionStyle: TextStyle {
        TextStyle(
            font: TextStyle.sans(7.5, weight: .semibold),
            color: UIColor(white: 0.45, alpha: 1),
            kerning: 0.8,
            isUppercased: true
        )
    }

    private var bodyStyle: TextStyle {
        TextStyle(font: TextStyle.sans(10.5), color: .black, lineHeightMultiple: 1.3)
    }

    private var bodyBoldStyle: TextStyle {
        TextStyle(font: TextStyle.sans(10.5, weight: .semibold), color: .black, lineHeightMultiple: 1.3)
    }

    private var amountStyle: TextStyle {
        TextStyle(font: TextStyle.monospacedDigits(10.5), color: .black)
    }

    private var totalStyle: TextStyle {
        TextStyle(font: TextStyle.monospacedDigits(24, weight: .bold), color: .black, kerning: -0.5)
    }

    private var fineStyle: TextStyle {
        TextStyle(font: TextStyle.sans(7.5), color: UIColor(white: 0.4, alpha: 1), lineHeightMultiple: 1.35)
    }

    private var rule: UIColor { UIColor(white: 0.86, alpha: 1) }

    // MARK: Render

    func render() -> Data {
        PDFDocumentBuilder.build(
            pageSize: content.pageSize.size,
            margins: .receipt,
            metadata: [
                kCGPDFContextTitle as String: "\(content.documentTitle) \(content.documentNumber)",
                kCGPDFContextAuthor as String: content.organizationName,
                kCGPDFContextSubject as String: "Donation receipt \(content.documentNumber)",
                kCGPDFContextCreator as String: "FieldForge",
            ]
        ) { canvas in
            canvas.beginPage()
            drawLetterhead(canvas)
            drawTitleBlock(canvas)
            drawParties(canvas)
            drawLineItems(canvas)
            drawTotal(canvas)
            drawPaymentDetails(canvas)
            drawTaxNote(canvas)
            drawSignature(canvas)
            drawFooter(canvas)
        }
    }

    // MARK: Blocks

    /// Logo and contact block. Two variants — a colour band for brands that
    /// want presence, a quiet rule for brands that do not. Both read as an
    /// office; neither reads as a template.
    private func drawLetterhead(_ canvas: PDFCanvas) {
        // A receipt only needs two treatments: a band, or a quiet rule. `split`
        // and `minimal` both collapse to the quiet variant, which is what they
        // look like at receipt scale anyway.
        if content.letterheadStyle == .colorBand {
            let bandHeight: CGFloat = 92
            let band = CGRect(x: 0, y: 0, width: canvas.pageSize.width, height: bandHeight)
            canvas.fill(rect: band, color: content.brandColor)

            let inset = canvas.margins.left
            var y: CGFloat = 24

            if let logo = content.logo {
                canvas.moveCursor(to: 24)
                canvas.drawImage(
                    logo,
                    maxSize: CGSize(width: 130, height: 44),
                    x: inset,
                    advancesCursor: false
                )
                y = 24
                // Text sits to the right of the logo inside the band.
                let textX = inset + 146
                let width = canvas.pageSize.width - textX - inset
                canvas.drawLine(
                    orgNameReversedStyle.attributed(content.organizationName),
                    in: CGRect(x: textX, y: y, width: width, height: 20)
                )
                canvas.drawLine(
                    letterheadReversedStyle.attributed(content.organizationAddressLines.joined(separator: " · ")),
                    in: CGRect(x: textX, y: y + 20, width: width, height: 30)
                )
            } else {
                let width = canvas.pageSize.width - inset * 2
                canvas.drawLine(
                    orgNameReversedStyle.attributed(content.organizationName),
                    in: CGRect(x: inset, y: y, width: width, height: 20)
                )
                canvas.drawLine(
                    letterheadReversedStyle.attributed(content.organizationAddressLines.joined(separator: " · ")),
                    in: CGRect(x: inset, y: y + 21, width: width, height: 34)
                )
            }
            canvas.moveCursor(to: bandHeight + 28)
            return
        }

        // Quiet variant.
        if let logo = content.logo {
            canvas.drawImage(logo, maxSize: CGSize(width: 150, height: 52), spacingAfter: 10)
        }
        canvas.drawText(content.organizationName, style: orgNameStyle, spacingAfter: 2)
        if !content.organizationAddressLines.isEmpty {
            canvas.drawText(
                content.organizationAddressLines.joined(separator: "\n"),
                style: letterheadStyle,
                width: canvas.contentWidth * 0.6,
                spacingAfter: 2
            )
        }
        if let ein = content.einLine.trimmedOrNil {
            canvas.drawText(ein, style: letterheadStyle, spacingAfter: 0)
        }
        canvas.drawRule(color: content.brandColor, thickness: 2.5, width: 56, spacingBefore: 12, spacingAfter: 20)
    }

    /// "DONATION RECEIPT", the number, and the date — the three things someone
    /// filing this needs to see without reading.
    private func drawTitleBlock(_ canvas: PDFCanvas) {
        let leftColumn = NSMutableAttributedString()
        leftColumn.append(titleStyle.attributed(content.documentTitle))

        let rightLines = NSMutableAttributedString()
        var rightStyle = captionStyle
        rightStyle.alignment = .right
        var rightValue = bodyBoldStyle
        rightValue.alignment = .right

        rightLines.append(rightStyle.attributed("Receipt no.\n"))
        rightLines.append(rightValue.attributed("\(content.documentNumber)\n"))
        rightLines.append(rightStyle.attributed("Issued\n"))
        rightLines.append(rightValue.attributed(content.formattedIssuedDate))

        canvas.drawColumns(left: leftColumn, right: rightLines, spacingAfter: 18)
        canvas.drawRule(color: rule, spacingAfter: 16)
    }

    /// Received-from / received-by, side by side. A receipt with only one party
    /// on it is a note to self.
    private func drawParties(_ canvas: PDFCanvas) {
        let left = NSMutableAttributedString()
        left.append(captionStyle.attributed("Received from\n"))
        left.append(bodyBoldStyle.attributed(content.displayRecipientName + "\n"))
        if !content.isAnonymous, !content.recipientAddressLines.isEmpty {
            // Drop the first line when it duplicates the name we just printed.
            let addressLines = content.recipientAddressLines.filter { $0 != content.recipientName }
            if !addressLines.isEmpty {
                left.append(bodyStyle.attributed(addressLines.joined(separator: "\n")))
            }
        }

        let right = NSMutableAttributedString()
        right.append(captionStyle.attributed("Received by\n"))
        right.append(bodyBoldStyle.attributed(content.organizationLegalName + "\n"))
        if let ein = content.einLine.trimmedOrNil {
            right.append(bodyStyle.attributed(ein + "\n"))
        }
        right.append(bodyStyle.attributed("Gift date: \(content.formattedGiftDate)"))

        canvas.drawColumns(left: left, right: right, spacingAfter: 22)
    }

    /// The itemised table. One row for most gifts, three when goods or services
    /// were provided and the arithmetic has to be shown.
    private func drawLineItems(_ canvas: PDFCanvas) {
        let amountColumnWidth: CGFloat = 110
        let descriptionWidth = canvas.contentWidth - amountColumnWidth - 12

        // Header row.
        var headerRight = captionStyle
        headerRight.alignment = .right
        canvas.drawLine(
            captionStyle.attributed("Description"),
            in: CGRect(x: canvas.contentRect.minX, y: canvas.cursorY, width: descriptionWidth, height: 12)
        )
        canvas.drawLine(
            headerRight.attributed(content.isInKind ? "Value" : "Amount"),
            in: CGRect(x: canvas.contentRect.maxX - amountColumnWidth, y: canvas.cursorY, width: amountColumnWidth, height: 12)
        )
        canvas.advance(14)
        canvas.drawRule(color: rule, spacingAfter: 10)

        for item in content.lineItems {
            let labelStyle = item.isEmphasized ? bodyBoldStyle : bodyStyle
            let description = NSMutableAttributedString()
            description.append(labelStyle.attributed(item.label))
            if let detail = item.detail.trimmedOrNil {
                description.append(bodyStyle.attributed("\n" + detail))
            }

            var valueStyle = item.isEmphasized
                ? TextStyle(font: TextStyle.monospacedDigits(11, weight: .bold), color: .black)
                : amountStyle
            valueStyle.alignment = .right

            let rowHeight = max(
                canvas.measure(description, width: descriptionWidth).height,
                14
            )
            canvas.reserve(rowHeight + 10)
            canvas.drawLine(description, in: CGRect(
                x: canvas.contentRect.minX, y: canvas.cursorY, width: descriptionWidth, height: rowHeight
            ))
            canvas.drawLine(valueStyle.attributed(item.amountText), in: CGRect(
                x: canvas.contentRect.maxX - amountColumnWidth, y: canvas.cursorY, width: amountColumnWidth, height: 16
            ))
            canvas.advance(rowHeight + 8)
        }

        if content.needsDonorEstimateFootnote {
            canvas.drawText(
                "* Value stated by the donor. \(content.organizationName) does not appraise donated property.",
                style: fineStyle,
                spacingAfter: 4
            )
        }

        canvas.drawRule(color: rule, spacingBefore: 4, spacingAfter: 0)
    }

    /// The total, in a tinted box. This is the one thing on the page that
    /// should be readable from across a desk.
    private func drawTotal(_ canvas: PDFCanvas) {
        let boxHeight: CGFloat = 62
        canvas.advance(16)
        canvas.reserve(boxHeight + 20)

        let box = CGRect(
            x: canvas.contentRect.minX,
            y: canvas.cursorY,
            width: canvas.contentWidth,
            height: boxHeight
        )
        canvas.fill(rect: box, color: content.brandColor.withAlphaComponent(0.08), cornerRadius: 8)
        canvas.stroke(rect: box, color: content.brandColor.withAlphaComponent(0.35), thickness: 0.75, cornerRadius: 8)

        let label = content.isInKind
            ? "In-kind contribution"
            : (content.providedGoodsOrServices ? "Tax-deductible portion" : "Total received")

        canvas.drawLine(
            captionStyle.attributed(label),
            in: CGRect(x: box.minX + 16, y: box.minY + 13, width: box.width - 32, height: 12)
        )

        let totalText: String
        if content.isInKind {
            totalText = content.showsDonorEstimatedValue && content.donorEstimatedValue.isPositive
                ? content.donorEstimatedValue.formatted
                : "See description"
        } else {
            totalText = content.providedGoodsOrServices
                ? content.deductibleAmount.formatted
                : content.amount.formatted
        }

        var style = totalStyle
        style.color = content.brandColor.darkened()
        // In-kind gifts print words, not a number, so the size steps down.
        if content.isInKind, !(content.showsDonorEstimatedValue && content.donorEstimatedValue.isPositive) {
            style.font = TextStyle.sans(15, weight: .semibold)
        }
        canvas.drawLine(
            style.attributed(totalText),
            in: CGRect(x: box.minX + 16, y: box.minY + 26, width: box.width - 32, height: 30)
        )

        canvas.moveCursor(to: box.maxY + 20)
    }

    private func drawPaymentDetails(_ canvas: PDFCanvas) {
        canvas.drawText("Payment details", style: captionStyle, spacingAfter: 8)
        for (label, value) in content.paymentDetailRows {
            canvas.drawFieldRow(
                label: label,
                value: value,
                labelStyle: bodyStyle,
                valueStyle: bodyBoldStyle,
                labelWidth: 160,
                spacingAfter: 5
            )
        }
        canvas.advance(10)
    }

    private func drawTaxNote(_ canvas: PDFCanvas) {
        canvas.drawRule(color: rule, spacingAfter: 10)
        canvas.drawText(content.receiptFooterNote, style: fineStyle, spacingAfter: 6)
        if let custom = content.customNote {
            canvas.drawText(custom, style: fineStyle, spacingAfter: 6)
        }
    }

    /// Signature and the "for the organization" line. Kept together with
    /// `reserve` so it never orphans.
    private func drawSignature(_ canvas: PDFCanvas) {
        guard content.signatureImage != nil || content.signatoryName.trimmedOrNil != nil else { return }

        let blockHeight: CGFloat = 84
        canvas.advance(14)
        canvas.reserve(blockHeight)

        let signatureWidth: CGFloat = 210
        let baselineY = canvas.cursorY + 46

        if let signature = content.signatureImage {
            // Sit the ink on the baseline rather than centring it in a box —
            // that is what makes it read as a signature and not a sticker.
            let maxHeight: CGFloat = 42
            let scale = min(signatureWidth / max(signature.size.width, 1), maxHeight / max(signature.size.height, 1), 1)
            let drawnSize = CGSize(width: signature.size.width * scale, height: signature.size.height * scale)
            canvas.drawImage(signature, in: CGRect(
                x: canvas.contentRect.minX,
                y: baselineY - drawnSize.height,
                width: drawnSize.width,
                height: drawnSize.height
            ))
        }

        canvas.fill(
            rect: CGRect(x: canvas.contentRect.minX, y: baselineY, width: signatureWidth, height: 0.75),
            color: UIColor(white: 0.55, alpha: 1)
        )
        canvas.drawLine(
            captionStyle.attributed("Authorised signature"),
            in: CGRect(x: canvas.contentRect.minX, y: baselineY + 5, width: signatureWidth, height: 12)
        )
        if let name = content.signatoryName.trimmedOrNil {
            let titleSuffix = content.signatoryTitle.trimmedOrNil.map { ", \($0)" } ?? ""
            canvas.drawLine(
                bodyStyle.attributed(name + titleSuffix),
                in: CGRect(x: canvas.contentRect.minX, y: baselineY + 17, width: canvas.contentWidth, height: 16)
            )
        }
        canvas.moveCursor(to: baselineY + 38)
    }

    /// Pinned to the bottom margin so the page always looks finished, even when
    /// the content is short.
    private func drawFooter(_ canvas: PDFCanvas) {
        let footerText = [
            content.footerNote.trimmedOrNil,
            TaxLanguage.disclaimerFooter,
        ]
        .compactMap { $0 }
        .joined(separator: "  ·  ")

        var style = fineStyle
        style.alignment = .center
        style.color = UIColor(white: 0.55, alpha: 1)

        let attributed = style.attributed(footerText)
        let height = canvas.measure(attributed, width: canvas.contentWidth).height
        let y = canvas.pageSize.height - canvas.margins.bottom + 14
        canvas.drawLine(attributed, in: CGRect(
            x: canvas.contentRect.minX,
            y: min(y, canvas.pageSize.height - height - 8),
            width: canvas.contentWidth,
            height: height
        ))
    }
}

// MARK: - Colour helper

extension UIColor {
    /// A darker variant of the brand colour for text, so a pale brand still
    /// produces a readable total. Contrast on paper matters as much as on glass.
    func darkened(by amount: CGFloat = 0.25) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        guard getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return self }
        return UIColor(
            hue: hue,
            saturation: saturation,
            brightness: max(0, min(brightness * (1 - amount), 0.55)),
            alpha: alpha
        )
    }
}
