import SwiftUI

/// Keeps a selection's actions inside the reading surface as the text reflows.
struct HighlightPopoverLayout: Layout {
    var anchor: CGRect

    private let inset: CGFloat = 12
    private let gap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.first?.sizeThatFits(.unspecified) ?? .zero
        return CGSize(
            width: proposal.width ?? ideal.width + 2 * inset,
            height: proposal.height ?? ideal.height + 2 * inset
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let content = subviews.first else { return }
        let available = ProposedViewSize(
            width: max(0, bounds.width - 2 * inset),
            height: max(0, bounds.height - 2 * inset)
        )
        let size = content.sizeThatFits(available)
        let left = bounds.minX + inset
        let right = max(left, bounds.maxX - inset - size.width)
        let top = bounds.minY + inset
        let bottom = max(top, bounds.maxY - inset - size.height)
        let below = bounds.minY + anchor.maxY + gap
        let above = bounds.minY + anchor.minY - gap - size.height
        let y: CGFloat
        if below >= top, below <= bottom {
            y = below
        } else if above >= top, above <= bottom {
            y = above
        } else {
            y = min(max(below, top), bottom)
        }
        let centered = bounds.minX + anchor.midX - size.width / 2
        content.place(
            at: CGPoint(x: min(max(centered, left), right), y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}
