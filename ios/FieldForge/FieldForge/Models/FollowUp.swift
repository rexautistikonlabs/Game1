//
//  FollowUp.swift
//  FieldForge
//
//  A reminder that shows up at the right time and has a button on it. A
//  reminder that only says "follow up with Dolores" is a chore; one that says
//  it and offers a Call button is a completed task.
//

import Foundation
import SwiftData

@Model
final class FollowUp {

    var id: UUID = UUID()

    /// Raw storage for the enum above. Internal rather than private so
    /// `#Predicate` in other files can filter on it.
    var kindRawValue: String = FollowUpKind.other.rawValue
    var kind: FollowUpKind {
        get { FollowUpKind(rawValue: kindRawValue) ?? .other }
        set { kindRawValue = newValue.rawValue }
    }

    var dueAt: Date = Date.now

    /// What to actually say or do. Prefilled from the visit notes so the
    /// staffer's future self has context they will otherwise have lost.
    var note: String = ""

    var completedAt: Date?
    var snoozeCount: Int = 0

    /// Identifier of the scheduled `UNNotificationRequest`, so rescheduling or
    /// completing the follow-up can cancel the pending notification.
    var notificationIdentifier: String = ""

    /// False when notification permission was refused or the schedule failed.
    /// The Today screen still surfaces the follow-up, so a denied permission
    /// degrades the experience without losing the commitment.
    var isNotificationScheduled: Bool = false

    var isSharedWithTeam: Bool = false
    var assignedToDisplayName: String = ""

    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    /// Inverse declared on `Contact.followUps`.
    var contact: Contact?

    init(kind: FollowUpKind = .other, dueAt: Date = .now, note: String = "") {
        self.kindRawValue = kind.rawValue
        self.dueAt = dueAt
        self.note = note
    }

    var isComplete: Bool { completedAt != nil }

    var isOverdue: Bool {
        !isComplete && dueAt < .now
    }

    var isDueToday: Bool {
        !isComplete && Calendar.current.isDateInToday(dueAt)
    }

    /// "Overdue by 3 days" / "In 2 weeks" / "Today"
    var relativeDueDescription: String {
        if Calendar.current.isDateInToday(dueAt) { return "Today" }
        return dueAt.formatted(.relative(presentation: .named))
    }

    func complete() {
        completedAt = .now
        updatedAt = .now
    }

    func snooze(byDays days: Int) {
        dueAt = Calendar.current.date(byAdding: .day, value: days, to: max(dueAt, .now)) ?? dueAt
        snoozeCount += 1
        updatedAt = .now
    }
}
