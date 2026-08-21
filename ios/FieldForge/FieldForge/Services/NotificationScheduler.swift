//
//  NotificationScheduler.swift
//  FieldForge
//
//  Follow-up reminders that arrive at a useful hour and have something to do
//  when tapped.
//
//  Two rules shape this file:
//
//    1. A reminder never fires at 3am. A due date with no time gets scheduled
//       for a sensible working hour in the staffer's own timezone.
//    2. A denied permission never loses a commitment. The `FollowUp` record is
//       the source of truth and the Today screen surfaces it regardless; the
//       notification is a convenience layered on top.
//

import Foundation
import UserNotifications

@MainActor
enum NotificationScheduler {

    /// The hour a reminder lands when the staffer only picked a date. 9am local
    /// is early enough to plan the day around and late enough to be civil.
    static let defaultHour = 9
    static let defaultMinute = 0

    /// Category identifier, so tapping a reminder deep-links to the contact.
    static let followUpCategory = "org.example.fieldforge.followUp"
    static let contactIDKey = "contactID"
    static let followUpIDKey = "followUpID"

    // MARK: Permission

    /// Requests permission at the moment a staffer schedules their first
    /// reminder, not at launch. Asking on first run gets a reflexive "no".
    static func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                AppLog.app.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        @unknown default:
            return false
        }
    }

    /// Registers the actionable category. Called once at launch.
    static func registerCategories() {
        let done = UNNotificationAction(
            identifier: "org.example.fieldforge.markDone",
            title: "Mark done",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: "org.example.fieldforge.snoozeWeek",
            title: "Remind me in a week",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: followUpCategory,
            actions: [done, snooze],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    // MARK: Scheduling

    /// Schedules (or reschedules) the reminder for a follow-up.
    ///
    /// Writes the outcome back onto the record so the UI can be honest about
    /// whether a notification will actually appear.
    @discardableResult
    static func schedule(_ followUp: FollowUp) async -> Bool {
        await cancel(followUp)

        guard await requestAuthorizationIfNeeded() else {
            followUp.isNotificationScheduled = false
            return false
        }

        let fireDate = normalizedFireDate(for: followUp.dueAt)
        guard fireDate > .now else {
            // Already due. The Today screen shows it; a notification in the past
            // cannot be scheduled and a fake one now would be startling.
            followUp.isNotificationScheduled = false
            return false
        }

        let content = UNMutableNotificationContent()
        content.title = title(for: followUp)
        content.body = body(for: followUp)
        content.sound = .default
        content.categoryIdentifier = followUpCategory
        content.userInfo = [
            followUpIDKey: followUp.id.uuidString,
            contactIDKey: followUp.contact?.id.uuidString ?? "",
        ]
        // Grouped by contact so five reminders about one business stack.
        content.threadIdentifier = followUp.contact?.id.uuidString ?? followUp.id.uuidString
        content.interruptionLevel = .active

        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let identifier = followUp.id.uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await UNUserNotificationCenter.current().add(request)
            followUp.notificationIdentifier = identifier
            followUp.isNotificationScheduled = true
            return true
        } catch {
            AppLog.app.error("Could not schedule reminder: \(error.localizedDescription, privacy: .public)")
            followUp.isNotificationScheduled = false
            return false
        }
    }

    static func cancel(_ followUp: FollowUp) async {
        let identifiers = [followUp.notificationIdentifier, followUp.id.uuidString]
            .compactMap { $0.trimmedOrNil }
        guard !identifiers.isEmpty else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        followUp.isNotificationScheduled = false
    }

    /// Moves a midnight date to a working hour, and leaves a deliberate time
    /// alone. A staffer who set 4:30pm meant 4:30pm.
    static func normalizedFireDate(for date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let isMidnight = (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0
        guard isMidnight else { return date }
        return calendar.date(
            bySettingHour: defaultHour,
            minute: defaultMinute,
            second: 0,
            of: date
        ) ?? date
    }

    // MARK: Copy

    private static func title(for followUp: FollowUp) -> String {
        let name = followUp.contact?.displayName ?? "a contact"
        switch followUp.kind {
        case .thankYou: return "Thank \(name)"
        case .collectPledge: return "Collect from \(name)"
        case .visitAgain: return "Visit \(name) again"
        case .call: return "Call \(name)"
        case .text: return "Text \(name)"
        case .email: return "Email \(name)"
        case .sendDocument: return "Send \(name) their letter"
        case .other: return "Follow up with \(name)"
        }
    }

    private static func body(for followUp: FollowUp) -> String {
        if let note = followUp.note.trimmedOrNil { return note }
        if let window = followUp.contact?.contactWindow, window != .unknown {
            return "Best time to catch them: \(window.label.lowercased())."
        }
        return "Tap to open their record."
    }

    // MARK: Housekeeping

    /// Reconciles what iOS has pending against what the store says. Run at
    /// launch: a restored backup, a long-dead app, or a denied-then-granted
    /// permission all leave the two out of step.
    static func reconcile(followUps: [FollowUp]) async {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let pendingIDs = Set(pending.map(\.identifier))

        for followUp in followUps where !followUp.isComplete && followUp.dueAt > .now {
            if !pendingIDs.contains(followUp.id.uuidString) {
                await schedule(followUp)
            }
        }
        // Cancel anything iOS still holds for a follow-up that is done.
        let staleIDs = followUps
            .filter { $0.isComplete }
            .map(\.id.uuidString)
            .filter { pendingIDs.contains($0) }
        if !staleIDs.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: staleIDs)
        }
    }
}
