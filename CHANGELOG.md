# Changelog

All notable changes to Ledge (the app formerly presenting itself as NotchMate —
the bundle still is, see the README for why).

## [1.3.0] – 2026-07-21

The polish release: better colors, bouncier motion, and one honest bug fix
that had been hiding since the spectrum tap learned to hear non-music audio.

### Added
- **Spectrum-only pill.** A new toggle in the now-playing settings replaces the
  mini cover in the collapsed pill with sixteen bars — one per analyzer band —
  in a wider, slightly taller pill. This mode exists to be watched, so it
  takes the room it needs. The music tab keeps its cover.
- **Claude tab**: usage limits at a glance plus a gearbox-style shifter for
  model/effort/mode of the Claude desktop app.
- **Per-tab visibility toggles** — hide the tabs you never open.
- **Focus-session tracking** in the pomodoro timer, logged to Obsidian.
- The "Cover" spectrum style now quantises each bar onto a real per-bar palette
  taken from the slice of artwork the bar sits over, with four tuning sliders
  (palette size, brightness steps, saturation, brightness). The old version
  masked a blurred cover and smeared neighbouring colors into every bar.

### Changed
- The app is called **Ledge** now. Bundle and targets stay `NotchMate` so
  macOS keeps honoring the Automation/Accessibility grants.
- Cover accents are tone-mapped instead of floored: muted sleeves stay muted
  instead of turning neon, black-and-white covers with a faint color cast get
  that cast as a washed-out tint instead of plain white, and the
  gradient/alternating styles use a second color the sleeve actually contains
  when it has one.
- The island opens with a visible overshoot-and-settle now, like the iPhone's.
  Closing stays deliberately calm — overshoot on the way out reads wrong.
- The spectrum analyzer resolves 16 bands (was 6), enough to feed the wide
  pill; the smaller waves bucket down as before.
- New original waveform app icon (the earlier one leaned on the Obsidian logo).

### Fixed
- The pill's hover and click areas now match what it draws. With only
  non-music audio playing (a YouTube tab, a call), the visible pill was wider
  than the area that reacted to the cursor — its outer edges were dead.
- Dragging a file onto the notch works again (broken by the click-through
  gate).
- Volume-key clicks and mute double-logging in the HUD.
- Two force-unwrap crashes that never fired but could have: the launch-path
  directory lookup and the Accessibility menu-bar walk now degrade instead.

## [1.2.1] – 2026-07-06

- **Fixed** the collapsed notch stealing focus from apps under its hidden
  footprint — clicking "through" the invisible expanded area now reaches the
  app you actually see.
- **Fixed** a spectrum freeze (the tap tore itself down from its own IO queue)
  and rebuilt the tap when the output device changes, so AirPods handoffs
  don't silence the bars.
- **Added** pomodoro timers with named presets, a passive readout in the pill,
  and optional auto-chaining. Yes, that's a feature in a patch release.

## [1.2.0] – 2026-07-06

- **Added** menu-bar overlap detection: when the frontmost app's menus reach
  the notch, the pill hides instead of fighting them for the pixels.
- **Added** cover-aware spectrum colors — the wave tints itself from the
  album artwork.
- **Fixed** a batch of hover/collapse edge cases and hardened the capture
  tab's link output and track-open behavior.

## [1.1.0] – 2026-07-04

- **Changed** the notch into a detached, iPhone-style island with a staged
  expand/collapse morph — the version where it started looking like the thing
  it's imitating.
- **Changed** the music tab: live audio spectrum from a system tap, and the
  now-playing hero collapses into the pill.
- **Changed** the capture tab into a compact pill with vault label and quick
  actions.
- **Fixed** the volume HUD popping open on its own.

## [1.0.0] – 2026-07-02

First release: now-playing controls in the notch, file shelf with drag & drop,
Obsidian quick capture, live activities (battery, audio routes), and a
volume/brightness HUD that replaces Apple's gray OSD.

[1.3.0]: https://github.com/Scxttk/Ledge/compare/v1.2.1...v1.3.0
[1.2.1]: https://github.com/Scxttk/Ledge/compare/v1.2.0...v1.2.1
[1.2.0]: https://github.com/Scxttk/Ledge/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/Scxttk/Ledge/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/Scxttk/Ledge/releases/tag/v1.0.0
