//
//  Haptics.swift
//  FieldForge
//
//  Feedback you can feel with the phone in one hand and your eyes on a person.
//
//  Used sparingly and meaningfully: a payment clearing and a document being
//  saved are worth a tap, scrolling a list is not. Every call here has a
//  visible counterpart, so a device with haptics disabled loses nothing.
//

import UIKit

@MainActor
enum Haptics {

    /// A gift was captured, a document issued — something worth a small
    /// celebration while looking the donor in the eye.
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A payment declined, a required field missing.
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// A rating tapped, a toggle flipped.
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// A step in the capture flow completed.
    static func step() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
