import SwiftUI

/// A simple left-to-right, top-to-bottom wrapping layout — used for the
/// "selected fields" chip cloud, since a plain HStack would just overflow
/// the popover width instead of wrapping to new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            // Cap each item's own proposed width at the container's max
            // width — measuring with `.unspecified` let a single long chip
            // (a long field label) report its full natural width with no
            // upper bound, which could exceed the whole popover's width and
            // blow it out sideways instead of wrapping/truncating. Proposing
            // maxWidth as an upper bound is a no-op for normal-sized items
            // (Text just reports its natural width when there's room) and
            // makes an oversized one truncate (it has .lineLimit(1)).
            let itemProposal = ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
            let rawSize = subview.sizeThatFits(itemProposal)
            let size = CGSize(width: min(rawSize.width, maxWidth), height: rawSize.height)

            if lineWidth > 0, lineWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += (lineWidth > 0 ? spacing : 0) + size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let itemProposal = ProposedViewSize(width: maxWidth, height: nil)
            let rawSize = subview.sizeThatFits(itemProposal)
            let size = CGSize(width: min(rawSize.width, maxWidth), height: rawSize.height)

            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// How tightly chips pack — chosen from how many are selected at once, so a
/// handful of fields get comfortable roomy pills, while a few dozen shrink
/// down (smaller font, tighter padding, value preview dropped first) to
/// keep the whole set visible without every one of them needing a scroll.
enum ChipDensity: Equatable {
    case roomy, compact, tiny

    init(itemCount: Int) {
        switch itemCount {
        case 0...8: self = .roomy
        case 9...20: self = .compact
        default: self = .tiny
        }
    }

    var labelFontSize: CGFloat {
        switch self {
        case .roomy: 10
        case .compact: 9
        case .tiny: 8
        }
    }
    var valueFontSize: CGFloat { labelFontSize - 1 }
    var showsValue: Bool { self != .tiny }
    var removeIconSize: CGFloat {
        switch self {
        case .roomy: 11
        case .compact: 10
        case .tiny: 9
        }
    }
    var horizontalPadding: CGFloat {
        switch self {
        case .roomy: 8
        case .compact: 6
        case .tiny: 4
        }
    }
    var verticalPadding: CGFloat {
        switch self {
        case .roomy: 5
        case .compact: 4
        case .tiny: 3
        }
    }
    var innerSpacing: CGFloat {
        switch self {
        case .roomy: 5
        case .compact: 4
        case .tiny: 3
        }
    }
    /// Passed to FlowLayout's own spacing — packs rows tighter too as
    /// density increases, not just each chip individually.
    var flowSpacing: CGFloat {
        switch self {
        case .roomy: 6
        case .compact: 5
        case .tiny: 4
        }
    }
}

/// One removable, reorderable "pill" for a field that's currently marked
/// visible in the overlay — shows its label plus a live value preview, with
/// inline ◀ ▶ to move it earlier/later in the overlay's render order (this
/// is what decides which tile ends up next to which) and an "x" to unmark
/// it without hunting for it in the full field list. Sizing responds to
/// `density` so a large selection still fits without every chip forcing
/// its own scroll.
struct FieldChip: View {
    let label: String
    let value: String
    let density: ChipDensity
    let canMoveBack: Bool
    let canMoveForward: Bool
    let onMoveBack: () -> Void
    let onMoveForward: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: density.innerSpacing) {
            if density != .tiny {
                moveButton(systemName: "chevron.left", enabled: canMoveBack, action: onMoveBack)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.system(size: density.labelFontSize, weight: .medium))
                if density.showsValue, !value.isEmpty {
                    Text(value)
                        .font(.system(size: density.valueFontSize, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)

            if density != .tiny {
                moveButton(systemName: "chevron.right", enabled: canMoveForward, action: onMoveForward)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: density.removeIconSize))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, density.horizontalPadding)
        .padding(.vertical, density.verticalPadding)
        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        .overlay(Capsule().stroke(Color.accentColor.opacity(0.35), lineWidth: 1))
    }

    private func moveButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: density.removeIconSize - 1, weight: .bold))
                .foregroundStyle(enabled ? .secondary : .quaternary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
