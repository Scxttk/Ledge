<p align="center">
  <img src="NotchMate/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="NotchMate icon">
</p>

<h1 align="center">NotchMate</h1>

<p align="center">A Dynamic-Island-style interactive notch for your Mac's menu bar.</p>

NotchMate is a macOS menu-bar accessory app (no Dock icon) that draws an interactive, animated notch at the top center of the screen — inspired by the iPhone's Dynamic Island.

## Features

- **Now Playing** — media controls for Spotify and Apple Music, including local favorites. Uses scriptable Apple Events (AppleScript), since Apple sealed the private MediaRemote framework on macOS 15.4+.
- **File shelf** — drag files onto the notch to stage them for later drag-out. Files are tracked via security bookmarks, so they survive moves and relaunches.
- **Live activities** — transient pill notifications for charging state, audio-route changes, and received files, with priorities and auto-dismiss.
- **Volume & brightness HUD** — replaces Apple's on-screen display with an in-notch HUD. Hardware keys are captured with a CGEvent tap (requires the Accessibility permission); volume is driven through public CoreAudio APIs.
- **Obsidian quick capture** — a global hotkey appends notes silently to your daily note.

## Requirements & build

- macOS 14.0+, Xcode 15+. No external dependencies — a single Xcode target using only system frameworks.

```sh
xcodebuild -project NotchMate.xcodeproj -scheme NotchMate -configuration Debug build
```

Or open `NotchMate.xcodeproj` and hit ⌘R.

## Permissions & caveats

- **Automation** (Apple Events) — prompted on first launch, used to control Spotify/Music.
- **Accessibility** — needed only for the "volume/brightness keys only in the notch" feature. Note: the grant is pinned to the code signature; ad-hoc rebuilds invalidate it.
- Brightness control uses the private `DisplayServices` framework, resolved dynamically — if Apple removes the symbols, the feature degrades gracefully and macOS keeps handling the brightness keys.
- The app is not sandboxed and registers itself as a login item (`SMAppService`).
- UI strings are currently German.

## App icon

The icon is generated programmatically: `swift Tools/GenerateAppIcon.swift` renders the 1024 px master (the Obsidian logo is © Obsidian.md, used as a nod to the quick-capture integration).

## License

[MIT](LICENSE)
