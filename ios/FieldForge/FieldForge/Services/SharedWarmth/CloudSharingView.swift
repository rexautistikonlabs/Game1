//
//  CloudSharingView.swift
//  FieldForge
//
//  `UICloudSharingController`, wrapped for SwiftUI.
//
//  Using Apple's own sharing sheet rather than building an invite flow matters
//  here: it handles the invite link, the participant list, permissions, and
//  removal, and — more importantly — it is the interface people already
//  recognise from Photos and Notes. A nonprofit's volunteer coordinator should
//  not have to learn a bespoke sharing UI.
//

import CloudKit
import SwiftUI
import UIKit

struct CloudSharingView: UIViewControllerRepresentable {

    let share: CKShare
    let container: CKContainer
    /// Shown as the share's title in the invitation.
    let teamName: String
    var onSaved: () -> Void = {}
    var onStoppedSharing: () -> Void = {}
    var onFailed: (Error) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        // Read-write, because the whole feature is teammates *contributing*
        // warmth ratings, not merely reading them. Private-only: a donor
        // relationship database must never be publicly joinable by link.
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(teamName: teamName, onSaved: onSaved, onStoppedSharing: onStoppedSharing, onFailed: onFailed)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {

        private let teamName: String
        private let onSaved: () -> Void
        private let onStoppedSharing: () -> Void
        private let onFailed: (Error) -> Void

        init(
            teamName: String,
            onSaved: @escaping () -> Void,
            onStoppedSharing: @escaping () -> Void,
            onFailed: @escaping (Error) -> Void
        ) {
            self.teamName = teamName
            self.onSaved = onSaved
            self.onStoppedSharing = onStoppedSharing
            self.onFailed = onFailed
        }

        func itemTitle(for csc: UICloudSharingController) -> String? {
            teamName
        }

        /// The subtitle in the invitation. Worth being explicit here: the
        /// person accepting deserves to know what they are joining before they
        /// tap, not after.
        func itemType(for csc: UICloudSharingController) -> String? {
            "Shared donor warmth"
        }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            AppLog.sync.info("Team share saved")
            onSaved()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            AppLog.sync.info("Team share stopped from the sharing sheet")
            onStoppedSharing()
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            AppLog.sync.error("Share failed: \(error.localizedDescription, privacy: .public)")
            onFailed(error)
        }
    }
}
