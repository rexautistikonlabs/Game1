//
//  CommonViews.swift
//  FieldForge
//
//  The small shared pieces: section headers, empty states, stat tiles, banners,
//  and the offline pill. Collected in one file because each is a dozen lines and
//  a file each would be worse.
//

import SwiftUI

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Type.section)
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Type.caption)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            Spacer(minLength: Space.sm)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Type.secondary.weight(.medium))
                    .foregroundStyle(Palette.brand)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Empty state

/// Empty states that say what to do, not just that there is nothing here.
struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.textTertiary)
                .accessibilityHidden(true)

            VStack(spacing: Space.xs) {
                Text(title)
                    .font(Type.section)
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(Type.secondary)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Type.body.weight(.semibold))
                    .padding(.horizontal, Space.lg)
                    .frame(minHeight: Space.minimumTarget)
                    .background(Palette.brandMuted, in: Capsule())
                    .foregroundStyle(Palette.brand)
            }
        }
        .frame(maxWidth: 340)
        .padding(Space.lg)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stat tile

/// A number with a label. Used on Today for the day's totals.
struct StatTile: View {
    let value: String
    let label: String
    var systemImage: String?
    var tint: Color = Palette.brand

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption)
                        .foregroundStyle(tint)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(Type.label)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(value)
                .font(Type.amountSmall)
                .foregroundStyle(Palette.textPrimary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.sm)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Banner

/// An inline message. Used for offline status, simulated payments, and store
/// recovery warnings — never for anything that should be an alert.
struct InlineBanner: View {

    enum Kind {
        case info
        case caution
        case critical
        case positive

        var tint: Color {
            switch self {
            case .info: return Palette.brand
            case .caution: return Palette.caution
            case .critical: return Palette.critical
            case .positive: return Palette.positive
            }
        }

        var symbol: String {
            switch self {
            case .info: return "info.circle.fill"
            case .caution: return "exclamationmark.triangle.fill"
            case .critical: return "exclamationmark.octagon.fill"
            case .positive: return "checkmark.circle.fill"
            }
        }
    }

    let kind: Kind
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.tint)
                .accessibilityHidden(true)

            Text(message)
                .font(Type.secondary)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(Type.secondary.weight(.semibold))
                    .foregroundStyle(kind.tint)
                    .minimumTapTarget()
            }
        }
        .padding(Space.sm)
        .background(kind.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: Space.cornerSmall, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Connectivity pill

/// The status pill in the navigation bar. Its job is reassurance: "offline" must
/// read as "still working", not as an error.
struct ConnectivityPill: View {
    let reachability: Reachability
    var queuedCount: Int = 0

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
            if queuedCount > 0 {
                Text("\(queuedCount)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Space.sm)
        .frame(minHeight: 28)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var symbol: String {
        if !reachability.isOnline { return "wifi.slash" }
        if queuedCount > 0 { return "arrow.up.arrow.down.circle.fill" }
        return "wifi"
    }

    private var tint: Color {
        if !reachability.isOnline { return Palette.offline }
        if queuedCount > 0 { return Palette.caution }
        return Palette.positive
    }

    private var accessibilityText: String {
        var parts = [reachability.statusDescription]
        if queuedCount > 0 {
            parts.append(queuedCount == 1 ? "1 item waiting to send" : "\(queuedCount) items waiting to send")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Labelled row

/// A label and a value, the building block of every detail screen.
struct LabeledRow: View {
    let label: String
    let value: String
    var systemImage: String?
    var valueColor: Color = Palette.textPrimary
    var isMonospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
            }
            Text(label)
                .font(Type.secondary)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Space.sm)
            Text(value)
                .font(isMonospaced ? Type.amountSmall : Type.secondary.weight(.medium))
                .foregroundStyle(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Tag chips

struct TagChips: View {
    let tags: [String]
    var onRemove: ((String) -> Void)?

    var body: some View {
        // A wrapping flow, so a contact with eight tags does not scroll sideways
        // off the screen.
        FlowLayout(spacing: Space.xs) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                        .font(Type.caption)
                    if let onRemove {
                        Button {
                            onRemove(tag)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove tag \(tag)")
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 5)
                .background(Palette.brandMuted, in: Capsule())
                .foregroundStyle(Palette.brand)
            }
        }
    }
}

/// Minimal wrapping layout. `Layout` rather than a nest of HStacks so it works
/// at every Dynamic Type size without hard-coded row counts.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                widestRow = max(widestRow, rowWidth)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        widestRow = max(widestRow, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(widestRow, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

#Preview("Common views") {
    ScrollView {
        VStack(spacing: Space.lg) {
            SectionHeader(title: "Today", subtitle: "3 visits, 2 gifts", actionTitle: "See all") {}
            HStack(spacing: Space.sm) {
                StatTile(value: "$1,250", label: "Raised", systemImage: "arrow.up.right")
                StatTile(value: "8", label: "Doors", systemImage: "figure.walk")
                StatTile(value: "2", label: "Queued", systemImage: "tray.full", tint: Palette.caution)
            }
            InlineBanner(
                kind: .caution,
                message: "No signal. Everything is saving locally and will send itself when you are back on.",
                actionTitle: "Details"
            ) {}
            LabeledRow(label: "Lifetime giving", value: "$4,500.00", systemImage: "gift", isMonospaced: true)
            TagChips(tags: ["main street", "restaurant", "matches gifts", "spanish speaking"]) { _ in }
            EmptyStateView(
                symbol: "person.crop.circle.badge.plus",
                title: "No contacts yet",
                message: "Point the camera at a shop sign and FieldForge will fill in the name and address.",
                actionTitle: "Scan a sign"
            ) {}
        }
        .padding()
    }
    .background(Palette.background)
}
