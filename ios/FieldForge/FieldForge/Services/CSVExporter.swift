//
//  CSVExporter.swift
//  FieldForge
//
//  Bulk CSV export of contacts, gifts and issued documents.
//
//  The destination for these files is a finance system or a spreadsheet
//  somebody's board treasurer opens, which means the CSV has to be *actually*
//  correct rather than approximately correct. So:
//
//    * **RFC 4180 quoting**, properly. A donor named `O'Brien & Sons, Inc.`
//      and a note containing a newline and a quotation mark both have to
//      survive. Getting this wrong shifts every column after it and quietly
//      corrupts a finance import, which is far worse than failing outright.
//    * **CRLF line endings**, which RFC 4180 specifies and which Excel on
//      Windows still cares about.
//    * **A UTF-8 BOM.** Without it, Excel on Windows opens a UTF-8 CSV as
//      Latin-1 and turns every accented donor name into mojibake. This is the
//      single most common complaint about exported CSVs.
//    * **Amounts as plain decimal numbers**, never currency-formatted. `$1,250.00`
//      imports as text; `1250.00` imports as a number you can sum.
//    * **ISO 8601 dates**, for the same reason.
//
//  Private notes are never exported to a shared destination — see
//  `Scope.includesPrivateNotes`.
//

import Foundation
import SwiftData

// MARK: - Writer

/// A minimal, correct CSV writer.
///
/// Deliberately not a general-purpose library: it does one thing, and the one
/// thing it does is the part that gets silently wrong elsewhere.
struct CSVWriter {

    private var rows: [String] = []
    private let separator = ","
    /// RFC 4180 says CRLF. Excel on Windows agrees.
    private let lineEnding = "\r\n"

    init(header: [String]) {
        rows.append(Self.encode(row: header))
    }

    mutating func append(_ values: [String]) {
        rows.append(Self.encode(row: values))
    }

    /// The finished file, BOM-prefixed so Excel reads it as UTF-8.
    var data: Data {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let body = rows.joined(separator: lineEnding) + lineEnding
        return bom + Data(body.utf8)
    }

    var rowCount: Int { max(0, rows.count - 1) }

    // MARK: Field encoding

    static func encode(row: [String]) -> String {
        row.map(encode(field:)).joined(separator: ",")
    }

    /// Quotes a field when it has to be quoted, and doubles any quote inside.
    ///
    /// A field needs quoting if it contains a comma, a quote, a CR or an LF.
    /// Leading or trailing whitespace is also quoted, because some parsers trim
    /// unquoted fields and a donor whose name really does end in a space should
    /// come back the same way.
    static func encode(field: String) -> String {
        let needsQuoting = field.contains(",")
            || field.contains("\"")
            || field.contains("\n")
            || field.contains("\r")
            || field.hasPrefix(" ")
            || field.hasSuffix(" ")

        guard needsQuoting else { return field }
        let escaped = field.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

// MARK: - Value formatting

private extension CSVExporter {

    /// ISO 8601, date only. A finance import wants `2026-04-13`, not
    /// "13 April 2026" and not a locale-dependent slash format.
    static func csvDate(_ date: Date?) -> String {
        guard let date else { return "" }
        return isoDateFormatter.string(from: date)
    }

    static func csvDateTime(_ date: Date?) -> String {
        guard let date else { return "" }
        return isoDateTimeFormatter.string(from: date)
    }

    /// A plain decimal, so the column sums. Never a currency symbol.
    ///
    /// The sign is applied to the whole string rather than to the integer part:
    /// `-50` minor units has a whole part of `0`, so formatting the parts
    /// separately would silently turn minus fifty cents into plus fifty.
    static func csvAmount(_ money: Money) -> String {
        let sign = money.minorUnits < 0 ? "-" : ""
        let magnitude = abs(money.minorUnits)
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }

    static func csvBool(_ value: Bool) -> String { value ? "yes" : "no" }

    static let isoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let isoDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter
    }()
}

// MARK: - Exporter

@MainActor
struct CSVExporter {

    /// What the export is for, which decides whether private notes are in it.
    enum Scope: Hashable, CaseIterable {
        /// The staffer's own backup or their own spreadsheet. Everything.
        case personal
        /// A file going to a finance office, a board, or a grant report.
        /// Excludes private notes.
        case organizational

        /// Private notes are for one person. An export destined for anyone else
        /// must not contain them, and the picker says so before the file exists.
        var includesPrivateNotes: Bool { self == .personal }

        var label: String {
            switch self {
            case .personal: return "For me"
            case .organizational: return "For the organization"
            }
        }

        var explanation: String {
            switch self {
            case .personal:
                return "Includes your private notes. Keep this file to yourself."
            case .organizational:
                return "Excludes your private notes. Safe to hand to finance or a board."
            }
        }
    }

    /// One produced file.
    struct File: Identifiable {
        let name: String
        let data: Data
        let rowCount: Int
        var id: String { name }

        var formattedSize: String {
            Int64(data.count).formatted(.byteCount(style: .file))
        }
    }

    let context: ModelContext
    let organization: Organization
    let scope: Scope

    // MARK: Contacts

    func exportContacts() throws -> File {
        var header = [
            "contact_id", "name", "kind", "contact_person", "contact_person_title",
            "phone", "email",
            "address_line_1", "address_line_2", "city", "state", "postal_code", "country",
            "latitude", "longitude",
            "warmth", "warmth_score", "best_time_to_contact",
            "do_not_contact", "do_not_contact_reason",
            "tags",
            "visit_count", "gift_count", "lifetime_giving", "currency",
            "first_gift_date", "last_gift_date", "last_visit_date",
            "shared_with_team", "team_notes",
            "source", "created_by", "created_at", "updated_at",
        ]
        if scope.includesPrivateNotes { header.append("private_notes") }

        var writer = CSVWriter(header: header)

        let descriptor = FetchDescriptor<Contact>(
            predicate: #Predicate { $0.isArchived == false },
            sortBy: [SortDescriptor(\.nameSortKey)]
        )
        for contact in try context.fetch(descriptor) {
            var row = [
                contact.id.uuidString,
                contact.displayName,
                contact.kind.label,
                contact.contactPersonName,
                contact.contactPersonTitle,
                contact.phone,
                contact.email,
                contact.addressLine1,
                contact.addressLine2,
                contact.city,
                contact.state,
                contact.postalCode,
                contact.country,
                contact.latitude.map { String($0) } ?? "",
                contact.longitude.map { String($0) } ?? "",
                contact.warmth.label,
                String(contact.warmth.rawValue),
                contact.contactWindow == .unknown ? "" : contact.contactWindow.label,
                Self.csvBool(contact.isDoNotContact),
                contact.doNotContactReason,
                // Semicolons inside the cell, so the comma stays the column
                // separator and a spreadsheet does not need re-splitting.
                contact.tags.joined(separator: "; "),
                String(contact.visitCount),
                String(contact.giftCount),
                Self.csvAmount(contact.lifetimeGiving),
                contact.lifetimeGiving.currencyCode,
                Self.csvDate(contact.firstGiftAt),
                Self.csvDate(contact.lastGiftAt),
                Self.csvDate(contact.lastVisitAt),
                Self.csvBool(contact.isSharedWithTeam),
                contact.sharedNotes,
                contact.source.label,
                contact.createdByDisplayName,
                Self.csvDate(contact.createdAt),
                Self.csvDate(contact.updatedAt),
            ]
            if scope.includesPrivateNotes { row.append(contact.privateNotes) }
            writer.append(row)
        }

        return File(
            name: fileName(for: "contacts"),
            data: writer.data,
            rowCount: writer.rowCount
        )
    }

    // MARK: Gifts

    /// The donation history. This is the export a finance office actually wants,
    /// so it is the widest of the three and every amount is a plain number.
    func exportGifts() throws -> File {
        var writer = CSVWriter(header: [
            "gift_id", "date_received", "contact_id", "contact_name",
            "amount", "currency", "deductible_amount",
            "method", "reference_number", "card_description", "transaction_id",
            "payment_confirmed",
            "fund", "is_in_kind", "in_kind_description", "in_kind_quantity",
            "donor_estimated_value",
            "goods_or_services_provided", "goods_or_services_description",
            "goods_or_services_value",
            "anonymous", "voided", "void_reason",
            "counts_toward_giving",
            "document_numbers",
            "recorded_by", "notes",
        ])

        let descriptor = FetchDescriptor<Gift>(
            sortBy: [SortDescriptor(\.receivedAt, order: .reverse)]
        )
        for gift in try context.fetch(descriptor) {
            let documentNumbers = (gift.documents ?? [])
                .sorted { $0.issuedAt < $1.issuedAt }
                .map(\.documentNumber)
                .joined(separator: "; ")

            writer.append([
                gift.id.uuidString,
                Self.csvDate(gift.receivedAt),
                gift.contact?.id.uuidString ?? "",
                gift.contact?.displayName ?? "",
                Self.csvAmount(gift.amount),
                gift.currencyCode,
                Self.csvAmount(gift.deductibleAmount),
                gift.method.label,
                gift.referenceNumber,
                gift.paymentInstrumentDescription,
                gift.transactionIdentifier,
                Self.csvBool(gift.isPaymentConfirmed),
                gift.fundName,
                Self.csvBool(gift.isInKind),
                gift.inKindDescription,
                gift.inKindQuantity > 0 ? String(gift.inKindQuantity) : "",
                gift.donorEstimatedValueMinorUnits > 0
                    ? Self.csvAmount(gift.donorEstimatedValue)
                    : "",
                Self.csvBool(gift.providedGoodsOrServices),
                gift.goodsOrServicesDescription,
                gift.providedGoodsOrServices
                    ? Self.csvAmount(gift.goodsOrServicesValue)
                    : "",
                Self.csvBool(gift.isAnonymousDonor),
                Self.csvBool(gift.isVoided),
                gift.voidReason,
                Self.csvBool(gift.countsTowardGiving),
                documentNumbers,
                gift.recordedByDisplayName,
                gift.notes,
            ])
        }

        return File(
            name: fileName(for: "donations"),
            data: writer.data,
            rowCount: writer.rowCount
        )
    }

    // MARK: Documents

    /// The issued-document register, including voided and superseded copies —
    /// the whole point of an audit trail is that nothing is quietly omitted.
    func exportDocuments() throws -> File {
        var writer = CSVWriter(header: [
            "document_number", "kind", "revision", "issued_at",
            "recipient_name", "recipient_email",
            "amount", "currency", "deductible_amount",
            "gift_date", "method", "fund", "in_kind_description",
            "delivery_state", "sent_at", "delivery_channel",
            "voided", "void_reason", "supersedes",
            "checksum", "issued_by",
        ])

        let descriptor = FetchDescriptor<GeneratedDocument>(
            sortBy: [SortDescriptor(\.issuedAt, order: .reverse)]
        )
        for document in try context.fetch(descriptor) {
            writer.append([
                document.documentNumber,
                document.kind.longLabel,
                String(document.revision),
                Self.csvDateTime(document.issuedAt),
                document.recipientName,
                document.recipientEmail,
                Self.csvAmount(document.amount),
                document.currencyCode,
                Self.csvAmount(document.deductibleAmount),
                Self.csvDate(document.giftDate),
                document.giftMethodLabel,
                document.fundName,
                document.inKindDescription,
                document.deliveryState.label,
                Self.csvDateTime(document.sentAt),
                document.deliveryChannel,
                Self.csvBool(document.isVoided),
                document.voidReason,
                document.supersedes?.documentNumber ?? "",
                document.pdfChecksum,
                document.createdByDisplayName,
            ])
        }

        return File(
            name: fileName(for: "documents"),
            data: writer.data,
            rowCount: writer.rowCount
        )
    }

    // MARK: All three

    func exportAll() throws -> [File] {
        [try exportContacts(), try exportGifts(), try exportDocuments()]
    }

    // MARK: Files on disk

    /// Writes the files into a temporary directory and returns their URLs, for
    /// the share sheet. Named so a spreadsheet in a downloads folder six months
    /// from now still identifies itself.
    func write(_ files: [File]) throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "FieldForge-Export", directoryHint: .isDirectory)
        // Clear any previous export, so a share sheet never offers a stale file
        // alongside a fresh one.
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return try files.map { file in
            let url = directory.appending(path: file.name)
            try file.data.write(to: url, options: [.atomic])
            return url
        }
    }

    /// Deletes staged exports. Called when the export screen disappears — a
    /// temporary directory full of donor data should not outlive its use.
    static func clearStagedExports() {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FieldForge-Export")
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileName(for kind: String) -> String {
        let stamp = DateFormatter.fileStamp.string(from: .now)
        let orgSlug = organization.name
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        let stem = [orgSlug.trimmedOrNil, kind, stamp]
            .compactMap { $0 }
            .joined(separator: "-")
        return "\(stem).csv"
    }
}
