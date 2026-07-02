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
- **Obsidian quick capture** — a global hotkey appends notes silently to the daily note of a vault you pick in Settings. The quick-launch button opens a terminal with Claude Code in that same vault.

## Requirements

- **macOS 14.0 (Sonoma) or newer.** A physical notch is not required — the app draws its own.
- Spotify and/or Apple Music for the now-playing controls (optional).
- Obsidian for the quick-capture feature (optional; the vault folder is chosen in Settings).
- UI strings are currently German.

## Installation (prebuilt app)

1. Download `NotchMate.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move `NotchMate.app` to `/Applications`.
3. **First launch:** the app is ad-hoc signed and not notarized, so Gatekeeper will refuse to open it. Either allow it under *System Settings → Privacy & Security → "Open Anyway"* after the first attempt, or remove the quarantine flag once in Terminal:

   ```sh
   xattr -d com.apple.quarantine /Applications/NotchMate.app
   ```

4. Grant permissions when prompted (see below). The app registers itself as a login item.

### Permissions

| Permission | Needed for | Prompted |
|---|---|---|
| Automation (Apple Events) | Controlling Spotify / Apple Music | on first playback query |
| Accessibility | "Volume/brightness keys only in the notch" (`MediaKeyTap`) | when the feature is enabled |

Everything else (file shelf, live activities, quick capture) works without extra permissions.

## Build from source

- Xcode 15+. No external dependencies — a single Xcode target using only system frameworks.

```sh
xcodebuild -project NotchMate.xcodeproj -scheme NotchMate -configuration Debug build
```

Or open `NotchMate.xcodeproj` and hit ⌘R.

## Caveats

- The Accessibility grant is pinned to the code signature; ad-hoc rebuilds invalidate it (re-grant after reinstalling).
- Brightness control uses the private `DisplayServices` framework, resolved dynamically — if Apple removes the symbols, the feature degrades gracefully and macOS keeps handling the brightness keys.
- The app is not sandboxed and registers itself as a login item (`SMAppService`).

## App icon

The icon is generated programmatically: `swift Tools/GenerateAppIcon.swift` renders the 1024 px master (the Obsidian logo is © Obsidian.md, used as a nod to the quick-capture integration).

## License

[MIT](LICENSE)
