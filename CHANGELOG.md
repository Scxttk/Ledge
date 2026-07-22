# Changelog

All notable changes to Ledge (the app formerly presenting itself as NotchMate —
the bundle still is, see the README for why).

## [1.3.0] – 2026-07-21

The polish release: better colors, bouncier motion, and one honest bug fix
that had been hiding since the spectrum tap learned to hear non-music audio.

### Added
- **Spectrum-only pill.** A new toggle in the now-playing settings replaces the
  mini cover in the collapsed pill with a wider, slightly taller wave. This
  mode exists to be watched, so it takes the room it needs — and it comes with
  two controls: bar count (6–32, at 32 every bar is its own analyzer band) and
  pill width (36–140pt); the bars spread evenly, so fewer bars means wider
  gaps. The music tab keeps its cover.
- **Claude tab**: usage limits at a glance plus a gearbox-style shifter for
  model/effort/mode of the Claude desktop app.
- **Per-tab visibility toggles** — hide the tabs you never open.
- **Focus-session tracking** in the pomodoro timer, logged to Obsidian.
- The "Cover" spectrum style now quantises each bar onto a real per-bar palette
  taken from the slice of artwork the bar sits over, with four tuning sliders
  (palette size, brightness steps, saturation, brightness). The old version
  masked a blurred cover and smeared neighbouring colors into every bar.

### Changed
- The app is **Ledge** now, all the way down: project, targets and the app
  bundle itself (`Ledge.app`). Only two invisible legacies remain so existing
  installs keep their data — the bundle identifier (your settings) and the
  Application Support folder name (your shelf). Updating from a
  `NotchMate.app` build means granting Automation and Accessibility once
  more; the grants follow the app.
- Cover accents are tone-mapped instead of floored: muted sleeves stay muted
  instead of turning neon, black-and-white covers with a faint color cast get
  that cast as a washed-out tint instead of plain white, and the
  gradient/alternating styles use up to two more colors the sleeve actually
  contains when it has them.
- Neutral can win the accent now. A mostly-white sleeve with a face used to
  tint the whole wave skin-orange, because grey pixels couldn't vote; when the
  neutral area outweighs the strongest hue's vividness, the wave goes luminous
  silver-white instead. A bold red logo on white still wins.
- The wave tapers toward its edges (full crest in the middle, ~45% at the
  rims), so it reads as a swell instead of a rectangle.
- The island opens with a visible overshoot-and-settle now, like the iPhone's.
  Closing stays deliberately calm — overshoot on the way out reads wrong.
- Opening and closing are one continuous gesture now, verified frame by frame
  with a new choreography test that renders the staged walk through its real
  spring curves. While music plays, the island used to sit still for 200 ms
  before opening (two stages of the walk change nothing in that case — they're
  skipped now), and closing braked to a near-standstill at every intermediate
  stage because the rests matched the spring's settling time. Each stage now
  retargets the spring while the silhouette is still moving.
- Beat peaks overdrive a bar's tip (and its glow) toward white-hot, like a
  VU meter pushed into the red — only levels above 70% reach it, so it reads
  as energy, not as a palette change.
- The expand animation stopped dropping frames. Profiling the live app
  showed the island's drop shadow and rim gradient being software-rendered
  on the main thread for every frame of the morph, the wave's bars each
  rasterizing their own gradient and glow 30× a second, and all five tab
  pages being built mid-spring. The chrome and the wave are GPU-composited
  now, and the pages mount only once the island has come to rest — shape
  first, content into a still frame.
- The spectrum got stage lighting: no more grey-washed edge bars (the Shades
  style is a full-saturation brightness ramp now), gradients run through up to
  three colors the cover actually contains, and every bar throws a glow that
  pulses with its band.
- The bars dance to compressed masters now, not only to dynamic audio. Each
  band tracks its own running average and the level leans on the deviation
  from it — a kick punches to the top even on a loudness-normalized Spotify
  master that barely moves in absolute dB.
- New tab glyphs: the music tab wears the app's waveform instead of a generic
  note, and the Claude tab got Claude Code's crab.
- The spectrum analyzer resolves 32 bands (was 6) over a 2048-point FFT (was
  1024 — the finer bins keep the low bands distinct), enough to feed the wide
  pill at its maximum bar count; the smaller waves bucket down as before. Its
  time constants tick on audio time instead of the wall clock — deterministic
  under callback jitter, and testable faster than real time.
- Silence costs almost nothing now. The analyzer used to run a 1024-point FFT
  ~46 times a second against digital zeroes and push 30 UI updates a second
  for an unchanged flat wave — the "high energy use" Battery settings kept
  flagging. A peak gate puts the analysis to sleep after two silent seconds
  (the first audible sample wakes it), and the publisher only touches the
  main thread when a level actually moves.
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
