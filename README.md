# Pomodoro

A small Pomodoro timer that lives in the macOS menu bar. Built with SwiftUI, no dependencies.

## Features

- Countdown shown in the menu bar while a session is active
- Focus, short break and long break modes with a progress ring
- Adjustable durations (1–180 min) and cycles before a long break (1–12), from the main panel or settings
- Built-in presets (Default 25/5/15 ×4, Quick Sprint, Deep Work, Flow State) plus your own saved presets
- Sound and notification when a session ends
- Settings and presets persist between launches

## Requirements

- macOS 14 or later, Apple silicon
- Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```sh
./build.sh
open Pomodoro.app
```

To install, copy or symlink `Pomodoro.app` into `/Applications`. To start at login, add it under
System Settings → General → Login Items.

## Shortcuts

With the panel open:

| Key   | Action         |
|-------|----------------|
| Space | Start / pause  |
| ⌘,    | Settings       |
| Esc   | Back from settings |
| ⌘Q    | Quit           |

## Files

| File               | Purpose                                   |
|--------------------|-------------------------------------------|
| `Pomodoro.swift`   | The whole app                             |
| `Info.plist`       | Bundle metadata; hides the Dock icon      |
| `build.sh`         | Compiles, signs and assembles `Pomodoro.app` |
| `AppIcon.icns`     | App icon                                  |
| `make_icon.swift`  | Regenerates the icon                      |

To regenerate the icon:

```sh
swift make_icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns && rm -rf AppIcon.iconset
```
