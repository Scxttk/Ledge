import SwiftUI
import AppKit

struct NotchRootView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var activities: ActivityManager
    @ObservedObject var capture: ObsidianCapture

    private var islandWidth: CGFloat {
        if viewModel.isExpanded { return viewModel.expandedWidth }
        if let activity = activities.current {
            return activity.kind == .audioRoute ? NotchLayout.activityRouteWidth : NotchLayout.activityWidth
        }
        return viewModel.collapsedWidth(isPlaying: nowPlaying.isPlaying, hasItems: !shelf.items.isEmpty)
    }
    private var islandHeight: CGFloat {
        viewModel.isExpanded ? viewModel.expandedHeight : viewModel.collapsedHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            island
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: nowPlaying.isPlaying) { _, playing in
            // When music starts, surface the music tab.
            if playing { viewModel.selectedTab = .music }
        }
    }

    private var island: some View {
        let bottomRadius = viewModel.isExpanded ? NotchLayout.notchBottomRadiusExpanded : NotchLayout.notchBottomRadiusCollapsed
        let topRadius = viewModel.isExpanded ? NotchLayout.notchTopRadiusExpanded : NotchLayout.notchTopRadiusCollapsed
        let shape = NotchShape(bottomRadius: bottomRadius, topRadius: topRadius, topWidthFactor: NotchLayout.notchTopWidthFactor)
        // The black silhouette leads. The content is clipped to the island bounds
        // (flush top, rounded bottom) so it can't float outside the frame while it
        // resizes — but NOT to the concave `NotchShape`, whose top flares would
        // carve away the top corners and hide corner controls (e.g. the quick-launch
        // button top-right). The shadow stays outside the clip.
        let contentClip = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: 0
        )
        return shape
            .fill(Color.black)
            .overlay(content.clipShape(contentClip))
            .frame(width: islandWidth, height: islandHeight)
            .shadow(color: .black.opacity(viewModel.isExpanded ? 0.45 : 0.25), radius: 10, y: 4)
    }

    @ViewBuilder private var content: some View {
        if viewModel.isExpanded {
            ExpandedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf, capture: capture)
                .transition(.notchContent)
        } else if let activity = activities.current {
            ActivityCompactView(activity: activity)
                .foregroundStyle(.white)
                .transition(.notchContent)
        } else {
            CollapsedView(viewModel: viewModel, nowPlaying: nowPlaying, shelf: shelf)
                .foregroundStyle(.white)
                .transition(.notchContent)
        }
    }
}

private extension AnyTransition {
    /// Content transition decoupled from the silhouette spring: content grows in
    /// (opacity + subtle scale, slightly delayed) and fades out fast on collapse,
    /// so it never lingers outside the shrinking shape.
    static var notchContent: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .scale(scale: NotchLayout.contentMorphScale, anchor: .top))
                .animation(NotchLayout.contentInsertAnimation),
            removal: .opacity.animation(NotchLayout.contentRemoveAnimation)
        )
    }
}

/// Compact rendering of a live activity inside the collapsed pill.
private struct ActivityCompactView: View {
    let activity: NotchActivity

    private var isRoute: Bool { activity.kind == .audioRoute }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: activity.icon)
                // The audio-route icon is bumped up so a connecting device reads
                // clearly at a glance (the main "markant" ask).
                .font(.system(size: isRoute ? 17 : 12, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: isRoute ? 22 : 16)
            if let progress = activity.progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.18))
                        Capsule()
                            .fill(Color.white.opacity(0.9))
                            .frame(width: geo.size.width * CGFloat(min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 4)
            } else {
                Text(activity.title)
                    .font(.system(size: isRoute ? 12 : 11, weight: isRoute ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let detail = activity.detail {
                    BatteryBadge(text: detail)
                }
            }
        }
        .padding(.horizontal, isRoute ? 12 : 14)
    }
}

/// A small tinted battery pill (icon + percentage), tinted red/orange when low.
private struct BatteryBadge: View {
    let text: String

    private var level: Int? { Int(text.replacingOccurrences(of: "%", with: "")) }

    private var color: Color {
        switch level ?? 100 {
        case ..<15: return .red
        case ..<30: return .orange
        default: return .green
        }
    }

    private var symbol: String {
        switch level ?? 100 {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(color)
    }
}

private struct ExpandedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel
    @ObservedObject var capture: ObsidianCapture

    private var tabIndex: Int {
        NotchViewModel.Tab.allCases.firstIndex(of: viewModel.selectedTab) ?? 0
    }

    var body: some View {
        VStack(spacing: 8) {
            NotchTabBar(selection: $viewModel.selectedTab)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    QuickLaunchButton()
                }

            // A real pager: all tabs sit side by side and we slide the strip by the
            // selected index. This always pages in the correct direction (a `.move`
            // transition reads its direction at the wrong time when reversing).
            GeometryReader { geo in
                HStack(spacing: 0) {
                    NowPlayingView(nowPlaying: nowPlaying)
                        .frame(width: geo.size.width, height: geo.size.height)
                    ShelfView(shelf: shelf)
                        .frame(width: geo.size.width, height: geo.size.height)
                    CaptureView(capture: capture, viewModel: viewModel)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .offset(x: -CGFloat(tabIndex) * geo.size.width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .padding(.horizontal, 28)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .foregroundStyle(.white)
    }
}

private struct NotchTabBar: View {
    @Binding var selection: NotchViewModel.Tab

    var body: some View {
        HStack(spacing: 6) {
            tab(title: String(localized: "tab.music", defaultValue: "Musik"), icon: "music.note", value: .music)
            tab(title: String(localized: "tab.files", defaultValue: "Ablage"), icon: "tray.full", value: .files)
            tab(title: String(localized: "tab.capture", defaultValue: "Capture"), icon: "square.and.pencil", value: .capture)
        }
    }

    private func tab(title: String, icon: String, value: NotchViewModel.Tab) -> some View {
        Button {
            guard selection != value else { return }
            Haptics.perform(.alignment)
            withAnimation(NotchLayout.tabChangeAnimation) { selection = value }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(
                Capsule().fill(Color.white.opacity(selection == value ? 0.18 : 0))
            )
            .foregroundStyle(.white.opacity(selection == value ? 1 : 0.55))
        }
        .buttonStyle(.plain)
    }
}

/// Quick-launch action: opens Terminal in the wiki-os vault and starts Claude
/// Code, so tasks can be knocked out fast without leaving the notch.
private enum QuickLaunch {
    /// Relative to the user's home directory.
    static let vaultPath = "Documents/Obsidian/wiki-os"

    static func openClaudeInVault() {
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(vaultPath) && claude"
        end tell
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    /// The real Obsidian app icon if installed, otherwise nil (caller falls back to an SF Symbol).
    static var obsidianIcon: NSImage? {
        let candidates = [
            "/Applications/Obsidian.app",
            "\(NSHomeDirectory())/Applications/Obsidian.app",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return nil
    }
}

private struct QuickLaunchButton: View {
    var body: some View {
        Button {
            Haptics.perform(.alignment)
            QuickLaunch.openClaudeInVault()
        } label: {
            Group {
                if let icon = QuickLaunch.obsidianIcon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "terminal")
                        .resizable().scaledToFit()
                        .padding(3)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Claude Code im Wiki-OS-Vault öffnen")
    }
}

private struct CollapsedView: View {
    @ObservedObject var viewModel: NotchViewModel
    @ObservedObject var nowPlaying: NowPlayingManager
    @ObservedObject var shelf: FileShelfModel

    /// Idle glyph reflects the tab you'd return to, so it isn't always the music
    /// note when you last used another tab.
    private var idleIcon: String {
        switch viewModel.selectedTab {
        case .music: return "music.note"
        case .files: return "tray.full"
        case .capture: return "square.and.pencil"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if nowPlaying.isPlaying, let url = nowPlaying.track?.artworkURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.1)
                }
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                WaveBarsView(isActive: nowPlaying.screensAwake, count: 3, maxHeight: 12, barWidth: 2.5, spacing: 2)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: idleIcon)
                    .font(.system(size: 11))
            }

            if !shelf.items.isEmpty {
                Label("\(shelf.items.count)", systemImage: "tray.full.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .padding(.horizontal, 10)
    }
}
