# DeSKSTAY

A menu-bar app for macOS that remembers and restores where things sit on your screens: **desktop icons** (like Desktop Icon Manager) and **application windows** (like Stay), per display combination.

## About

DeSKSTAY is a personal tool by **Starbudweiser & Claude Code (Anthropic)**, released under the MIT license. It merges the ideas of [Desktop Icon Manager](https://www.parker9.com/desktopIconManager4.html) and [Stay](https://cordlessdog.com/stay/) and is not affiliated with their authors. It is provided as is, without warranty. The same information is available in the app itself: menu bar icon › *About DeSKSTAY*.

## Features

- **Desktop icons**: save and restore their positions (instantly, only the icons that moved), or hide them.
- **Windows**: save and restore the position of Finder windows (never reopened if closed) and application windows, chosen app by app.
- **Several arrangements**, picked automatically from the connected displays.
- **Nothing automatic by default**; restoring on display change, wake or launch are opt-in options.
- Available in English, French, Spanish and Italian (follows the system language).

## Requirements

macOS 14 or later. On first use macOS asks for two permissions: Automation (to control the Finder) and Accessibility (to move application windows).

## Build

```bash
swift test        # unit tests
./build.sh        # builds, signs and installs DeSKSTAY.app
./release.sh      # Developer ID signature, archive and notarization (see the script header)
```

Data is kept in `~/Library/Application Support/DeskStay/arrangements.json`.

## License

MIT, © 2026 Starbudweiser. See [LICENSE](LICENSE).
