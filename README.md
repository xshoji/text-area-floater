# TextAreaFloater

A simple text area that always floats on top. A macOS-only app that lets you send (paste) the text you type into any other application.

[demo.mp4](https://github.com/user-attachments/assets/06d7710d-cd0a-4384-806e-d1b28aab08c4)





## Problem it solves

Some applications, such as terminals, make text input awkward:

- No cursor movement
- No select-and-delete
- Shift required for newlines

With this app you can edit freely first, then send the text to the target application (via paste).

## Usage

```bash
./build.sh
open build/TextAreaFloater.app
```

### Operation

1. Type text into the panel that floats on top
    - Enter: newline (no Shift needed)
    - Cursor movement, selection, deletion: same as a normal text area
2. Select the destination from the dropdown (default: "Frontmost App")
3. Send with `Cmd + Enter` or the "Send" button
    - The target app is activated and the text is pasted via the clipboard
    - The original clipboard contents are restored

### Send only the selection

If you send while part of the text is selected, **only the selection** is sent. With no selection, the entire text is sent.

### Enter confirm option

Turn on the "Enter" toggle in the lower-right corner to send an Enter key after pasting. Handy when you want to execute a command immediately in a terminal.

### Global hotkey

You can set a hotkey from the ⌨ icon in the lower-right corner. Default is unset.

1. Click the ⌨ icon
2. A popover opens; press any key combo (e.g. `Cmd+Shift+J`)
3. Once set, the combo is shown on the ⌨ icon
4. From then on, that combo toggles the panel visibility regardless of which app is frontmost

Press Esc to cancel.

### Window controls

- **Move**: drag the padding area at the top
- **Resize**: drag the right or bottom edge
- **Minimum size**: 200px wide / 60px tall

### Permissions

On first launch, allow the following in System Settings:

- **Accessibility**: to operate and paste into other apps via AppleScript
    - System Settings > Privacy & Security > Accessibility
    - Turn on `TextAreaFloater`
- **Input Monitoring**: for the global hotkey (only needed when you set a hotkey)
    - System Settings > Privacy & Security > Input Monitoring

Restart the app after granting permission.

## Technical stack

| Layer | Technology | Role |
|---|---|---|
| UI | SwiftUI (`TextEditor`, `Picker`, `Toggle`, `Button`) | Text editing, destination selection, options |
| Text editor | AppKit (`NSTextView` via `NSViewRepresentable`) | Zero-padding, clear-background plain editor |
| Window | AppKit (`NSPanel`, borderless) | Always on top, accepts input while other apps are active, no header |
| Window controls | AppKit (`NSView` drag/resize) | Top-drag move, right/bottom-edge resize |
| Send | AppleScript (`NSAppleScript` + System Events) | Click "Paste" in the menu bar, fall back to `keystroke` |
| Enter confirm | AppleScript (`keystroke return`) | Send Enter after paste |
| Global hotkey | Carbon (`RegisterEventHotKey`) | Toggle panel with any combo |
| App selection | `NSWorkspace` | List running apps, activate |
| Clipboard | `NSPasteboard` | Pass text, save/restore |

### Design notes

- **`NSPanel` + `nonactivatingPanel` + `level = .floating`**: the panel floats on top while other apps stay frontmost and accept input
- **Borderless window**: no title bar, full-size content. Rounded corners and shadow are set manually
- **`LSUIElement = true`**: does not appear in the Dock. Stays out of the way
- **Send method**: clipboard + AppleScript clicking "Paste" in the menu bar. More reliable than `keystroke`. Falls back to `keystroke` on failure
- **Identify process by PID**: targets the process via `unix id` instead of the app name to avoid localization mismatches
- **Clipboard save/restore**: does not clobber the original contents
- **Temporarily hide the panel**: the panel is `orderOut`-ed on send so key events are not swallowed by the panel
- **`PlainTextEditor`**: SwiftUI's `TextEditor` has fixed internal padding that is hard to adjust, so `NSTextView` is wrapped directly. Padding is controlled via `textContainerInset` and `lineFragmentPadding`
- **Selection tracking**: `textViewDidChangeSelection` continuously syncs the selected text

## File layout

```
.
├── Sources/
│   └── TextAreaApp/
│       └── App.swift       # Entire implementation (single file, ~850 lines)
├── Resources/
│   └── Info.plist          # Bundle settings, permission declarations
├── build.sh                # Build script (runs swiftc directly)
└── README.md
```

### Main components in App.swift

| Component | Role |
|---|---|
| `FloatingPanel` | `NSPanel` subclass. Overrides `canBecomeKey` / `canBecomeMain` |
| `AppState` | `ObservableObject`. Manages text, selection, destination, status, permissions |
| `GlobalHotKeyManager` | Registers and manages a global hotkey via the Carbon API. UI-configurable |
| `HotKeyRecorder` | `NSViewRepresentable`. Captures key input to record a combo |
| `WindowDragHandle` / `DragView` | Transparent drag area at the top |
| `ResizeHandle` / `ResizeView` | Transparent resize area on the right/bottom edges |
| `PlainTextEditor` | Editor wrapping `NSTextView` with controllable padding |
| `ContentView` | SwiftUI root view. Editor + overlay controls |
| `AppDelegate` | Creates the panel, initializes the hotkey |

## Build

```bash
./build.sh
```

Compiles directly with `swiftc` and produces a `.app` bundle. No Xcode project required.

Dependency frameworks: SwiftUI, AppKit, ApplicationServices, Carbon

## Future ideas

- Persist hotkey settings (`UserDefaults`)
- Hotkey clear button
- Auto-clear option after send
- Send history
- Apple Silicon native (arm64) build
- Character count, markdown preview
