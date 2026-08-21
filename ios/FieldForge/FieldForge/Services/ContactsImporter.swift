//
//  ContactsImporter.swift
//  FieldForge
//
//  Pulling in a contact the staffer already has on their phone, instead of
//  making them retype a name they are looking at in Messages.
//
//  Read-only, and it never writes back to the system address book. Two reasons:
//  a fundraising app silently editing someone's personal contacts would be a
//  genuine intrusion, and the app has no business owning that data.
//

import Contacts
import ContactsUI
import Foundation
import SwiftUI
import UIKit

/// The system contact picker. Using Apple's picker rather than requesting full
/// Contacts access means the staffer shares exactly one contact, with no
/// permission prompt at all on modern iOS.
struct SystemContactPicker: UIViewControllerRepresentable {

    var onPick: (CNContact) -> Void
    var onCancel: () -> Void = {}

    func makeUIViewController(context: Context) -> CNContactPickerViewController {
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        // Only what a donor record needs.
        picker.displayedPropertyKeys = [
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactJobTitleKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactPostalAddressesKey,
        ]
        return picker
    }

    func updateUIViewController(_ controller: CNContactPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        let onPick: (CNContact) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (CNContact) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            onPick(contact)
        }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            onCancel()
        }
    }
}

/// Writes a picked system contact into a draft, and offers to open the phone,
/// Messages, or Mail for an existing record.
enum ContactActions {

    /// `tel:` URL, digits only. Returns nil for a number iOS could not dial.
    static func callURL(for phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 7 else { return nil }
        return URL(string: "tel://\(digits)")
    }

    static func messageURL(for phone: String) -> URL? {
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard digits.count >= 7 else { return nil }
        return URL(string: "sms://\(digits)")
    }

    static func mailURL(for email: String, subject: String = "") -> URL? {
        guard let cleaned = email.trimmedOrNil else { return nil }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = cleaned
        if let subject = subject.trimmedOrNil {
            components.queryItems = [URLQueryItem(name: "subject", value: subject)]
        }
        return components.url
    }

    /// Opens Maps at the contact, preferring coordinates over the address
    /// string — coordinates are what we actually captured on the doorstep, and
    /// they are right even when the address is not.
    static func mapsURL(for contact: Contact) -> URL? {
        if let coordinate = contact.coordinate {
            var components = URLComponents(string: "https://maps.apple.com/")
            components?.queryItems = [
                URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                URLQueryItem(name: "q", value: contact.displayName),
            ]
            return components?.url
        }
        let address = [contact.streetLine, contact.cityStateZipLine]
            .compactMap { $0.trimmedOrNil }
            .joined(separator: ", ")
        guard let address = address.trimmedOrNil else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "address", value: address)]
        return components?.url
    }
}
