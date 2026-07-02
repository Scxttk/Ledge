import SwiftUI

/// A transient event surfaced in the collapsed pill, like the real Dynamic
/// Island's live activities. Content is modelled as data (icon · title · tint)
/// so the collapsed view can render every kind uniformly.
struct NotchActivity: Identifiable, Equatable {
    enum Kind: Equatable {
        case charging
        case battery
        case audioRoute
        case fileReceived
        case timer
    }

    let id = UUID()
    let kind: Kind
    /// Higher wins when two activities compete for the pill.
    var priority: Int
    var icon: String          // SF Symbol name
    var tint: Color
    var title: String         // short, fits the pill
    var autoDismiss: TimeInterval
    /// 0…1 for HUD-style activities (volume/brightness); nil shows the title.
    var progress: Double?
    /// Trailing detail shown next to the title, e.g. an AirPods battery "82%".
    var detail: String?

    init(kind: Kind, priority: Int, icon: String, tint: Color, title: String, autoDismiss: TimeInterval, progress: Double? = nil, detail: String? = nil) {
        self.kind = kind
        self.priority = priority
        self.icon = icon
        self.tint = tint
        self.title = title
        self.autoDismiss = autoDismiss
        self.progress = progress
        self.detail = detail
    }
}
