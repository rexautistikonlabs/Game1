//
//  MessageComposer.swift
//  FieldForge
//
//  `MFMessageComposeViewController` with the pay-link body already filled.
//  Falls back to `sms:` when Messages cannot send (no SIM, iPad).
//

import MessageUI
import SwiftUI
import UIKit

struct MessageComposer: UIViewControllerRepresentable {

    let recipients: [String]
    let body: String
    var onFinish: (MessageComposeResult) -> Void

    static var canSendText: Bool { MFMessageComposeViewController.canSendText() }

    func makeUIViewController(context: Context) -> MFMessageComposeViewController {
        let controller = MFMessageComposeViewController()
        controller.messageComposeDelegate = context.coordinator
        controller.recipients = recipients.filter { !$0.isEmpty }
        controller.body = body
        return controller
    }

    func updateUIViewController(_ controller: MFMessageComposeViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        let onFinish: (MessageComposeResult) -> Void

        init(onFinish: @escaping (MessageComposeResult) -> Void) {
            self.onFinish = onFinish
        }

        func messageComposeViewController(
            _ controller: MFMessageComposeViewController,
            didFinishWith result: MessageComposeResult
        ) {
            controller.dismiss(animated: true) { [onFinish] in
                onFinish(result)
            }
        }
    }
}
