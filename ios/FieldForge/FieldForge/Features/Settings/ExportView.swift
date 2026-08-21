//
//  ExportView.swift
//  FieldForge
//
//  Bulk CSV export.
//
//  Two decisions shape this screen. First, the scope picker comes *before* the
//  export button rather than after, because whether private notes are in the
//  file is the most consequential choice here and it should not be something
//  discovered afterwards. Second, the row counts are shown before sharing, so
//  a staffer who expected 400 donors and sees 4 knows something is wrong while
//  the file is still on their phone.
//

import SwiftData
import SwiftUI

struct ExportView: View {

    @Environment(\.appEnvironment) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var scope: CSVExporter.Scope = .organizational
    @State private var files: [CSVExporter.File] = []
    @State private var shareURLs: [URL] = []
    @State private var isExporting = false
    @State private var isPresentingShare = false
    @State private var errorMessage: String?

    private var isUnlocked: Bool { app.entitlements.isEnabled(.bulkExport) }

    var body: some View {
        List {
            if !isUnlocked {
                Section { LockedFeatureRow(feature: .bulkExport) }
            }

            scopeSection
            whatIsIncludedSection

            if let errorMessage {
                Section {
                    InlineBanner(kind: .critical, message: errorMessage)
                }
            }

            if !files.isEmpty {
                resultSection
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Export")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            ActionBar {
                PrimaryButton(
                    title: files.isEmpty ? "Create the files" : "Create them again",
                    systemImage: "tablecells",
                    isLoading: isExporting,
                    isEnabled: isUnlocked
                ) {
                    Task { await runExport() }
                }
                Text("Everything happens on this iPhone. Nothing is uploaded.")
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .sheet(isPresented: $isPresentingShare) {
            DocumentShareSheet(
                fileURLs: shareURLs,
                subject: "\(app.activeOrganization()?.name ?? "FieldForge") export"
            )
        }
        .onDisappear {
            // Staged CSVs hold the whole donor list. They should not outlive
            // the screen that made them.
            CSVExporter.clearStagedExports()
        }
    }

    // MARK: Scope

    private var scopeSection: some View {
        Section {
            Picker("Who is this for?", selection: $scope) {
                Text(CSVExporter.Scope.organizational.label)
                    .tag(CSVExporter.Scope.organizational)
                Text(CSVExporter.Scope.personal.label)
                    .tag(CSVExporter.Scope.personal)
            }
            .pickerStyle(.segmented)
            .onChange(of: scope) { _, _ in
                // The previous files were built for the other scope, so keeping
                // them on screen would invite sharing the wrong one.
                files = []
                shareURLs = []
            }

            Label(scope.explanation, systemImage: scope.includesPrivateNotes ? "lock.open" : "lock.fill")
                .font(Type.caption)
                .foregroundStyle(scope.includesPrivateNotes ? Palette.caution : Palette.positive)
        } header: {
            Text("Scope")
        } footer: {
            Text("This choice only affects your private notes. Everything else is in both versions.")
        }
    }

    // MARK: What is included

    private var whatIsIncludedSection: some View {
        Section {
            fileDescription(
                name: "contacts.csv",
                detail: "Every contact with warmth, giving totals, tags and dates."
            )
            fileDescription(
                name: "donations.csv",
                detail: "Every gift with amount, method, fund, in-kind detail and the documents issued for it."
            )
            fileDescription(
                name: "documents.csv",
                detail: "Every receipt and letter ever issued, including voided and re-issued copies."
            )
        } header: {
            Text("Three files")
        } footer: {
            Text("Amounts are plain numbers and dates are ISO 8601, so a spreadsheet can sum and sort them without cleanup. Encoded UTF-8 with a byte-order mark so Excel reads accented names correctly.")
        }
    }

    private func fileDescription(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(Type.body.weight(.medium))
                .monospaced()
            Text(detail)
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Result

    private var resultSection: some View {
        Section {
            ForEach(files) { file in
                HStack(spacing: Space.md) {
                    Image(systemName: "tablecells.fill")
                        .foregroundStyle(Palette.brand)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.name)
                            .font(Type.caption)
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                        // The row count is the check that matters: a staffer who
                        // expected 400 donors and sees 4 finds out here rather
                        // than in a board meeting.
                        Text("\(file.rowCount) row\(file.rowCount == 1 ? "" : "s") · \(file.formattedSize)")
                            .font(.caption2)
                            .foregroundStyle(Palette.textSecondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
            }

            Button {
                isPresentingShare = true
            } label: {
                Label("Share the files", systemImage: "square.and.arrow.up")
            }
            .disabled(shareURLs.isEmpty)
        } header: {
            Text("Ready")
        } footer: {
            if scope.includesPrivateNotes {
                Text("These files contain your private notes. Send them only to yourself.")
                    .foregroundStyle(Palette.caution)
            } else {
                Text("AirDrop, Mail, Files — anywhere. Your private notes are not in these files.")
            }
        }
    }

    // MARK: Running it

    private func runExport() async {
        guard let organization = app.activeOrganization() else {
            errorMessage = "Add your organization in Settings first."
            return
        }
        isExporting = true
        errorMessage = nil
        defer { isExporting = false }

        let exporter = CSVExporter(context: context, organization: organization, scope: scope)
        do {
            let produced = try exporter.exportAll()
            shareURLs = try exporter.write(produced)
            files = produced
            Haptics.success()
        } catch {
            Haptics.error()
            errorMessage = error.localizedDescription
            files = []
            shareURLs = []
        }
    }
}

#Preview("Export") {
    NavigationStack { ExportView() }
        .environment(\.appEnvironment, AppEnvironment.preview(tier: .team))
        .modelContainer(Persistence.previewContainer())
}
