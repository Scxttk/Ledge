import XCTest
import SwiftUI
@testable import Ledge

/// Frame-by-frame view of the island's expand/collapse choreography, without
/// pointing a camera at the screen: a small retargetable spring solver drives
/// the silhouette (width/height/corner radius) through the exact stage walk
/// `NotchWindowController.advanceStaging` performs — same `NotchLayout`
/// constants, same rest delays, same per-hop animations — and every frame is
/// rendered into a contact sheet plus a time/width curve plot under
/// `/tmp/notchmate-wavebars/choreography/`. The plot is where stutters live:
/// a flat shelf mid-walk is a visible pause, a kink is a hard retarget.
@MainActor
final class IslandChoreographySheetTests: XCTestCase {

    private static let outputDirectory = URL(
        fileURLWithPath: "/tmp/notchmate-wavebars/choreography", isDirectory: true)

    // MARK: Spring solver

    /// One animated scalar, integrated with the same physics SwiftUI's springs
    /// use (`stiffness = (2π/response)²`, `damping = 2ζ·2π/response`, mass 1).
    /// Retargeting keeps position *and* velocity, exactly like SwiftUI merging
    /// a new `withAnimation` onto a moving property.
    private struct SpringTrack {
        private(set) var value: Double
        private(set) var velocity: Double = 0
        private(set) var target: Double
        private var stiffness: Double = 0
        private var damping: Double = 0
        private var animating = false

        init(at value: Double) {
            self.value = value
            self.target = value
        }

        mutating func retarget(_ newTarget: Double, response: Double, dampingFraction: Double) {
            guard newTarget != target else { return }  // withAnimation only animates changed values
            target = newTarget
            let omega = 2 * Double.pi / response
            stiffness = omega * omega
            damping = 2 * dampingFraction * omega
            animating = true
        }

        mutating func snap(to newValue: Double) {
            value = newValue
            target = newValue
            velocity = 0
            animating = false
        }

        mutating func step(_ dt: Double) {
            guard animating else { return }
            let steps = max(1, Int((dt / 0.0005).rounded()))
            let h = dt / Double(steps)
            for _ in 0..<steps {
                let accel = stiffness * (target - value) - damping * velocity
                velocity += accel * h
                value += velocity * h
            }
            if abs(value - target) < 0.05, abs(velocity) < 0.5 {
                snap(to: target)
            }
        }
    }

    /// The spring parameters behind the `NotchLayout` animation constants.
    /// (`Animation` doesn't expose its curve, so these mirror the definitions:
    /// `.smooth(d)` ≈ spring(response: d, ζ 1.0); `.snappy(d, extraBounce: b)`
    /// ≈ spring(response: d, ζ 0.85 − b).)
    private enum Curve {
        static let expandHop = (response: 0.30, damping: 0.75)      // islandExpandAnimation
        static let expandFinal = (response: 0.42, damping: 0.70)    // islandExpandFinalAnimation
        static let collapseHop = (response: 0.55, damping: 1.0)     // islandCollapseAnimation
    }

    // MARK: Walk simulation

    private struct StageEvent {
        let time: Double
        let state: NotchViewModel.IslandState
        let width: Double
        let height: Double
        let corner: Double
        /// nil = state set without `withAnimation` (the pill handover).
        let curve: (response: Double, damping: Double)?
        let label: String
    }

    private struct Frame {
        let time: Double
        let width: Double
        let height: Double
        let corner: Double
        let stageLabel: String
    }

    private struct Walk {
        let name: String
        let events: [StageEvent]
        let frames: [Frame]
    }

    private func geometry(
        of state: NotchViewModel.IslandState, viewModel: NotchViewModel, hero: Bool
    ) -> (width: Double, height: Double, corner: Double) {
        let pillWidth = viewModel.collapsedWidth(isPlaying: hero, hasItems: false, timerText: nil)
        let width: CGFloat
        switch state {
        case .expanded:   width = viewModel.expandedWidth
        case .band:       width = NotchLayout.bandWidth
        case .solo:       width = hero ? pillWidth : viewModel.soloWidth(for: .music)
        case .condensing: width = pillWidth
        case .collapsed:  width = pillWidth
        }
        let expanded = state == .expanded
        return (
            Double(width),
            Double(expanded ? viewModel.expandedHeight : viewModel.collapsedHeight),
            Double(expanded ? NotchLayout.expandedCornerRadius : viewModel.collapsedHeight / 2)
        )
    }

    /// Build the event list the controller would produce for a full staged
    /// walk in one direction — stage rest delays from `stageRestDelay`,
    /// per-hop animation choice from `advanceStaging`.
    private func walkEvents(expanding: Bool, viewModel: NotchViewModel, hero: Bool) -> [StageEvent] {
        let order: [NotchViewModel.IslandState] =
            [.collapsed, .condensing, .solo, .band, .expanded]
        let path = expanding ? Array(order.dropFirst()) : Array(order.dropLast().reversed())

        var events: [StageEvent] = []
        var t = 0.0
        for state in path {
            let geo = geometry(of: state, viewModel: viewModel, hero: hero)
            let curve: (response: Double, damping: Double)?
            if state == .collapsed {
                curve = nil  // handover: no withAnimation
            } else if expanding {
                curve = state == .expanded ? Curve.expandFinal : Curve.expandHop
            } else {
                curve = Curve.collapseHop
            }
            events.append(StageEvent(
                time: t, state: state,
                width: geo.width, height: geo.height, corner: geo.corner,
                curve: curve, label: "\(state)"
            ))
            t += restDelay(entering: state, expanding: expanding, hero: hero)
        }
        return events
    }

    /// Mirrors `NotchWindowController.stageRestDelay`, including the hero
    /// no-op stage skip.
    private func restDelay(entering state: NotchViewModel.IslandState, expanding: Bool, hero: Bool) -> Double {
        switch (state, expanding) {
        case (.band, false):       return NotchLayout.bandCollapseDelay
        case (.solo, false):       return NotchLayout.soloCollapseDelay
        case (.condensing, false): return hero ? 0 : NotchLayout.condenseSwapDelay
        case (.condensing, true):  return hero ? 0 : NotchLayout.condenseExpandDelay
        case (.solo, true):        return hero ? 0 : NotchLayout.soloExpandDelay
        case (.band, true):        return NotchLayout.bandExpandDelay
        default:                   return 0
        }
    }

    private func simulate(name: String, expanding: Bool, viewModel: NotchViewModel, hero: Bool) -> Walk {
        let events = walkEvents(expanding: expanding, viewModel: viewModel, hero: hero)
        let start = geometry(
            of: expanding ? .collapsed : .expanded, viewModel: viewModel, hero: hero)

        var width = SpringTrack(at: start.width)
        var height = SpringTrack(at: start.height)
        var corner = SpringTrack(at: start.corner)

        let dt = 1.0 / 240.0
        let tail = 0.8  // keep sampling past the last event so the settle shows
        let duration = (events.last?.time ?? 0) + tail
        var frames: [Frame] = []
        var nextEvent = 0
        var stageLabel = "\(expanding ? "collapsed" : "expanded")"

        var t = 0.0
        while t <= duration {
            while nextEvent < events.count, events[nextEvent].time <= t + dt / 2 {
                let e = events[nextEvent]
                stageLabel = e.label
                if let curve = e.curve {
                    width.retarget(e.width, response: curve.response, dampingFraction: curve.damping)
                    height.retarget(e.height, response: curve.response, dampingFraction: curve.damping)
                    corner.retarget(e.corner, response: curve.response, dampingFraction: curve.damping)
                } else {
                    // No withAnimation: an unchanged value stays put, a changed
                    // one would snap — exactly what the code does at .collapsed.
                    if width.target != e.width { width.snap(to: e.width) }
                    if height.target != e.height { height.snap(to: e.height) }
                    if corner.target != e.corner { corner.snap(to: e.corner) }
                }
                nextEvent += 1
            }
            frames.append(Frame(
                time: t, width: width.value, height: height.value,
                corner: corner.value, stageLabel: stageLabel
            ))
            width.step(dt)
            height.step(dt)
            corner.step(dt)
            t += dt
        }
        return Walk(name: name, events: events, frames: frames)
    }

    // MARK: Content lanes

    /// Opacity/progress curves of the content layers during the *expand* walk,
    /// modelled from the transition clocks in `NotchView`/`NotchLayout`. This
    /// is where the "icon overlap" class of bug lives: the silhouette can be
    /// perfectly smooth while two content layers paint over each other.
    private struct ContentLane {
        let label: String
        let color: Color
        let value: (Double) -> Double
    }

    private func easeIn(_ t: Double) -> Double { t <= 0 ? 0 : t >= 1 ? 1 : t * t }
    private func easeOut(_ t: Double) -> Double { t <= 0 ? 0 : t >= 1 ? 1 : 1 - (1 - t) * (1 - t) }
    private func easeInOut(_ t: Double) -> Double {
        t <= 0 ? 0 : t >= 1 ? 1 : t * t * (3 - 2 * t)
    }

    /// The selected icon's flight from the capsule centre to its slot: driven
    /// by the band hop's spring, retargeted by the final hop — same solver as
    /// the silhouette.
    private func flightCurve(bandTime: Double, expandedTime: Double, duration: Double) -> [Double] {
        var track = SpringTrack(at: 0)
        let dt = 1.0 / 240.0
        var values: [Double] = []
        var t = 0.0
        while t <= duration {
            if abs(t - bandTime) < dt / 2 {
                track.retarget(0.8, response: Curve.expandHop.response, dampingFraction: Curve.expandHop.damping)
            }
            if abs(t - expandedTime) < dt / 2 {
                track.retarget(1.0, response: Curve.expandFinal.response, dampingFraction: Curve.expandFinal.damping)
            }
            values.append(track.value)
            track.step(dt)
            t += dt
        }
        return values
    }

    private func expandLanes(for walk: Walk, hero: Bool) -> [ContentLane] {
        let duration = walk.frames.last?.time ?? 1
        let bandTime = walk.events.first { $0.state == .band }?.time ?? 0
        let expandedTime = walk.events.first { $0.state == .expanded }?.time ?? 0

        if hero {
            // Hero: the whole tab bar crossfades in against the departing wave.
            let fadeOut = NotchLayout.heroCrossfadeDuration
            let delay = NotchLayout.heroCrossfadeInsertDelay
            return [
                ContentLane(label: "wave out", color: .orange) { [self] t in
                    1 - easeInOut((t - bandTime) / fadeOut)
                },
                ContentLane(label: "tab bar in", color: .green) { [self] t in
                    easeInOut((t - bandTime - delay) / fadeOut)
                },
            ]
        }

        // Idle: pill icon hands over to the (identical) tab icon via a hard
        // cut at walk start, the tab icon flies to its slot, and the other
        // tabs join once the flight is home.
        let flight = flightCurve(bandTime: bandTime, expandedTime: expandedTime, duration: duration)
        let joinStart = bandTime + NotchLayout.tabJoinFadeDelay
        let joinFade = 0.15  // condenseFadeAnimation
        return [
            ContentLane(label: "pill icon (ghost)", color: .red) { t in
                t < 0 ? 1 : 0  // hard cut: gone the instant the walk starts
            },
            ContentLane(label: "icon flight", color: .white) { t in
                let index = Int(t * 240)
                return index < flight.count ? flight[index] : 1
            },
            ContentLane(label: "other tabs", color: .green) { [self] t in
                easeOut((t - joinStart) / joinFade)
            },
        ]
    }

    // MARK: Rendering

    /// Width/height-vs-time plot with stage markers — pauses and kinks are
    /// obvious here in a way single frames can't show.
    private func plotView(for walk: Walk) -> some View {
        let plotW = 860.0, plotH = 240.0, padL = 46.0, padR = 14.0, padT = 30.0, padB = 34.0
        let duration = walk.frames.last?.time ?? 1
        let maxW = 470.0
        func x(_ t: Double) -> Double { padL + (plotW - padL - padR) * t / duration }
        func yW(_ w: Double) -> Double { padT + (plotH - padT - padB) * (1 - w / maxW) }
        func yH(_ h: Double) -> Double { padT + (plotH - padT - padB) * (1 - h / maxW) }

        return Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: plotW, height: plotH)), with: .color(.black))

            // Stage markers.
            for event in walk.events {
                var line = Path()
                line.move(to: CGPoint(x: x(event.time), y: padT - 4))
                line.addLine(to: CGPoint(x: x(event.time), y: plotH - padB))
                context.stroke(line, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                context.draw(
                    Text(event.label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.7)),
                    at: CGPoint(x: x(event.time) + 2, y: padT - 14), anchor: .leading
                )
            }
            // 100 ms grid.
            var tick = 0.0
            while tick <= duration {
                context.draw(
                    Text(String(format: "%.1f", tick)).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)),
                    at: CGPoint(x: x(tick), y: plotH - padB + 10), anchor: .center
                )
                tick += 0.1
            }

            func stroke(_ series: [(Double, Double)], color: Color) {
                var path = Path()
                for (i, point) in series.enumerated() {
                    let p = CGPoint(x: point.0, y: point.1)
                    if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.6)
            }
            stroke(walk.frames.map { (x($0.time), yW($0.width)) }, color: .cyan)
            stroke(walk.frames.map { (x($0.time), yH($0.height)) }, color: .orange)

            context.draw(
                Text("\(walk.name)   —   width (cyan) / height (orange), stage markers dashed")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white),
                at: CGPoint(x: padL, y: 10), anchor: .leading
            )
        }
        .frame(width: plotW, height: plotH)
    }

    /// Opacity/progress lanes over time for the expand content choreography.
    private func lanesView(for walk: Walk, lanes: [ContentLane]) -> some View {
        let plotW = 860.0, plotH = 200.0, padL = 46.0, padR = 14.0, padT = 30.0, padB = 34.0
        let duration = walk.frames.last?.time ?? 1
        func x(_ t: Double) -> Double { padL + (plotW - padL - padR) * t / duration }
        func y(_ v: Double) -> Double { padT + (plotH - padT - padB) * (1 - v) }

        return Canvas { context, _ in
            context.fill(Path(CGRect(x: 0, y: 0, width: plotW, height: plotH)), with: .color(.black))
            for event in walk.events {
                var line = Path()
                line.move(to: CGPoint(x: x(event.time), y: padT - 4))
                line.addLine(to: CGPoint(x: x(event.time), y: plotH - padB))
                context.stroke(line, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            var tick = 0.0
            while tick <= duration {
                context.draw(
                    Text(String(format: "%.1f", tick)).font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)),
                    at: CGPoint(x: x(tick), y: plotH - padB + 10), anchor: .center
                )
                tick += 0.1
            }
            for (index, lane) in lanes.enumerated() {
                var path = Path()
                var t = 0.0
                var first = true
                while t <= duration {
                    let p = CGPoint(x: x(t), y: y(lane.value(t)))
                    if first { path.move(to: p); first = false } else { path.addLine(to: p) }
                    t += 1.0 / 240.0
                }
                context.stroke(path, with: .color(lane.color), lineWidth: 1.6)
                context.draw(
                    Text(lane.label).font(.system(size: 10, weight: .semibold)).foregroundStyle(lane.color),
                    at: CGPoint(x: padL + 4 + Double(index) * 150, y: 12), anchor: .leading
                )
            }
            context.draw(
                Text("\(walk.name) — content lanes").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white),
                at: CGPoint(x: padL, y: padT - 22), anchor: .leading
            )
        }
        .frame(width: plotW, height: plotH)
    }

    /// Filmstrip of silhouettes at 30 fps, timestamped — what the eye would see.
    private func filmstripView(for walk: Walk) -> some View {
        let fps = 30.0
        let sampled = stride(from: 0.0, through: walk.frames.last?.time ?? 0, by: 1 / fps).map { t in
            walk.frames.min(by: { abs($0.time - t) < abs($1.time - t) })!
        }
        let scale = 0.42
        let cellW = 460.0 * scale + 8, cellH = 212.0 * scale + 22
        let columns = 6

        return VStack(alignment: .leading, spacing: 4) {
            Text("\(walk.name) — 30 fps").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            ForEach(0..<((sampled.count + columns - 1) / columns), id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<columns, id: \.self) { col in
                        let index = row * columns + col
                        if index < sampled.count {
                            let f = sampled[index]
                            VStack(spacing: 2) {
                                ZStack(alignment: .top) {
                                    Color.clear
                                    RoundedRectangle(cornerRadius: f.corner * scale, style: .continuous)
                                        .fill(Color.black)
                                        .frame(width: f.width * scale, height: f.height * scale)
                                }
                                .frame(width: cellW - 8, height: cellH - 20, alignment: .top)
                                Text(String(format: "%.2fs %@", f.time, f.stageLabel))
                                    .font(.system(size: 7)).foregroundStyle(.black.opacity(0.7))
                            }
                            .frame(width: cellW, height: cellH)
                            .background(Color(white: 0.75))
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(white: 0.6))
    }

    /// Composite filmstrip: silhouette *and* content layers together, drawn
    /// from the same curves — the closest thing to the real screen this
    /// harness can produce. "Feels slightly buggy" lives here: each layer can
    /// be individually correct while their composition looks broken.
    private func compositeStripView(for walk: Walk, hero: Bool) -> some View {
        let fps = 30.0
        let duration = walk.frames.last?.time ?? 0
        let sampled = stride(from: 0.0, through: duration, by: 1 / fps).map { t in
            walk.frames.min(by: { abs($0.time - t) < abs($1.time - t) })!
        }
        let lanes = expandLanes(for: walk, hero: hero)
        let expandedTime = walk.events.first { $0.state == .expanded }?.time ?? 0
        let pageIn: (Double) -> Double = { [self] t in
            easeOut((t - expandedTime - NotchLayout.pagesSettleDelay - 0.05) / 0.35)
        }
        let scale = 0.42
        let cellW = 460.0 * scale + 8, cellH = 212.0 * scale + 22
        let columns = 6
        let rows = (sampled.count + columns - 1) / columns
        let width = Double(columns) * (cellW + 4) + 16
        let height = Double(rows) * (cellH + 4) + 30

        return Canvas { ctx, _ in
            ctx.fill(Path(CGRect(x: 0, y: 0, width: width, height: height)), with: .color(Color(white: 0.62)))
            ctx.draw(
                Text("\(walk.name) — composite, 30 fps").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white),
                at: CGPoint(x: 10, y: 12), anchor: .leading
            )
            for (i, f) in sampled.enumerated() {
                let col = i % columns, row = i / columns
                let ox = 8 + Double(col) * (cellW + 4)
                let oy = 24 + Double(row) * (cellH + 4)
                let cx = ox + cellW / 2
                let island = CGRect(
                    x: cx - f.width * scale / 2, y: oy,
                    width: f.width * scale, height: f.height * scale
                )
                let shape = Path(roundedRect: island, cornerRadius: f.corner * scale)
                ctx.fill(shape, with: .color(.black))

                ctx.drawLayer { layer in
                    layer.clip(to: shape)
                    let bandY = oy + 15 * scale  // centre of the pill/tab band

                    func dot(_ x: Double, _ opacity: Double, _ color: Color = .white) {
                        guard opacity > 0.01 else { return }
                        let r = 5.5 * scale
                        layer.fill(
                            Path(ellipseIn: CGRect(x: x - r, y: bandY - r, width: 2 * r, height: 2 * r)),
                            with: .color(color.opacity(opacity)))
                    }
                    let slots = (0..<5).map { cx + (Double($0) - 2) * 62 * scale }

                    if hero {
                        // Departing wave (9 bars, 74 pt), arriving tab dots.
                        let waveOut = lanes[0].value(f.time)
                        if waveOut > 0.01 {
                            let heights: [Double] = [0.4, 0.7, 1.0, 0.6, 0.9, 0.5, 0.8, 0.45, 0.65]
                            for (b, hgt) in heights.enumerated() {
                                let bx = cx + (Double(b) - 4) * 8.5 * scale
                                let bh = 18 * scale * hgt
                                layer.fill(
                                    Path(roundedRect: CGRect(x: bx - 1.2, y: bandY - bh / 2, width: 2.4, height: bh), cornerRadius: 1.2),
                                    with: .color(Color.cyan.opacity(waveOut)))
                            }
                        }
                        let tabsIn = lanes[1].value(f.time)
                        for slot in slots { dot(slot, tabsIn) }
                    } else {
                        // Ghost at centre, selected icon flying to slot 0,
                        // the other tabs joining at their slots.
                        dot(cx, lanes[0].value(f.time), .red)
                        let flight = lanes[1].value(f.time)
                        dot(cx + (slots[0] - cx) * flight, 1.0)
                        let others = lanes[2].value(f.time)
                        for slot in slots.dropFirst() { dot(slot, others, .green) }
                    }

                    // The page content growing in below the band.
                    let pages = pageIn(f.time)
                    if pages > 0.01 {
                        let inset = 16 * scale
                        let rect = CGRect(
                            x: island.minX + inset, y: oy + 34 * scale,
                            width: island.width - 2 * inset,
                            height: max(0, island.height - 34 * scale - 20 * scale))
                        layer.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(.white.opacity(0.16 * pages)))
                    }
                }
                ctx.draw(
                    Text(String(format: "%.2fs", f.time)).font(.system(size: 7)).foregroundStyle(.black.opacity(0.7)),
                    at: CGPoint(x: cx, y: oy + cellH - 8), anchor: .center
                )
            }
        }
        .frame(width: width, height: height)
    }

    private func write<V: View>(_ view: V, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "\(name) failed to render")
        let rep = NSBitmapImageRep(cgImage: image)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: Self.outputDirectory.appendingPathComponent("\(name).png"))
    }

    // MARK: Tests

    func testRenderExpandAndCollapseChoreography() throws {
        try FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)

        let settings = UserSettings.shared
        let originalOnly = settings.pillSpectrumOnly
        let originalWidth = settings.pillSpectrumWidth
        defer {
            settings.pillSpectrumOnly = originalOnly
            settings.pillSpectrumWidth = originalWidth
        }
        // Scott's real configuration: spectrum-only pill, 74 pt wave.
        settings.pillSpectrumOnly = true
        settings.pillSpectrumWidth = 74

        let viewModel = NotchViewModel()

        let walks = [
            simulate(name: "expand-hero", expanding: true, viewModel: viewModel, hero: true),
            simulate(name: "collapse-hero", expanding: false, viewModel: viewModel, hero: true),
            simulate(name: "expand-idle", expanding: true, viewModel: viewModel, hero: false),
            simulate(name: "collapse-idle", expanding: false, viewModel: viewModel, hero: false),
        ]

        for walk in walks {
            try write(plotView(for: walk), name: "plot-\(walk.name)")
            try write(filmstripView(for: walk), name: "strip-\(walk.name)")
            XCTAssertFalse(walk.frames.isEmpty)
        }

        // Content choreography on expand (the icon-overlap class of bug: the
        // silhouette can be smooth while two content layers paint over each
        // other — Scott saw the other tab icons appear under the still-flying
        // selected icon).
        let idleLanes = expandLanes(for: walks[2], hero: false)
        let heroLanes = expandLanes(for: walks[0], hero: true)
        try write(lanesView(for: walks[2], lanes: idleLanes), name: "lanes-expand-idle")
        try write(lanesView(for: walks[0], lanes: heroLanes), name: "lanes-expand-hero")
        try write(compositeStripView(for: walks[0], hero: true), name: "composite-expand-hero")
        try write(compositeStripView(for: walks[2], hero: false), name: "composite-expand-idle")

        let duration = walks[2].frames.last?.time ?? 1
        var t = 0.0
        while t <= duration {
            // Idle: the departing pill icon must be gone before the other tabs
            // start fading in, and the other tabs may only appear once the
            // selected icon's flight is essentially home.
            let ghost = idleLanes[0].value(t)
            let flight = idleLanes[1].value(t)
            let others = idleLanes[2].value(t)
            if others > 0.01 {
                XCTAssertEqual(ghost, 0, accuracy: 0.01,
                    "t=\(t): pill ghost still visible while other tabs fade in")
                XCTAssertGreaterThan(flight, 0.85,
                    "t=\(t): other tabs fading in while the selected icon is still mid-flight")
            }
            // The doubled-glyph bug: once the selected icon has visibly left
            // the centre, the departing pill icon must already be gone.
            if flight > 0.05 {
                XCTAssertLessThan(ghost, 0.05,
                    "t=\(t): pill ghost still visible while its twin is mid-flight")
            }
            // Hero: sequenced, not overlapped — the wave and the tab bar must
            // never be substantially visible at the same time.
            let waveOut = heroLanes[0].value(t)
            let tabsIn = heroLanes[1].value(t)
            XCTAssertFalse(waveOut > 0.25 && tabsIn > 0.25,
                "t=\(t): wave and tab bar visibly overlapping")
            t += 1.0 / 120.0
        }

        // Quantitative stutter check alongside the pictures: the longest span
        // mid-walk (between first and last stage event) where the width moves
        // less than 2 pt per 100 ms — a visible dead pause.
        var summary = ""
        for walk in walks {
            guard let first = walk.events.first?.time, let last = walk.events.last?.time else { continue }
            let mid = walk.frames.filter { $0.time >= first && $0.time <= last }
            var longestPause = 0.0
            var pauseStart: Double?
            for (a, b) in zip(mid, mid.dropFirst()) {
                let speed = abs(b.width - a.width) / (b.time - a.time)  // pt/s
                if speed < 20 {
                    pauseStart = pauseStart ?? a.time
                    longestPause = max(longestPause, b.time - (pauseStart ?? a.time))
                } else {
                    pauseStart = nil
                }
            }
            summary += String(format: "%@: longest mid-walk pause %.0f ms\n", walk.name, longestPause * 1000)
        }
        try summary.write(
            to: Self.outputDirectory.appendingPathComponent("summary.txt"),
            atomically: true, encoding: .utf8)
    }
}
