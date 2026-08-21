//
//  VisitRow.swift
//  FieldForge
//
//  One line of history. Shared between Today's recent list and the contact
//  detail timeline, so a visit reads identically wherever it appears.
//

import SwiftUI

struct VisitRow: View {

    let visit: Visit
    var showsContactName: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: visit.outcome.symbolName)
                .font(.body)
                .foregroundStyle(visit.warmth == .unrated ? Palette.textTertiary : visit.warmth.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                if showsContactName {
                    Text(visit.contact?.displayName ?? "Unknown")
                        .font(Type.body.weight(.medium))
                        .foregroundStyle(Palette.textPrimary)
                }
                Text(visit.outcome.label)
                    .font(showsContactName ? Type.caption : Type.body)
                    .foregroundStyle(showsContactName ? Palette.textSecondary : Palette.textPrimary)
                if let note = visit.notes.trimmedOrNil {
                    Text(note)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(2)
                }
                if visit.isLocationApproximate, visit.coordinate != nil {
                    Label("Approximate location", systemImage: "location.slash")
                        .font(.caption2)
                        .foregroundStyle(Palette.textTertiary)
                }
            }

            Spacer(minLength: Space.sm)

            VStack(alignment: .trailing, spacing: 4) {
                Text(visit.occurredAt.formatted(.relative(presentation: .numeric)))
                    .font(Type.caption)
                    .foregroundStyle(Palette.textTertiary)
                if let gift = visit.gift, gift.countsTowardGiving {
                    Text(gift.isInKind ? "In-kind" : gift.amount.formattedCompact)
                        .font(Type.caption.weight(.semibold))
                        .foregroundStyle(Palette.positive)
                        .monospacedDigit()
                }
                if visit.hasPhotoEvidence {
                    Image(systemName: "photo")
                        .font(.caption2)
                        .foregroundStyle(Palette.textTertiary)
                        .accessibilityLabel("Has a photo")
                }
            }
        }
        .cardSurface(padding: Space.sm)
        .accessibilityElement(children: .combine)
    }
}
