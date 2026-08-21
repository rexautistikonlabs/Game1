//
//  DocumentExporter.swift
//  FieldForge
//
//  Getting the finished PDF off the phone: Mail, AirDrop, Messages, print, or
//  save to Files.
//
//  An honest note about offline email, because it shapes the whole design:
//  iOS gives an app no way to send mail silently. `MFMailComposeViewController`
//  needs a foreground presentation and a configured Mail account, and there is
//  no background send. So "queue for later sending" here means the *intent* is
//  stored durably in the outbox, and the Outbox screen walks the staffer
//  through the composers the moment they are back on signal — one tap each,
//  in a batch, instead of forty forgotten follow-ups.
//
//  If an organization wants true unattended sending, `MailTransport` is the
//  seam: implement it against a transactional mail API and the outbox drains
//  without any user interaction. See README, "Sending mail without a person".
//

import MessageUI
import PDFKit
import SwiftUI
import UIKit

// MARK: - Share sheet (AirDrop, Messages, Files, anything installed)

/// A share sheet wrapper that hands over a real file URL rather than raw Data.
///
/// This matters: AirDrop of a `Data` blob arrives as "Untitled", while a file
/// URL arrives as "Acknowledgment-ACK-2026-0007-Delgado-Hardware.pdf". On the
/// receiving end that is the difference between a document and a mystery.
struct DocumentShareSheet: UIViewControllerRepresentable {

    let fileURLs: [URL]
    var subject: String = ""
    /// Called with the activity type that completed, so the document can record
    /// how it actually left the phone.
    var onCompletion: ((_ activity: String?, _ completed: Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: fileURLs, applicationActivities: nil)
        controller.setValue(subject, forKey: "subject")   // used by Mail
        controller.completionWithItemsHandler = { activityType, completed, _, _ in
            onCompletion?(activityType?.rawValue, completed)
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Mail composer

/// `MFMailComposeViewController` with the PDF already attached and the body
/// already written, so sending is one tap.
struct MailComposer: UIViewControllerRepresentable {

    struct Message {
        var recipients: [String]
        var subject: String
        var body: String
        var attachmentData: Data?
        var attachmentFileName: String
    }

    let message: Message
    var onFinish: (MFMailComposeResult, Error?) -> Void

    /// Always check before presenting. A phone with no Mail account configured
    /// shows a blank composer that cannot send, which reads as a broken app.
    static var canSendMail: Bool { MFMailComposeViewController.canSendMail() }

    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let controller = MFMailComposeViewController()
        controller.mailComposeDelegate = context.coordinator
        controller.setToRecipients(message.recipients.filter { !$0.isEmpty })
        controller.setSubject(message.subject)
        controller.setMessageBody(message.body, isHTML: false)
        if let data = message.attachmentData {
            controller.addAttachmentData(data, mimeType: "application/pdf", fileName: message.attachmentFileName)
        }
        return controller
    }

    func updateUIViewController(_ controller: MFMailComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: (MFMailComposeResult, Error?) -> Void

        init(onFinish: @escaping (MFMailComposeResult, Error?) -> Void) {
            self.onFinish = onFinish
        }

        func mailComposeController(
            _ controller: MFMailComposeViewController,
            didFinishWith result: MFMailComposeResult,
            error: Error?
        ) {
            controller.dismiss(animated: true) { [onFinish] in
                onFinish(result, error)
            }
        }
    }
}

// MARK: - Message bodies

/// Composes the covering email. Short, warm, and it repeats the key facts in
/// the body so a donor who never opens the attachment still has what they need.
enum DocumentMessageBuilder {

    static func mailMessage(for document: GeneratedDocument) -> MailComposer.Message {
        MailComposer.Message(
            recipients: [document.recipientEmail].filter { !$0.isEmpty },
            subject: subject(for: document),
            body: body(for: document),
            attachmentData: document.pdfData ?? DocumentEngine.reprint(document),
            attachmentFileName: document.suggestedFileName
        )
    }

    static func subject(for document: GeneratedDocument) -> String {
        switch document.kind {
        case .receipt:
            return "Your receipt from \(document.organizationName) — \(document.documentNumber)"
        case .letter:
            return "Thank you from \(document.organizationName) — gift acknowledgment \(document.documentNumber)"
        }
    }

    static func body(for document: GeneratedDocument) -> String {
        let amountLine = document.inKindDescription.trimmedOrNil
            .map { "Donated: \($0)" }
            ?? "Amount: \(document.amount.formatted)"

        let deductibleLine = document.deductibleAmountMinorUnits != document.amountMinorUnits
            ? "\nTax-deductible portion: \(document.deductibleAmount.formatted)"
            : ""

        let signature = [document.signatoryName.trimmedOrNil, document.signatoryTitle.trimmedOrNil]
            .compactMap { $0 }
            .joined(separator: "\n")

        return """
        \(document.recipientName.trimmedOrNil.map { "Dear \($0)," } ?? "Hello,")

        Thank you for your support of \(document.organizationName). \
        \(document.kind == .receipt ? "Your receipt is attached." : "Your acknowledgment letter is attached for your tax records.")

        \(amountLine)\(deductibleLine)
        Date of gift: \(document.giftDate.formatted(date: .long, time: .omitted))
        Reference: \(document.documentNumber)

        With gratitude,
        \(signature.isEmpty ? document.organizationName : signature)
        \(document.organizationName)\(document.organizationEIN.trimmedOrNil.map { "\nEIN \($0)" } ?? "")
        """
    }

    /// For Messages and WhatsApp, where an attachment plus a wall of text is
    /// wrong. Short, and the PDF rides along as the file.
    static func shortMessage(for document: GeneratedDocument) -> String {
        "Thanks again from \(document.organizationName) — here is your \(document.kind == .receipt ? "receipt" : "gift acknowledgment") (\(document.documentNumber))."
    }
}

// MARK: - Printing

/// AirPrint, straight from the PDF. Nonprofits with an office printer use this
/// for the donor who wants paper and does not use email.
enum DocumentPrinter {

    @MainActor
    static func print(document: GeneratedDocument, completion: ((Bool) -> Void)? = nil) {
        let data = document.pdfData ?? DocumentEngine.reprint(document)
        guard UIPrintInteractionController.canPrint(data) else {
            completion?(false)
            return
        }

        let info = UIPrintInfo.printInfo()
        info.outputType = .general
        info.jobName = document.suggestedFileName
        info.orientation = .portrait

        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = data
        controller.present(animated: true) { _, completed, error in
            if let error {
                AppLog.documents.error("Print failed: \(error.localizedDescription, privacy: .public)")
            }
            completion?(completed)
        }
    }
}

// MARK: - Server-side send seam

/// The extension point for unattended email.
///
/// The app ships with no implementation, and that is a deliberate choice: a
/// field app that requires a backend is a field app that stops working. An
/// organization that wants documents to send themselves implements this against
/// their own transactional mail provider, registers it at launch, and the
/// outbox stops needing a human.
protocol MailTransport: Sendable {
    /// Sends the message without any UI. Throws to signal a retryable failure.
    func send(_ message: MailComposer.Message) async throws
}

/// The default: there is no transport, so the outbox falls back to walking the
/// staffer through Mail composers. Never silently drops a message.
struct UnattendedMailUnavailable: MailTransport {
    struct NotConfigured: LocalizedError {
        var errorDescription: String? {
            "No mail service is configured, so this will be sent through the Mail app."
        }
    }

    func send(_ message: MailComposer.Message) async throws {
        throw NotConfigured()
    }
}

/// Registry so `OutboxProcessor` does not need to know which transport is in
/// play. Set once, at launch, from `FieldForgeApp`.
@MainActor
enum MailTransportRegistry {
    static var current: MailTransport = UnattendedMailUnavailable()

    static var supportsUnattendedSending: Bool {
        !(current is UnattendedMailUnavailable)
    }
}
