# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build (Debug)
xcodebuild -project Clipster.xcodeproj -scheme Clipster -configuration Debug build

# Build (Release)
xcodebuild -project Clipster.xcodeproj -scheme Clipster -configuration Release build

# Run tests
xcodebuild -project Clipster.xcodeproj -scheme Clipster -configuration Debug test
```

**Project config:** macOS 26.1 deployment target, Swift 6.0+, Xcode 26.1.1+, bundle ID `com.rene.Clipster`, sandbox disabled.

## Architecture

**Single-file app** — all code lives in `Clipster/Clipster.swift` (~980 lines), organized by MARK sections. No external dependencies; pure SwiftUI + AppKit + Carbon + ServiceManagement.

### Key Components

| Section | Role |
|---|---|
| `ClipboardItem` (model) | Codable struct with UUID, content, timestamp, type (.text/.url/.code/.image), pin status. Custom Codable excludes runtime `imageData`. |
| `ClipboardManager` (ObservableObject) | Core logic: clipboard polling (1s timer), screenshot directory polling (2s timer), expiry (1h timer), persistence, pin/delete/copy actions. |
| `ContentView` | Main popover UI with tabbed view (Snippets/Screenshots), search, keyboard navigation, pinned/unpinned sections. |
| `ClipboardItemView` | Individual row with hover/selection actions (copy, pin, delete). |
| `SettingsView` | Preferences window with General and Screenshots tabs. |
| `AppDelegate` | Menu bar status item, NSPopover management, global hotkey (Cmd+Shift+V) via Carbon Event API. |
| `ClipsterApp` | SwiftUI App entry point with Settings scene. |

### Design Decisions

- **Timer-based polling** (not notifications) for clipboard and screenshot monitoring — intentional for reliability.
- **Image storage is split**: metadata in UserDefaults JSON, actual TIFF files in `~/Library/Application Support/Clipster/images/` with UUID filenames. Images are lazy-loaded on launch.
- **Screenshot detection** watches the macOS screenshot directory (respects `com.apple.screencapture` location preference, defaults to ~/Desktop). Filters by `.png` extension and creation date < 30 seconds.
- **Carbon Event API** for global Cmd+Shift+V hotkey — no Accessibility permission required.
- **Keyboard navigation** uses `NSEvent.addLocalMonitorForEvents`. Arrow keys carry `.function` and `.numericPad` modifier flags on macOS — both must be stripped when checking for bare key presses.

### UserDefaults Keys

| Key | Type | Default | Purpose |
|---|---|---|---|
| `clipboardHistory` | Data (JSON) | — | Persisted clipboard items |
| `maxItems` | Int | 100 | History size limit |
| `expiryHours` | Int | 12 | Auto-expiry (-1 = never) |
| `monitorScreenshots` | Bool | true | Screenshot directory watching |
