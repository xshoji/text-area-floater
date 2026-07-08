# AGENTS.md

Guidelines for agents (AI assistants) working in this project.

## Project overview

**TextAreaFloater** is a macOS-only floating text area app. It always floats on top and can send (paste) the text you type into any other application. Use it to edit text in this app first, then send it to apps that are awkward to type into, such as terminals.

## Tech stack

- **Language**: Swift
- **UI**: SwiftUI + AppKit
- **Build**: `swiftc` run directly (no Xcode project, no SwiftPM)
- **Target**: macOS 13+ (Arm64 / x86_64)
- **Dependency frameworks**: SwiftUI, AppKit, ApplicationServices, Carbon

## Build & run

```bash
./build.sh                    # build
open build/TextAreaFloater.app  # launch
```

Build logs go to stdout/stderr. On error, check the tail:

```bash
./build.sh 2>&1 | tail -20
```

## Code layout

The entire implementation lives in a single file, `Sources/TextAreaApp/App.swift` (~850 lines). Add new features to this file in principle. Do not split files until readability is significantly degraded.

### Main components

| Component | Around line | Role |
|---|---|---|
| `FloatingPanel` | Top | `NSPanel` subclass |
| `AppState` | 15+ | State management, send logic, permission management |
| `GlobalHotKeyManager` | 246+ | Hotkey management via the Carbon API |
| `HotKeyRecorder` | ~400 | Key input capture |
| `WindowDragHandle` / `ResizeHandle` | 440+ | Window controls |
| `PlainTextEditor` | 542+ | `NSTextView` wrapper |
| `ContentView` | 611+ | SwiftUI root view |
| `AppDelegate` | 710+ | Panel creation, initialization |

## Coding conventions

### Swift

- Swift 5 style (use `@MainActor`, `ObservableObject`, `NSViewRepresentable`)
- Apply `@MainActor` to classes that touch UI or call AppKit APIs
- Limit `nonisolated` to things that must be called off the main actor, such as Carbon callbacks
- Do not emit Sendable warnings (suppress with `nonisolated(unsafe)` as needed)
- Write comments in English

### SwiftUI

- Float controls with `overlay(alignment:)` (do not build the full layout with VStack/HStack)
- Use `.background(.regularMaterial, in: Capsule())` for a material-background capsule
- Define shortcuts with `keyboardShortcut`
- `popover`'s `isPresented` cannot bind directly to a `@Published` on a `let` property, so use `Binding(get:set:)`

### AppKit

- `NSPanel` is `borderless` + `nonactivatingPanel`. No title bar
- Rounded corners, shadow, and background disappear with `borderless`, so set them manually:
    - `isOpaque = false`
    - `backgroundColor = .clear`
    - `hasShadow = true`
- `isMovableByWindowBackground = true` does not work because `TextEditor` consumes the mouse. Place a dedicated drag area
- Bridge AppKit views into SwiftUI with `NSViewRepresentable`

## Send logic

### Flow

1. Check accessibility permission (`AXIsProcessTrusted`)
2. Determine what to send: if there is a selection, only that; otherwise everything
3. Save the clipboard → set the text
4. Temporarily hide the panel (`orderOut`) → activate the target app
5. Wait 0.4s, then paste via AppleScript:
    - Method 1: click "Paste" in the menu bar (`click menu item "Paste" of menu "Edit" of menu bar 1`)
    - Method 2 (fallback): `keystroke "v" using command down`
6. If `sendEnterAfterPaste` is on, additionally `keystroke return`
7. Restore the clipboard → show the panel again

### AppleScript notes

- Identify the process by **PID (`unix id`)**. The app name can mismatch due to localization
- Activate with `NSRunningApplication.activate()` instead of `tell application id "..." to activate`, and use AppleScript only for the paste operation
- Extract `NSAppleScript.errorMessage` from the error dictionary of `NSAppleScript.executeAndReturnError` and display it

## Permissions

| Permission | Purpose | API |
|---|---|---|
| Accessibility | Operate other apps via AppleScript | `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions` |
| Input Monitoring | Global hotkey | Carbon `RegisterEventHotKey` (prompted at runtime) |

When permission is not granted, show `⚠️` in the status bar and open System Settings automatically.

## Common pitfalls

### `NSRectEdge` case names

Case names differ by SDK version:

- SDK 26+: `.maxX` / `.minY` / `.maxY` / `.minX`
- Older SDK: `.maxXEdge` / `.minYEdge`, etc.

If the build errors, follow the SDK's suggestion.

### `performDrag` is move, not resize

`window?.performDrag(with:)` moves the window. To resize, call `window.setFrame` directly in `mouseDragged`.

### SwiftUI `TextEditor` padding

`TextEditor` has fixed `textContainerInset` and `lineFragmentPadding`; forcing an offset with `.padding(-x)` causes clipping. Wrap `NSTextView` directly with `NSViewRepresentable` to control it.

### `popover`'s `isPresented` and `let` properties

You cannot use `$` binding on a `@Published` inside a `let` property of a `@StateObject` / `@EnvironmentObject`. Use `Binding(get:set:)` to get and set explicitly.

## Checklist for changes

- [ ] `./build.sh` completes with no warnings or errors
- [ ] After launch, text editing and sending work
- [ ] Window move and resize work
- [ ] Hotkey configuration and behavior work
- [ ] Selection-only send works
- [ ] Enter confirm option works

## Non-goals

- Introducing an Xcode project (keep direct `swiftc` builds)
- Excessive file splitting (keep the single-file structure)
- Cross-platform support (macOS only)
- Adding external dependencies (standard frameworks only)
