//
//  ContactParser.swift
//  FieldForge
//
//  Turning a pile of OCR'd lines into a contact record.
//
//  This is heuristics, and it says so. The goal is not perfection: it is to
//  save four out of five keystrokes and then get out of the way. Every parsed
//  field lands in an editable form marked "scanned — check this", and the
//  parser deliberately prefers leaving a field blank over guessing wrong,
//  because a wrong address on a tax letter is worse than an empty one.
//

import Contacts
import Foundation

struct ParsedContactCandidate {
    var name: String = ""
    var personName: String = ""
    var personTitle: String = ""
    var phone: String = ""
    var email: String = ""
    var website: String = ""
    var addressLine1: String = ""
    var city: String = ""
    var state: String = ""
    var postalCode: String = ""

    /// Lines the parser could not place. Shown to the staffer so nothing the
    /// camera read is silently thrown away.
    var unmatchedLines: [String] = []

    var isUsable: Bool { name.trimmedOrNil != nil || personName.trimmedOrNil != nil }

    /// Fills a draft's contact fields. Never overwrites something already typed.
    func apply(to fields: inout DocumentDraft.NewContactFields, source: ContactSource) {
        if fields.name.trimmedOrNil == nil { fields.name = name }
        if fields.contactPersonName.trimmedOrNil == nil { fields.contactPersonName = personName }
        if fields.contactPersonTitle.trimmedOrNil == nil { fields.contactPersonTitle = personTitle }
        if fields.phone.trimmedOrNil == nil { fields.phone = phone }
        if fields.email.trimmedOrNil == nil { fields.email = email }
        if fields.addressLine1.trimmedOrNil == nil { fields.addressLine1 = addressLine1 }
        if fields.city.trimmedOrNil == nil { fields.city = city }
        if fields.state.trimmedOrNil == nil { fields.state = state }
        if fields.postalCode.trimmedOrNil == nil { fields.postalCode = postalCode }
        fields.source = source
    }
}

enum ContactParser {

    /// Parses OCR output from a **shop sign or awning**.
    ///
    /// The heuristic: the largest text in the frame is the business name. This
    /// works because signage is designed to be read from across a street, so
    /// the name is genuinely the biggest thing on it.
    static func parseSign(_ blocks: [RecognizedTextBlock]) -> ParsedContactCandidate {
        var candidate = ParsedContactCandidate()
        guard !blocks.isEmpty else { return candidate }

        let usable = blocks.filter { $0.confidence > 0.3 && $0.text.trimmedOrNil != nil }
        guard !usable.isEmpty else { return candidate }

        // Name: tallest block that is not obviously a phone number, a URL, or
        // opening hours.
        let nameCandidates = usable
            .filter { !looksLikePhone($0.text) && !looksLikeURL($0.text) && !looksLikeHours($0.text) }
            .sorted { $0.relativeHeight > $1.relativeHeight }
        if let best = nameCandidates.first {
            candidate.name = tidyBusinessName(best.text)
        }

        let allText = usable.map(\.text).joined(separator: "\n")
        applyDetectors(to: &candidate, text: allText)

        // Anything left that we did not use, kept for the staffer to see. The
        // camera read it, so it should never silently vanish.
        let claimed = [candidate.name, candidate.phone, candidate.email, candidate.website]
            .compactMap { $0.trimmedOrNil }
        candidate.unmatchedLines = usable
            .map(\.text)
            .filter { line in
                !claimed.contains { line.localizedCaseInsensitiveContains($0) }
            }

        return candidate
    }

    /// Parses a **business card**, where the layout conventions are different:
    /// the person's name is usually near the top and the largest text is often
    /// the company logo type.
    static func parseBusinessCard(_ blocks: [RecognizedTextBlock]) -> ParsedContactCandidate {
        var candidate = ParsedContactCandidate()
        let usable = blocks.filter { $0.confidence > 0.3 && $0.text.trimmedOrNil != nil }
        guard !usable.isEmpty else { return candidate }

        let allText = usable.map(\.text).joined(separator: "\n")
        applyDetectors(to: &candidate, text: allText)

        // Top-to-bottom. Vision's y origin is at the bottom, so descending y is
        // reading order.
        let ordered = usable.sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }

        // A job title is the strongest anchor on a card: the line above it is
        // almost always the person, and a line with a company suffix is the org.
        if let titleIndex = ordered.firstIndex(where: { looksLikeJobTitle($0.text) }) {
            candidate.personTitle = ordered[titleIndex].text.trimmingCharacters(in: .whitespaces)
            if titleIndex > 0, looksLikePersonName(ordered[titleIndex - 1].text) {
                candidate.personName = ordered[titleIndex - 1].text.trimmingCharacters(in: .whitespaces)
            }
        }

        if candidate.personName.isEmpty {
            candidate.personName = ordered
                .prefix(3)
                .first { looksLikePersonName($0.text) }?
                .text
                .trimmingCharacters(in: .whitespaces) ?? ""
        }

        // Company: a line with a corporate suffix, else the tallest line that
        // is not the person.
        if let company = ordered.first(where: { hasCompanySuffix($0.text) }) {
            candidate.name = tidyBusinessName(company.text)
        } else if let tallest = usable
            .filter({ $0.text != candidate.personName && !looksLikeJobTitle($0.text) && !looksLikePhone($0.text) && !looksLikeURL($0.text) })
            .max(by: { $0.relativeHeight < $1.relativeHeight }) {
            candidate.name = tidyBusinessName(tallest.text)
        }

        // Fall back to the email's domain, which is often the only reliable
        // clue on a minimalist card.
        if candidate.name.isEmpty, let host = candidate.email.split(separator: "@").last {
            let stem = host.split(separator: ".").first.map(String.init) ?? ""
            if !["gmail", "yahoo", "hotmail", "outlook", "icloud", "aol", "proton"].contains(stem.lowercased()) {
                candidate.name = stem.capitalized
            }
        }

        return candidate
    }

    /// Imports from the system Contacts framework — no guessing required.
    static func parse(_ contact: CNContact) -> ParsedContactCandidate {
        var candidate = ParsedContactCandidate()
        candidate.personName = CNContactFormatter.string(from: contact, style: .fullName) ?? ""
        candidate.name = contact.organizationName.trimmedOrNil ?? candidate.personName
        candidate.personTitle = contact.jobTitle
        candidate.phone = contact.phoneNumbers.first?.value.stringValue ?? ""
        candidate.email = (contact.emailAddresses.first?.value as? String) ?? ""

        if let address = contact.postalAddresses.first?.value {
            candidate.addressLine1 = address.street.components(separatedBy: "\n").first ?? address.street
            candidate.city = address.city
            candidate.state = address.state
            candidate.postalCode = address.postalCode
        }
        return candidate
    }

    // MARK: - Detectors

    /// `NSDataDetector` for phone numbers, emails, URLs, and addresses. Apple's
    /// detector is far better at this than any regex worth maintaining.
    private static func applyDetectors(to candidate: inout ParsedContactCandidate, text: String) {
        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .link, .address]
        guard let detector = try? NSDataDetector(types: types.rawValue) else { return }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        detector.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            switch match.resultType {
            case .phoneNumber:
                if candidate.phone.isEmpty, let number = match.phoneNumber {
                    candidate.phone = number
                }
            case .link:
                guard let url = match.url else { return }
                if url.scheme == "mailto" {
                    if candidate.email.isEmpty {
                        candidate.email = url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                    }
                } else if candidate.website.isEmpty {
                    candidate.website = url.absoluteString
                }
            case .address:
                let components = match.addressComponents ?? [:]
                if candidate.addressLine1.isEmpty {
                    candidate.addressLine1 = components[.street] ?? ""
                }
                if candidate.city.isEmpty { candidate.city = components[.city] ?? "" }
                if candidate.state.isEmpty { candidate.state = components[.state] ?? "" }
                if candidate.postalCode.isEmpty { candidate.postalCode = components[.zip] ?? "" }
            default:
                break
            }
        }

        // The address detector misses a bare email with no mailto:, which is
        // most of them.
        if candidate.email.isEmpty {
            candidate.email = firstEmail(in: text) ?? ""
        }
    }

    private static func firstEmail(in text: String) -> String? {
        // Intentionally conservative: matches the shapes people actually print,
        // and rejects anything it is unsure about.
        let pattern = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let matchRange = Range(match.range, in: text) else { return nil }
        return String(text[matchRange]).lowercased()
    }

    // MARK: - Shape tests

    private static let companySuffixes = [
        "inc", "inc.", "llc", "l.l.c.", "ltd", "ltd.", "co", "co.", "corp", "corp.",
        "company", "gmbh", "plc", "pllc", "lp", "llp", "pc", "&", "and sons", "group",
        "associates", "partners", "holdings",
    ]

    private static let jobTitleWords = [
        "owner", "manager", "director", "president", "vice", "vp", "ceo", "cfo", "coo",
        "founder", "principal", "partner", "agent", "broker", "chef", "proprietor",
        "supervisor", "coordinator", "administrator", "head", "chair", "pastor",
        "reverend", "rev", "superintendent", "controller", "treasurer",
    ]

    static func hasCompanySuffix(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "." && $0 != "&" })
        return words.contains { companySuffixes.contains(String($0)) }
    }

    static func looksLikeJobTitle(_ text: String) -> Bool {
        let lowered = text.lowercased()
        guard text.count < 48 else { return false }
        return jobTitleWords.contains { lowered.contains($0) }
    }

    /// Two or three capitalised words, no digits, not a company. Crude, and
    /// deliberately so — the cost of a false positive is one tap to correct.
    static func looksLikePersonName(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 42 else { return false }
        guard !trimmed.contains(where: \.isNumber) else { return false }
        guard !hasCompanySuffix(trimmed), !looksLikeJobTitle(trimmed) else { return false }
        let words = trimmed.split(separator: " ")
        guard (2...4).contains(words.count) else { return false }
        // At least two words starting with a capital.
        let capitalised = words.filter { $0.first?.isUppercase == true }
        return capitalised.count >= 2
    }

    static func looksLikePhone(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return digits.count >= 7 && Double(digits.count) / Double(max(text.count, 1)) > 0.4
    }

    static func looksLikeURL(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("www.") || lowered.contains("http")
            || (lowered.contains(".com") && !lowered.contains("@"))
            || lowered.contains(".org") || lowered.contains(".net")
    }

    /// "MON-FRI 9-5", "OPEN 24 HOURS", "CLOSED SUNDAYS" — never a business name.
    static func looksLikeHours(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let markers = ["mon", "tue", "wed", "thu", "fri", "sat", "sun", "open", "closed", "hours", "am", "pm"]
        let hits = markers.filter { lowered.contains($0) }.count
        return hits >= 2 || (lowered.contains("open") && text.contains(where: \.isNumber))
    }

    /// Signs are set in all caps. "DELGADO HARDWARE" becomes "Delgado Hardware",
    /// while a name that is already mixed case is left exactly as printed.
    static func tidyBusinessName(_ text: String) -> String {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "•·|-–—*"))
            .trimmingCharacters(in: .whitespaces)
        guard trimmed.count > 2 else { return trimmed }

        let letters = trimmed.filter(\.isLetter)
        let uppercaseRatio = letters.isEmpty
            ? 0
            : Double(letters.filter(\.isUppercase).count) / Double(letters.count)
        guard uppercaseRatio > 0.85 else { return trimmed }

        // Capitalise, then restore the small words and the ampersand style that
        // `capitalized` gets wrong.
        let lowerWords: Set<String> = ["and", "or", "of", "the", "a", "an", "for", "at", "in", "on", "to", "by"]
        return trimmed
            .lowercased()
            .split(separator: " ")
            .enumerated()
            .map { index, word in
                let string = String(word)
                if index > 0, lowerWords.contains(string) { return string }
                return string.capitalizedFirst
            }
            .joined(separator: " ")
    }
}
