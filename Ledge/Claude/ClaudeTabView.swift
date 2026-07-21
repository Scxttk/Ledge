import SwiftUI

/// The "Claude" tab: usage windows on the left, the gear shifter (model ×
/// effort, H-pattern like a car gearbox) plus the mode button on the right.
struct ClaudeTabView: View {
    @ObservedObject var usage: ClaudeUsageModel
    @ObservedObject var driver: ClaudeSessionDriver
    /// True while this page is the selected tab — all carousel pages stay
    /// mounted, so `onAppear` alone would fetch on every expand, not on tab
    /// selection. The usage fetch keys off this instead.
    var isFront: Bool

    var body: some View {
        HStack(alignment: .top, spacing: NotchLayout.claudeColumnSpacing) {
            usageColumn
                .frame(maxWidth: .infinity, alignment: .leading)
            if ClaudeSessionDriver.isClaudeAppInstalled {
                VStack(spacing: NotchLayout.claudeShifterModeSpacing) {
                    ClaudeShifterView(driver: driver, showsFableLane: usage.hasFableBucket)
                    modeButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { if isFront { usage.refreshIfStale() } }
        .onChange(of: isFront) { _, front in
            if front { usage.refreshIfStale() }
        }
    }

    // MARK: Usage

    @ViewBuilder private var usageColumn: some View {
        switch usage.status {
        case .noCredentials:
            usageMessage(String(localized: "claude.usage.noCredentials",
                                defaultValue: "Kein Claude-Code-Login gefunden."))
        case .tokenExpired:
            usageMessage(String(localized: "claude.usage.tokenExpired",
                                defaultValue: "Token abgelaufen — Claude kurz benutzen."))
        case .rateLimited where usage.windows.isEmpty:
            usageMessage(String(localized: "claude.usage.rateLimited",
                                defaultValue: "Rate-Limit — später erneut."))
        case .failed where usage.windows.isEmpty:
            usageMessage(String(localized: "claude.usage.failed",
                                defaultValue: "Usage nicht abrufbar."))
        case .loading, .idle:
            usageMessage(String(localized: "claude.usage.loading", defaultValue: "Lade Usage …"))
        default:
            VStack(alignment: .leading, spacing: NotchLayout.claudeUsageRowSpacing) {
                ForEach(usage.windows) { window in
                    UsageRow(window: window)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func usageMessage(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
    }

    // MARK: Mode

    private var modeButton: some View {
        Button {
            Haptics.perform(.alignment)
            driver.cycleMode()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9, weight: .semibold))
                Text(driver.currentMode)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 10)
            .background(Capsule().fill(Color.white.opacity(0.12)))
            .foregroundStyle(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
        .help(String(localized: "claude.mode.help",
                     defaultValue: "Modus wechseln (Shift+Tab in Claude). Lange drücken: Anzeige zurücksetzen."))
        // The real mode is unknowable from outside; long-press re-syncs the
        // label to the cycle start without sending anything.
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in
            driver.resetModeDisplay()
        })
    }
}

/// One usage window: label + percent up top, capacity bar, reset time below.
private struct UsageRow: View {
    let window: ClaudeUsageWindow

    private var color: Color {
        switch window.utilization {
        case ..<0.6: return .green
        case ..<0.85: return .orange
        default: return .red
        }
    }

    private var resetText: String? {
        guard let date = window.resetsAt else { return nil }
        let relative = date.formatted(.relative(presentation: .named))
        return String(localized: "claude.usage.reset", defaultValue: "Reset \(relative)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.localizedLabel)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 8)
                Text(window.utilization.formatted(.percent.precision(.fractionLength(0))))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(color)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(color)
                        .frame(width: max(geo.size.width * window.utilization, 3))
                }
            }
            .frame(height: NotchLayout.claudeUsageBarHeight)
            if let resetText {
                Text(resetText)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}

/// The gearbox: model lanes side by side, effort front-to-back (low at the
/// top, high at the bottom), knob snaps into gates like a stick shift.
struct ClaudeShifterView: View {
    @ObservedObject var driver: ClaudeSessionDriver
    /// Extra "Fable" lane while the plan still reports a Fable bucket.
    let showsFableLane: Bool

    /// (command for `/model`, lane caption)
    private var models: [(id: String, label: String)] {
        // Official Claude Code aliases — they resolve to the newest model of
        // each family, so no version pinning ("opus" → Opus 4.8 today).
        var lanes = [("haiku", "Haiku"), ("sonnet", "Sonnet"), ("opus", "Opus")]
        if showsFableLane { lanes.append(("fable", "Fable")) }
        return lanes
    }
    private let efforts = ["low", "medium", "high"]

    /// Live knob position while dragging, in gate coordinates (lane, row).
    @State private var dragPosition: CGPoint?

    private var laneCount: Int { models.count }

    private var currentLane: Int {
        models.firstIndex { $0.id == driver.currentModel } ?? 1
    }
    private var currentRow: Int {
        efforts.firstIndex(of: driver.currentEffort ?? "") ?? 1
    }

    var body: some View {
        VStack(spacing: 4) {
            gearbox
            Text(gearLabel)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
    }

    private var gearLabel: String {
        if let model = driver.currentModel, let effort = driver.currentEffort {
            let lane = models.first { $0.id == model }?.label ?? model
            return "\(lane) · \(effort)"
        }
        return String(localized: "claude.shifter.neutral", defaultValue: "Neutral")
    }

    private var gearbox: some View {
        let width = NotchLayout.claudeShifterLaneSpacing * CGFloat(laneCount - 1)
            + NotchLayout.claudeShifterPadding * 2
        let height = NotchLayout.claudeShifterRowSpacing * 2 + NotchLayout.claudeShifterPadding * 2

        return ZStack {
            // Gate plate: vertical slot per lane, horizontal crossbar through
            // the middle row — the classic H-pattern.
            GeometryReader { geo in
                let slots = slotFrame(in: geo.size)
                Path { path in
                    for lane in 0..<laneCount {
                        let x = slots.minX + CGFloat(lane) * NotchLayout.claudeShifterLaneSpacing
                        path.move(to: CGPoint(x: x, y: slots.minY))
                        path.addLine(to: CGPoint(x: x, y: slots.maxY))
                    }
                    path.move(to: CGPoint(x: slots.minX, y: slots.midY))
                    path.addLine(to: CGPoint(x: slots.maxX, y: slots.midY))
                }
                .stroke(
                    Color.white.opacity(0.22),
                    style: StrokeStyle(lineWidth: NotchLayout.claudeShifterSlotWidth, lineCap: .round)
                )

                // Lane captions under the plate.
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    Text(model.label)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(index == currentLane && driver.currentModel != nil ? 0.9 : 0.4))
                        .position(
                            x: slots.minX + CGFloat(index) * NotchLayout.claudeShifterLaneSpacing,
                            y: slots.maxY + 10
                        )
                }

                knob(in: slots)
            }
            // One drag surface over the whole plate (not just the 20-pt knob):
            // grab anywhere and the knob comes to the finger — the tiny-knob
            // precision grab was the "schwer zu bedienen" complaint.
            .contentShape(Rectangle())
            .gesture(shiftGesture)
        }
        .frame(width: width, height: height + 14)
        .coordinateSpace(name: "shifter")
    }

    private var shiftGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("shifter"))
            .onChanged { value in
                let slots = slotFrame(in: .zero)  // grid metrics are size-independent
                // Follow the finger on the rails: y is free within the slot,
                // x snaps to the nearest lane except near the crossbar, where
                // lane changes happen.
                let x = min(max(value.location.x, slots.minX), slots.maxX)
                let y = min(max(value.location.y, slots.minY), slots.maxY)
                let nearestLaneX = slots.minX
                    + round((x - slots.minX) / NotchLayout.claudeShifterLaneSpacing)
                    * NotchLayout.claudeShifterLaneSpacing
                let nearCrossbar = abs(y - slots.midY) < NotchLayout.claudeShifterRowSpacing / 3
                dragPosition = nearCrossbar ? CGPoint(x: x, y: slots.midY) : CGPoint(x: nearestLaneX, y: y)
            }
            .onEnded { value in
                let slots = slotFrame(in: .zero)
                let x = min(max(value.location.x, slots.minX), slots.maxX)
                let y = min(max(value.location.y, slots.minY), slots.maxY)
                let lane = Int(round((x - slots.minX) / NotchLayout.claudeShifterLaneSpacing))
                let row = Int(round((y - slots.minY) / NotchLayout.claudeShifterRowSpacing))
                withAnimation(.spring(duration: 0.25)) { dragPosition = nil }
                engage(lane: lane, row: row)
            }
    }

    /// The area the slot endpoints span (gates sit on this grid). Pure
    /// constants — independent of the proposed size.
    private func slotFrame(in size: CGSize) -> CGRect {
        CGRect(
            x: NotchLayout.claudeShifterPadding,
            y: NotchLayout.claudeShifterPadding,
            width: NotchLayout.claudeShifterLaneSpacing * CGFloat(laneCount - 1),
            height: NotchLayout.claudeShifterRowSpacing * 2
        )
    }

    private func gatePoint(lane: Int, row: Int, in slots: CGRect) -> CGPoint {
        CGPoint(
            x: slots.minX + CGFloat(lane) * NotchLayout.claudeShifterLaneSpacing,
            y: slots.minY + CGFloat(row) * NotchLayout.claudeShifterRowSpacing
        )
    }

    private func knob(in slots: CGRect) -> some View {
        let resting = gatePoint(lane: currentLane, row: currentRow, in: slots)
        let position = dragPosition ?? resting
        return Circle()
            .fill(
                RadialGradient(
                    colors: [Color.white.opacity(0.95), Color(white: 0.55)],
                    center: .init(x: 0.35, y: 0.3),
                    startRadius: 1,
                    endRadius: NotchLayout.claudeShifterKnobSize / 2
                )
            )
            .overlay(Circle().strokeBorder(Color.black.opacity(0.4), lineWidth: 1))
            .frame(width: NotchLayout.claudeShifterKnobSize, height: NotchLayout.claudeShifterKnobSize)
            .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
            .position(position)
            .allowsHitTesting(false)
            .animation(.spring(duration: 0.25), value: driver.currentModel)
            .animation(.spring(duration: 0.25), value: driver.currentEffort)
    }

    private func engage(lane: Int, row: Int) {
        let model = models[min(max(lane, 0), laneCount - 1)].id
        let effort = efforts[min(max(row, 0), efforts.count - 1)]
        // No same-gear guard: re-engaging the current gear resends the
        // commands on purpose — the session state is unknowable, so a retry
        // (e.g. after Claude wasn't running) must not be swallowed.
        Haptics.perform(.levelChange)
        driver.setGear(model: model, effort: effort)
    }
}
