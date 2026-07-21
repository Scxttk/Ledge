import SwiftUI

/// The iPhone-style island silhouette: a plain rounded rectangle with a
/// continuous (superellipse) corner curve, detached from the screen edge.
/// A custom shape instead of `RoundedRectangle` so the corner radius is
/// explicitly animatable and morphs in the same transaction as the island's
/// frame (capsule when collapsed, softly rounded panel when expanded).
/// `InsettableShape` so the highlight rim can use `strokeBorder`.
struct IslandShape: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: CGFloat {
        get { cornerRadius }
        set { cornerRadius = newValue }
    }

    func inset(by amount: CGFloat) -> IslandShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }

    func path(in rect: CGRect) -> Path {
        let inset = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard inset.width > 0, inset.height > 0 else { return Path() }
        let radius = max(0, min(cornerRadius - insetAmount, min(inset.width, inset.height) / 2))
        return Path(roundedRect: inset, cornerRadius: radius, style: .continuous)
    }
}
