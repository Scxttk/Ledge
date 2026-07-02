import SwiftUI

/// A notch/island shape designed to look like it "sticks" to the top screen
/// edge: the top edge is flush and full-width, and the two top corners are
/// *concave* (inverse radii) that scoop inward as they fall into the vertical
/// sides — the classic MacBook-notch / Dynamic Island look. The concave scoops
/// are elongated horizontally (`topWidthFactor`) so they read as long, flowing
/// flares rather than tight corners. The bottom corners are *convex* roundings.
/// Both radii animate with the expand state.
struct NotchShape: Shape {
    /// Convex radius of the bottom corners.
    var bottomRadius: CGFloat
    /// Vertical depth of the concave top scoops where the notch meets the edge.
    var topRadius: CGFloat
    /// How much wider than deep the concave top scoops are (1 = circular).
    var topWidthFactor: CGFloat = 1.5

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set {
            bottomRadius = newValue.first
            topRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let topH = max(0, min(topRadius, rect.height))
        // Horizontal reach of the scoop; keep room for both scoops on the top edge.
        let topW = max(0, min(topH * topWidthFactor, rect.width / 2 - 1))
        let bottomR = max(0, min(bottomRadius, rect.height - topH, (rect.width - 2 * topW) / 2))

        // Top-left: concave scoop from the flush top edge down into the left side.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topW, y: rect.minY + topH),
            control: CGPoint(x: rect.minX + topW, y: rect.minY)
        )
        // Left side.
        path.addLine(to: CGPoint(x: rect.minX + topW, y: rect.maxY - bottomR))
        // Bottom-left: convex rounding.
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + topW + bottomR, y: rect.maxY),
            control: CGPoint(x: rect.minX + topW, y: rect.maxY)
        )
        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - topW - bottomR, y: rect.maxY))
        // Bottom-right: convex rounding.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - topW, y: rect.maxY - bottomR),
            control: CGPoint(x: rect.maxX - topW, y: rect.maxY)
        )
        // Right side.
        path.addLine(to: CGPoint(x: rect.maxX - topW, y: rect.minY + topH))
        // Top-right: concave scoop back up to the flush top edge.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - topW, y: rect.minY)
        )
        // Flush top edge (closeSubpath draws maxX,minY -> minX,minY).
        path.closeSubpath()
        return path
    }
}
