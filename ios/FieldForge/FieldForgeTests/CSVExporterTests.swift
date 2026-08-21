//
//  CSVExporterTests.swift
//  FieldForgeTests
//
//  CSV correctness, which matters because the destination is a finance system.
//  A quoting bug shifts every column after it and quietly corrupts an import —
//  much worse than failing outright, because nobody notices until the numbers
//  are wrong in a board pack.
//

import Foundation
import SwiftData
import Testing
@testable import FieldForge

struct CSVWriterTests {

    @Test("Plain fields are not quoted")
    func plainFields() {
        #expect(CSVWriter.encode(field: "Delgado Hardware") == "Delgado Hardware")
        #expect(CSVWriter.encode(field: "250.00") == "250.00")
        #expect(CSVWriter.encode(field: "") == "")
    }

    @Test("Fields containing a separator or a quote are quoted correctly", arguments: [
        ("Delgado Hardware, Inc.", "\"Delgado Hardware, Inc.\""),
        ("She said \"yes\"", "\"She said \"\"yes\"\"\""),
        ("Line one\nLine two", "\"Line one\nLine two\""),
        ("Carriage\rreturn", "\"Carriage\rreturn\""),
        ("  padded  ", "\"  padded  \""),
    ])
    func quoting(input: String, expected: String) {
        #expect(CSVWriter.encode(field: input) == expected)
    }

    @Test("A row round-trips through a naive splitter only when it is safe to")
    func rowEncoding() {
        let row = CSVWriter.encode(row: ["a", "b,c", "d\"e"])
        #expect(row == "a,\"b,c\",\"d\"\"e\"")
    }

    @Test("The file carries a UTF-8 BOM and CRLF line endings")
    func fileShape() {
        var writer = CSVWriter(header: ["name", "amount"])
        writer.append(["Café Ubuntu", "250.00"])
        let data = writer.data

        // Without the BOM, Excel on Windows reads UTF-8 as Latin-1 and turns
        // every accented donor name into mojibake.
        #expect(data.prefix(3) == Data([0xEF, 0xBB, 0xBF]))

        let text = String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        #expect(text.contains("\r\n"), "RFC 4180 specifies CRLF")
        #expect(text.contains("Café Ubuntu"))
        #expect(text.hasSuffix("\r\n"))
        #expect(writer.rowCount == 1, "the header is not a data row")
    }

    @Test("A donor name with every awkward character survives intact")
    func adversarialName() {
        let nasty = "O'Brien & Sons, \"The Bakery\"\nUnit 3"
        var writer = CSVWriter(header: ["name"])
        writer.append([nasty])
        let text = String(data: writer.data.dropFirst(3), encoding: .utf8) ?? ""
        // Quoted as one field: exactly two quote characters bound it, and the
        // inner ones are doubled.
        #expect(text.contains("\"O'Brien & Sons, \"\"The Bakery\"\"\nUnit 3\""))
    }
}

@MainActor
struct CSVExporterTests {

    private func makeContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Persistence.schema,
            configurations: ModelConfiguration(schema: Persistence.schema, isStoredInMemoryOnly: true)
        )
    }

    private func seed(_ context: ModelContext) -> Organization {
        let organization = Organization(name: "Riverside Food Collective", ein: "36-4829107")
        organization.signatoryName = "Maritza Ocampo"
        organization.addressLine1 = "412 South Water Street"
        context.insert(organization)

        let contact = Contact(name: "Delgado Hardware, Inc.")
        contact.organization = organization
        contact.privateNotes = "SENTINEL-PRIVATE-NOTE"
        contact.sharedNotes = "Ana hosts the winter drive"
        contact.tags = ["main street", "matches gifts"]
        contact.contactWindow = .afternoon
        context.insert(contact)

        let gift = Gift(amount: Money(dollars: 250), method: .cash)
        gift.contact = contact
        gift.organization = organization
        gift.isPaymentConfirmed = true
        gift.fundName = "Winter Meals"
        context.insert(gift)

        contact.recomputeRollups()
        return organization
    }

    @Test("The organizational scope excludes private notes")
    func organizationalScopeIsSafeToShare() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = seed(context)
        try context.save()

        let exporter = CSVExporter(context: context, organization: organization, scope: .organizational)
        let file = try exporter.exportContacts()
        let text = String(data: file.data, encoding: .utf8) ?? ""

        #expect(!text.contains("SENTINEL-PRIVATE-NOTE"), "private notes reached an organizational export")
        #expect(!text.contains("private_notes"), "the column should not even exist")
        // The shareable content is still all there.
        #expect(text.contains("Delgado Hardware"))
        #expect(text.contains("Ana hosts the winter drive"))
        #expect(file.rowCount == 1)
    }

    @Test("The personal scope includes them, and says so")
    func personalScopeIncludesPrivateNotes() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = seed(context)
        try context.save()

        let exporter = CSVExporter(context: context, organization: organization, scope: .personal)
        let text = String(data: try exporter.exportContacts().data, encoding: .utf8) ?? ""
        #expect(text.contains("SENTINEL-PRIVATE-NOTE"))
        #expect(text.contains("private_notes"))

        #expect(CSVExporter.Scope.personal.includesPrivateNotes)
        #expect(!CSVExporter.Scope.organizational.includesPrivateNotes)
    }

    @Test("A name containing a comma does not shift the columns")
    func commaInNameDoesNotBreakColumns() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = seed(context)
        try context.save()

        let exporter = CSVExporter(context: context, organization: organization, scope: .organizational)
        let file = try exporter.exportContacts()
        let text = String(data: file.data.dropFirst(3), encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        // "Delgado Hardware, Inc." must be one quoted field, not two.
        #expect(lines[1].contains("\"Delgado Hardware, Inc.\""))
    }

    @Test("Amounts export as plain summable numbers, not currency strings")
    func amountsAreNumeric() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = seed(context)
        try context.save()

        let exporter = CSVExporter(context: context, organization: organization, scope: .organizational)
        let text = String(data: try exporter.exportGifts().data, encoding: .utf8) ?? ""
        #expect(text.contains("250.00"))
        // A currency symbol or a thousands separator makes the column import
        // as text, and then it will not sum.
        #expect(!text.contains("$250"))
        #expect(!text.contains("1,250"))
    }

    @Test("All three files are produced and named distinctly")
    func exportAll() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let organization = seed(context)
        try context.save()

        let exporter = CSVExporter(context: context, organization: organization, scope: .organizational)
        let files = try exporter.exportAll()
        #expect(files.count == 3)
        #expect(Set(files.map(\.name)).count == 3)
        for file in files {
            #expect(file.name.hasSuffix(".csv"))
            #expect(!file.name.contains(" "), "a filename with a space is awkward everywhere")
            #expect(file.data.count > 3, "\(file.name) is empty")
        }
    }
}
