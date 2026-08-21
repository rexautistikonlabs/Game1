//
//  PaywallView.swift
//  FieldForge
//
//  The upgrade screen.
//
//  Written the way a nonprofit should be sold to: it starts by telling them
//  what they already have for free, because that list is long and it is true.
//  Nothing here uses a countdown, a fake discount, or a dark pattern. The
//  cheapest option is listed first and the small-organization price is
//  presented as a normal choice rather than something to be ashamed of asking
//  for.
//

import StoreKit
import SwiftUI

struct PaywallView: View {

    @Environment(\.appEnvironment) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var selectedProductID: String?
    @State private var message: String?
    @State private var messageKind: InlineBanner.Kind = .info
    @State private var isRestoring = false

    private var store: StoreService { app.store }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header
                    if let message {
                        InlineBanner(kind: messageKind, message: message)
                    }
                    freeTierReassurance
                    teamFeatures
                    plans
                    smallPrint
                }
                .padding(.horizontal, Space.screenEdge)
                .padding(.bottom, Space.xxl)
            }
            .background(Palette.background)
            .navigationTitle("FieldForge Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Restore") { Task { await restore() } }
                        .disabled(isRestoring)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !app.entitlements.isPro {
                    ActionBar {
                        PrimaryButton(
                            title: purchaseButtonTitle,
                            systemImage: "person.2.badge.key.fill",
                            isLoading: store.purchaseInFlight != nil,
                            isEnabled: selectedProduct != nil
                        ) {
                            Task { await purchase() }
                        }
                        Text("Cancel any time in your Apple Account settings.")
                            .font(Type.caption)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
            .task {
                await store.loadProducts()
                // Default to the annual plan, which is the better value, rather
                // than to whichever loaded first.
                selectedProductID = store.product(for: StoreService.ProductID.teamAnnual)?.id
                    ?? store.products.first?.id
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            if app.entitlements.isPro {
                Label("You are on Team", systemImage: "checkmark.seal.fill")
                    .font(Type.section)
                    .foregroundStyle(Palette.positive)
            }
            Text("One shared memory for the whole team")
                .font(Type.screenTitle)
                .foregroundStyle(Palette.textPrimary)
            Text("Every staffer and volunteer sees the same history: who gave, who was warm, who asked to be called back in the fall, and what time of day anyone actually catches them.")
                .font(Type.body)
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.top, Space.sm)
    }

    // MARK: Free tier

    /// Leading with what is free is not modesty, it is the honest framing. If a
    /// tiny nonprofit reads this screen and concludes they do not need to pay,
    /// that is a correct outcome.
    private var freeTierReassurance: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("Free forever, for everyone")
                .font(Type.section)

            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(freeHighlights, id: \.self) { item in
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Palette.positive)
                        Text(item)
                            .font(Type.secondary)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Text("A donor's receipt should never stop working because a subscription lapsed. It does not, here.")
                .font(Type.caption)
                .foregroundStyle(Palette.textSecondary)
        }
        .cardSurface()
    }

    private var freeHighlights: [String] {
        [
            "Unlimited receipts and IRS acknowledgment letters",
            "Your logo, your colour, your EIN, your signature",
            "Apple Pay, cash, cheque and in-kind capture",
            "Contacts, visits, giving history and reminders — kept forever",
            "Your own warmth ratings and your own map",
            "Full offline capture, email, AirDrop and printing",
        ]
    }

    // MARK: Team features

    private var teamFeatures: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("What Team adds")
                .font(Type.section)

            ForEach(paidFeatures, id: \.rawValue) { feature in
                if let description = feature.paywallDescription {
                    HStack(alignment: .top, spacing: Space.sm) {
                        Image(systemName: "person.2.fill")
                            .font(.caption)
                            .foregroundStyle(Palette.brand)
                            .frame(width: 18)
                        Text(description)
                            .font(Type.secondary)
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .cardSurface()
    }

    private var paidFeatures: [Feature] {
        // Available only: selling something that does not exist yet is the one
        // thing a paywall must never do.
        Feature.allCases.filter { !$0.isFree && $0.isAvailable }
    }

    // MARK: Plans

    private var selectedProduct: Product? {
        guard let selectedProductID else { return nil }
        return store.product(for: selectedProductID)
    }

    private var purchaseButtonTitle: String {
        guard let product = selectedProduct else { return "Choose a plan" }
        if product.subscription?.introductoryOffer != nil {
            return "Start free, then \(store.priceDescription(for: product))"
        }
        return "Subscribe — \(store.priceDescription(for: product))"
    }

    @ViewBuilder
    private var plans: some View {
        if app.entitlements.isPro {
            InlineBanner(
                kind: .positive,
                message: "Team is active on this Apple Account. Nothing more to do."
            )
        } else if store.products.isEmpty {
            VStack(alignment: .leading, spacing: Space.sm) {
                if store.isLoadingProducts {
                    HStack(spacing: Space.sm) {
                        ProgressView()
                        Text("Checking the App Store…")
                            .font(Type.secondary)
                            .foregroundStyle(Palette.textSecondary)
                    }
                } else {
                    InlineBanner(
                        kind: .caution,
                        message: store.lastErrorMessage
                            ?? "The App Store is not reachable right now. Everything you already have keeps working.",
                        actionTitle: "Try again"
                    ) {
                        Task { await store.loadProducts() }
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("Choose a plan")
                    .font(Type.section)

                ForEach(store.products, id: \.id) { product in
                    PlanRow(
                        product: product,
                        priceDescription: store.priceDescription(for: product),
                        monthlyEquivalent: store.monthlyEquivalent(for: product),
                        isSelected: selectedProductID == product.id,
                        isSmallOrgOption: product.id == StoreService.ProductID.teamAnnualSmallOrg
                    ) {
                        Haptics.selection()
                        selectedProductID = product.id
                    }
                }
            }
        }
    }

    private var smallPrint: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Subscriptions renew automatically until cancelled. Manage or cancel in your Apple Account settings at any time.")
            Text("If a subscription ends, everything you have created stays on your iPhone and stays usable. Shared team memory simply stops syncing.")
            Text("The small-organization price is offered on trust. Nobody will audit you.")
        }
        .font(Type.caption)
        .foregroundStyle(Palette.textTertiary)
    }

    // MARK: Actions

    private func purchase() async {
        guard let product = selectedProduct else { return }
        let result = await store.purchase(product)
        switch result {
        case .success:
            messageKind = .positive
            message = "Thank you. Team is on — restart FieldForge to start syncing with your team."
        case .cancelled:
            break
        case .pending:
            messageKind = .info
            message = "Waiting for approval. Team will switch on by itself once it is approved."
        case .failed(let reason):
            messageKind = .critical
            message = reason
        }
    }

    private func restore() async {
        isRestoring = true
        defer { isRestoring = false }
        let restored = await store.restorePurchases()
        messageKind = restored ? .positive : .info
        message = restored
            ? "Restored. Team is on."
            : "No previous purchase was found on this Apple Account."
    }
}

// MARK: - Plan row

private struct PlanRow: View {
    let product: Product
    let priceDescription: String
    let monthlyEquivalent: String?
    let isSelected: Bool
    let isSmallOrgOption: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.md) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Palette.brand : Palette.textTertiary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(Type.body.weight(.semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text(priceDescription)
                        .font(Type.secondary)
                        .foregroundStyle(Palette.textPrimary)
                    if let monthlyEquivalent {
                        Text(monthlyEquivalent)
                            .font(Type.caption)
                            .foregroundStyle(Palette.textSecondary)
                    }
                    Text(product.description)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if product.subscription?.introductoryOffer != nil {
                        Label("Free to start", systemImage: "gift")
                            .font(Type.caption.weight(.medium))
                            .foregroundStyle(Palette.positive)
                    }
                }

                Spacer(minLength: 0)

                if isSmallOrgOption {
                    Text("Small org")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 3)
                        .background(Palette.brandMuted, in: Capsule())
                        .foregroundStyle(Palette.brand)
                }
            }
            .padding(Space.md)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Space.corner, style: .continuous)
                    .strokeBorder(isSelected ? Palette.brand : Palette.separator, lineWidth: isSelected ? 2 : 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(product.displayName), \(priceDescription)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview("Paywall") {
    PaywallView()
        .environment(\.appEnvironment, AppEnvironment.preview())
        .modelContainer(Persistence.previewContainer())
}
