//
//  Organization.swift
//  FieldForge
//
//  The nonprofit itself: the letterhead, the EIN, the signature, and the
//  document numbering counters. Everything the document engine needs to make a
//  PDF that looks like it came out of a real office.
//
//  SwiftData + CloudKit constraints observed by every model in this folder:
//    * no `.unique` attributes (CloudKit cannot enforce uniqueness),
//    * every stored property has a default value,
//    * every relationship is optional or an array with an explicit inverse.
//  Break any of those and the CloudKit-backed container refuses to load.
//

import Foundation
import SwiftData
import SwiftUI

@Model
final class Organization {

    // MARK: Identity

    var id: UUID = UUID()

    /// Name as it should appear on letterhead — "Riverside Food Collective".
    var name: String = ""

    /// Registered legal name, when it differs from the name people know. The
    /// letter footer shows this because the IRS cares about the legal entity.
    var legalName: String = ""

    /// Employer Identification Number, formatted "12-3456789". Printed on both
    /// document types; a donation acknowledgment without it is worth less to
    /// the donor's accountant.
    var ein: String = ""

    /// Whether to print 501(c)(3) deductibility language. A fiscally sponsored
    /// project or a 501(c)(4) must be able to turn this off — printing
    /// "tax deductible" when it is not would be a real problem for the donor.
    var is501c3: Bool = true

    /// Free-text line naming the fiscal sponsor, printed under the EIN when
    /// set. Fiscally sponsored projects receipt under the sponsor's EIN.
    var fiscalSponsorNote: String = ""

    // MARK: Contact block (prints in the letterhead)

    var addressLine1: String = ""
    var addressLine2: String = ""
    var city: String = ""
    var state: String = ""
    var postalCode: String = ""
    var country: String = "United States"
    var phone: String = ""
    var email: String = ""
    var website: String = ""

    // MARK: Branding

    /// PNG or JPEG logo. Kept out of the row store because it can be large and
    /// is only read when rendering a PDF or the settings preview.
    @Attribute(.externalStorage) var logoData: Data?

    /// Hex string like "#1F5F5B". Drives rules, the header band, and totals
    /// emphasis in both PDF templates. Stored as a string so it round-trips
    /// through CloudKit without a custom transformer.
    var brandColorHex: String = "#1F5F5B"

    /// One-line positioning statement under the logo, e.g. "Feeding neighbours
    /// since 1998". Optional; the letterhead collapses cleanly without it.
    var letterheadTagline: String = ""

    /// Printed small at the bottom of every page. Pro tier; the free tier gets
    /// the org name and EIN, which is all the IRS requires.
    var letterFooterNote: String = ""

    /// `true` prints the letterhead as a full-width colour band with reversed
    /// text; `false` prints a restrained rule under black text. Both look like
    /// a real office, they just suit different brands.
    ///
    /// Kept for compatibility with documents issued before `letterheadStyle`
    /// existed; new code should read that instead.
    var usesColorBandLetterhead: Bool = false

    /// Raw storage for the enum below. Internal rather than private so
    /// `#Predicate` and SwiftUI's `onChange` in other files can observe it.
    /// Empty by default, deliberately. SwiftData's lightweight migration gives
    /// existing rows the declared default, so defaulting this to `classic`
    /// would silently strip the colour band from every organization that had
    /// already chosen it. Empty means "never set", and the getter then falls
    /// back to the old boolean.
    var letterheadStyleRawValue: String = ""
    /// How the top of the page is built. Four genuinely different looks rather
    /// than a slider, because a nonprofit picking a letterhead wants to choose
    /// between finished designs, not tune one.
    var letterheadStyle: LetterheadStyle {
        get {
            // Honour the old boolean for organizations that set it before the
            // style enum existed.
            if let stored = LetterheadStyle(rawValue: letterheadStyleRawValue) { return stored }
            return usesColorBandLetterhead ? .colorBand : .classic
        }
        set {
            letterheadStyleRawValue = newValue.rawValue
            usesColorBandLetterhead = (newValue == .colorBand)
        }
    }

    /// Raw storage for the enum below. Internal rather than private so
    /// `#Predicate` and SwiftUI's `onChange` in other files can observe it.
    var typefaceRawValue: String = DocumentTypeface.serif.rawValue
    /// The type family for document body text. Restricted to the four font
    /// *designs* that ship with iOS — a real custom font would need a licence
    /// the app cannot grant, and a missing font file at render time would be a
    /// blank receipt.
    var typeface: DocumentTypeface {
        get { DocumentTypeface(rawValue: typefaceRawValue) ?? .serif }
        set { typefaceRawValue = newValue.rawValue }
    }

    /// Raw storage for the enum below. Internal rather than private so
    /// `#Predicate` and SwiftUI's `onChange` in other files can observe it.
    var footerStyleRawValue: String = FooterStyle.legalMinimum.rawValue
    /// What prints at the very bottom of every page.
    var footerStyle: FooterStyle {
        get { FooterStyle(rawValue: footerStyleRawValue) ?? .legalMinimum }
        set { footerStyleRawValue = newValue.rawValue }
    }

    /// Mission or tagline line for the footer, when `footerStyle` includes it.
    var missionStatement: String = ""

    /// Prints in-kind item photos into the acknowledgment letter. Off by
    /// default: a letter is a formal document and photographs change its
    /// character, so this is a deliberate choice rather than a surprise.
    var includesInKindPhotosInLetter: Bool = false

    // MARK: Signature

    /// Who signs the acknowledgment letters by default.
    var signatoryName: String = ""
    var signatoryTitle: String = ""

    /// A signature captured once in Settings and reused, so a staffer is not
    /// asked to sign with a fingertip forty times a day. Individual documents
    /// can still carry their own freshly captured signature.
    @Attribute(.externalStorage) var defaultSignatureData: Data?

    // MARK: Document numbering

    /// Human-readable prefixes. Kept short so document numbers stay readable
    /// when read aloud over a phone.
    var receiptPrefix: String = "RCT"
    var letterPrefix: String = "ACK"

    /// Counters, scoped to `sequenceYear`. Reset automatically on the first
    /// document of a new calendar year — see `DocumentNumberer`.
    var nextReceiptSequence: Int = 1
    var nextLetterSequence: Int = 1
    var sequenceYear: Int = Calendar.current.component(.year, from: .now)

    /// Two-character tag unique to this install, appended to document numbers
    /// only when shared team memory is on. Without it, two staffers offline in
    /// different neighbourhoods would both mint "RCT-2026-0042".
    var deviceTag: String = Organization.makeDeviceTag()

    // MARK: Defaults for new gifts

    var defaultCurrencyCode: String = Locale.current.currency?.identifier ?? "USD"

    /// The fund or campaign a gift is attributed to unless changed.
    var defaultFundName: String = "General Fund"

    /// Whether in-kind letters may print a donor-supplied estimated value.
    /// Off by default, and deliberately so: the safest practice is to describe
    /// the property and let the donor value it. See `TaxLanguage`.
    var printsDonorEstimatedValueOnInKind: Bool = false

    /// Appended verbatim to the tax paragraph on every letter. For the
    /// state-specific sentence a nonprofit's counsel asks for.
    var customTaxNote: String = ""

    // MARK: Bookkeeping

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// Most nonprofits have one of these. A fiscal sponsor or a consultant
    /// working across several has more, and switches between them.
    var isActive: Bool = true

    // MARK: Relationships

    @Relationship(deleteRule: .cascade, inverse: \Contact.organization)
    var contacts: [Contact]? = []

    @Relationship(deleteRule: .cascade, inverse: \Gift.organization)
    var gifts: [Gift]? = []

    @Relationship(deleteRule: .cascade, inverse: \GeneratedDocument.organization)
    var documents: [GeneratedDocument]? = []

    init(
        name: String = "",
        ein: String = "",
        city: String = "",
        state: String = ""
    ) {
        self.name = name
        self.ein = ein
        self.city = city
        self.state = state
    }

    // MARK: Derived values used by the PDF renderers

    /// Name to print in the legal/footer position.
    var printableLegalName: String {
        legalName.trimmedOrNil ?? name
    }

    /// "128 River Street, Suite 3" — the street portion on one line.
    var streetLine: String {
        [addressLine1, addressLine2]
            .compactMap { $0.trimmedOrNil }
            .joined(separator: ", ")
    }

    /// "Rockford, IL 61101"
    var cityStateZipLine: String {
        let cityState = [city.trimmedOrNil, state.trimmedOrNil]
            .compactMap { $0 }
            .joined(separator: ", ")
        return [cityState.trimmedOrNil, postalCode.trimmedOrNil]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// The letterhead contact block, already ordered and de-blanked.
    var letterheadLines: [String] {
        [streetLine, cityStateZipLine, phone, email, website]
            .compactMap { $0.trimmedOrNil }
    }

    /// "EIN 12-3456789" or "" when the org has not entered one yet. The
    /// document engine surfaces the omission as a warning rather than silently
    /// producing a weaker acknowledgment.
    var einLine: String {
        guard let ein = ein.trimmedOrNil else { return "" }
        return "EIN \(ein)"
    }

    var brandColor: Color {
        Color(hex: brandColorHex) ?? Color("BrandDefault")
    }

    /// Everything the renderers require. The document step refuses to render
    /// until this is empty, because a receipt with no organization name on it
    /// is worse than no receipt.
    var missingRequiredBrandingFields: [String] {
        var missing: [String] = []
        if name.trimmedOrNil == nil { missing.append("Organization name") }
        if streetLine.isEmpty && cityStateZipLine.isEmpty { missing.append("Mailing address") }
        if ein.trimmedOrNil == nil && is501c3 { missing.append("EIN") }
        if signatoryName.trimmedOrNil == nil { missing.append("Who signs letters") }
        return missing
    }

    /// Non-blocking suggestions shown as a nudge in Settings.
    var brandingSuggestions: [String] {
        var suggestions: [String] = []
        if logoData == nil { suggestions.append("Add a logo — branded documents get read.") }
        if defaultSignatureData == nil { suggestions.append("Save a signature so you are not drawing one at every door.") }
        if email.trimmedOrNil == nil { suggestions.append("Add a reply-to email address.") }
        return suggestions
    }

    var isReadyToIssueDocuments: Bool { missingRequiredBrandingFields.isEmpty }

    // MARK: Helpers

    /// Two upper-case characters derived from a fresh UUID. Not a secret and
    /// not a device identifier Apple would object to — just a tiebreaker.
    static func makeDeviceTag() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")  // no I/O/0/1
        return String((0..<2).map { _ in alphabet.randomElement() ?? "X" })
    }

    func touch() { updatedAt = .now }
}

// MARK: - Small string conveniences used across the models

extension String {
    /// `nil` when the string is empty or only whitespace, the trimmed value
    /// otherwise. Used everywhere a blank field must not print as a blank line.
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    var trimmedOrNil: String? { self?.trimmedOrNil }
}
