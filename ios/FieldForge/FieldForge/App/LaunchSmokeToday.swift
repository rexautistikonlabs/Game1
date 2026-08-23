//
//  LaunchSmokeToday.swift
//  FieldForge
//
//  The first frame. Painted before Persistence / AppEnvironment finish, and
//  kept on screen if they fail. Never imports Stripe Terminal.
//

import SwiftUI

struct LaunchSmokeToday: View {
    var error: String?

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Text(error)
                            .font(Type.body)
                            .foregroundStyle(Palette.textPrimary)
                    }
                } else {
                    Section {
                        Text("Who to see today")
                            .font(Type.section)
                            .foregroundStyle(Palette.textPrimary)
                        Text("Opening…")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Today")
        }
    }
}

#Preview("Launch smoke") {
    LaunchSmokeToday()
}
