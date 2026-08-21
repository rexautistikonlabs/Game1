//
//  FollowUpsView.swift
//  FieldForge
//
//  Everything owed, grouped by when. Reached from Today rather than living in a
//  tab of its own, because a list of chores should not be one of five things
//  competing for attention — the ones that are due today already appear on the
//  first screen.
//

import SwiftData
import SwiftUI

struct FollowUpsView: View {

    @Environment(\.modelContext) private var context

    @Query(
        filter: #Predicate<FollowUp> { $0.completedAt == nil },
        sort: \FollowUp.dueAt
    )
    private var openFollowUps: [FollowUp]

    @Query(
        filter: #Predicate<FollowUp> { $0.completedAt != nil },
        sort: \FollowUp.completedAt,
        order: .reverse
    )
    private var completed: [FollowUp]

    @State private var showsCompleted = false

    var body: some View {
        List {
            if openFollowUps.isEmpty {
                Section {
                    EmptyStateView(
                        symbol: "checkmark.circle",
                        title: "Nothing owed",
                        message: "Reminders you set during a capture will land here."
                    )
                }
            } else {
                bucket("Overdue", items: overdue, tint: Palette.critical)
                bucket("Today", items: today, tint: Palette.caution)
                bucket("This week", items: thisWeek, tint: Palette.brand)
                bucket("Later", items: later, tint: Palette.textSecondary)
            }

            if !completed.isEmpty {
                Section {
                    DisclosureGroup("Done (\(completed.count))", isExpanded: $showsCompleted) {
                        ForEach(completed.prefix(20)) { followUp in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(followUp.contact?.displayName ?? "Follow up")
                                    .font(Type.secondary)
                                    .strikethrough()
                                    .foregroundStyle(Palette.textSecondary)
                                if let completedAt = followUp.completedAt {
                                    Text("Done \(completedAt.formatted(.relative(presentation: .named)))")
                                        .font(.caption2)
                                        .foregroundStyle(Palette.textTertiary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Follow-ups")
    }

    @ViewBuilder
    private func bucket(_ title: String, items: [FollowUp], tint: Color) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { followUp in
                    FollowUpRow(followUp: followUp)
                }
            } header: {
                HStack(spacing: Space.xs) {
                    Circle().fill(tint).frame(width: 7, height: 7)
                    Text("\(title) · \(items.count)")
                }
            }
        }
    }

    // MARK: Buckets

    private var overdue: [FollowUp] {
        openFollowUps.filter { $0.isOverdue && !$0.isDueToday }
    }

    private var today: [FollowUp] {
        openFollowUps.filter(\.isDueToday)
    }

    private var thisWeek: [FollowUp] {
        let calendar = Calendar.current
        guard let weekOut = calendar.date(byAdding: .day, value: 7, to: .now) else { return [] }
        return openFollowUps.filter {
            !$0.isOverdue && !$0.isDueToday && $0.dueAt <= weekOut
        }
    }

    private var later: [FollowUp] {
        let calendar = Calendar.current
        guard let weekOut = calendar.date(byAdding: .day, value: 7, to: .now) else { return [] }
        return openFollowUps.filter { $0.dueAt > weekOut }
    }
}

#Preview("Follow-ups") {
    NavigationStack { FollowUpsView() }
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
