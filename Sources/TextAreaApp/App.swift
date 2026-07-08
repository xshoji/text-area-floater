import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox

// MARK: - フローティングパネル

/// 常に最前面に浮く、他アプリ操作中でも入力可能なパネル。
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - アプリ状態

@MainActor
final class AppState: ObservableObject {
    @Published var text: String = ""
    /// エディタで選択中のテキスト。空なら選択なしとみなす。
    @Published var selectedText: String = ""
    @Published var targetBundleId: String? = nil  // nil = 前面のアプリ
    @Published var status: String = "準備完了"
    @Published private(set) var runningApps: [NSRunningApplication] = []
    /// 送信後に Enter を送ってテキストを確定するか（ターミナル等のコマンド実行用）。
    @Published var sendEnterAfterPaste: Bool = false
    /// グローバルホットキーマネージャ。
    let hotKeyManager = GlobalHotKeyManager()

    /// 送信時にパネルを一時非表示にするための参照。
    weak var panel: NSPanel?

    init() {
        refreshApps()
    }

    /// パネルの表示/非表示をトグル（グローバルホットキーから呼ばれる）。
    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: false)
        }
    }

    /// 実行中の regular アプリ一覧を更新（自分は除外）。
    func refreshApps() {
        let myBundleId = Bundle.main.bundleIdentifier
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != myBundleId }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    /// 送信先表示名
    var targetDisplayName: String {
        if let id = targetBundleId,
           let app = runningApps.first(where: { $0.bundleIdentifier == id }) {
            return app.localizedName ?? id
        }
        return "前面のアプリ"
    }

    /// テキストを対象アプリへ送信する。
    /// 選択範囲があればその部分だけ、なければ全体を送信。
    /// 1) アクセシビリティ権限をチェック
    /// 2) クリップボードを退避
    /// 3) テキストをクリップボードへセット
    /// 4) パネルを一時非表示 + 対象アプリをアクティブ化
    /// 5) メニューバーから「Paste」をクリック（フォールバック: keystroke）
    /// 6) クリップボードを復元 + パネル再表示
    func sendText() {
        // 選択範囲があればそれだけ、なければ全体
        let payload = selectedText.isEmpty ? text : selectedText
        guard !payload.isEmpty else {
            status = "テキストが空です"
            return
        }

        // アクセシビリティ権限チェック
        guard checkAccessibility() else {
            status = "⚠️ アクセシビリティ権限が必要。システム設定で許可してください"
            requestAccessibility()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.openAccessibilitySettings()
            }
            return
        }

        // 送信先アプリを決定
        guard let target = resolveTargetApp(),
              let bundleId = target.bundleIdentifier else {
            status = "送信先アプリが見つかりません"
            return
        }
        let targetName = target.localizedName ?? bundleId
        let pid = Int(target.processIdentifier)

        // クリップボード退避
        let pasteboard = NSPasteboard.general
        let savedChangeCount = pasteboard.changeCount
        let savedString = pasteboard.string(forType: .string)

        // テキストをセット
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        // パネルを一時非表示（キーイベントがパネルに吸われないように）
        panel?.orderOut(nil)

        // 対象アプリをアクティブ化
        target.activate(options: [.activateAllWindows])
        let isPartial = !selectedText.isEmpty && selectedText != text
        status = "送信中… → \(targetName)"
        print("[TextAreaFloater] send: target=\(targetName), bundleId=\(bundleId), pid=\(pid), chars=\(payload.count)\(isPartial ? " (選択範囲)" : "")")

        // ターゲットが前面になるのを待ってからペーストを実行
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            // 方法1: メニューバーの「Paste」を直接クリック（keystroke より確実）
            let menuScript = """
            tell application "System Events"
                tell (first process whose unix id is \(pid))
                    click menu item "Paste" of menu "Edit" of menu bar 1
                end tell
            end tell
            """
            var error1: NSDictionary?
            _ = NSAppleScript(source: menuScript)?.executeAndReturnError(&error1)

            if let error1 = error1 {
                print("[TextAreaFloater] menu click failed: \(error1[NSAppleScript.errorMessage] ?? "")")
                // 方法2: フォールバックで keystroke "v" using command down
                let keyScript = """
                tell application "System Events"
                    tell (first process whose unix id is \(pid))
                        set frontmost to true
                    end tell
                    keystroke "v" using command down
                end tell
                """
                var error2: NSDictionary?
                _ = NSAppleScript(source: keyScript)?.executeAndReturnError(&error2)

                DispatchQueue.main.async {
                    if let error2 = error2 {
                        let msg = error2[NSAppleScript.errorMessage] as? String ?? String(describing: error2)
                        print("[TextAreaFloater] keystroke also failed: \(msg)")
                        self.status = "⚠️ 送信失敗: \(msg)"
                    } else {
                        print("[TextAreaFloater] keystroke OK (fallback)")
                        self.finishSend(targetName: targetName, pid: pid,
                                        savedString: savedString, savedChangeCount: savedChangeCount)
                    }
                    self.panel?.orderFrontRegardless()
                }
            } else {
                print("[TextAreaFloater] menu click OK")
                DispatchQueue.main.async {
                    self.finishSend(targetName: targetName, pid: pid,
                                    savedString: savedString, savedChangeCount: savedChangeCount)
                    self.panel?.orderFrontRegardless()
                }
            }
        }
    }

    /// ペースト成功後の処理。必要に応じて Enter を送り、クリップボードを復元する。
    private func finishSend(targetName: String, pid: Int,
                            savedString: String?, savedChangeCount: Int) {
        if sendEnterAfterPaste {
            status = "確定中… → \(targetName)"
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                let enterScript = """
                tell application "System Events"
                    tell (first process whose unix id is \(pid))
                        keystroke return
                    end tell
                end tell
                """
                var enterError: NSDictionary?
                _ = NSAppleScript(source: enterScript)?.executeAndReturnError(&enterError)

                DispatchQueue.main.async {
                    if let enterError = enterError {
                        let msg = enterError[NSAppleScript.errorMessage] as? String ?? String(describing: enterError)
                        print("[TextAreaFloater] enter failed: \(msg)")
                        self.status = "⚠️ 確定失敗: \(msg)"
                    } else {
                        print("[TextAreaFloater] enter OK")
                        self.restoreClipboard(savedString: savedString, savedChangeCount: savedChangeCount)
                        self.status = "送信・確定しました → \(targetName)"
                    }
                }
            }
        } else {
            restoreClipboard(savedString: savedString, savedChangeCount: savedChangeCount)
            status = "送信しました → \(targetName)"
        }
    }

    /// クリップボードを元の内容に復元する。
    private func restoreClipboard(savedString: String?, savedChangeCount: Int) {
        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount > savedChangeCount {
            pasteboard.clearContents()
            if let saved = savedString {
                pasteboard.setString(saved, forType: .string)
            }
        }
    }

    // MARK: - 権限

    /// アクセシビリティ権限が許可されているか。
    private func checkAccessibility() -> Bool {
        return AXIsProcessTrusted()
    }

    /// アクセシビリティ権限のプロンプトを表示。
    private func requestAccessibility() {
        let options: NSDictionary = [
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true
        ]
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// システム設定の「アクセシビリティ」画面を開く。
    private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// 送信先アプリを解決。nil の場合は frontmost（自分以外）。
    private func resolveTargetApp() -> NSRunningApplication? {
        let myBundleId = Bundle.main.bundleIdentifier
        if let id = targetBundleId {
            return NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == id && $0.bundleIdentifier != myBundleId }
        }
        // 前面のアプリ（自分を除外）
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != myBundleId {
            return front
        }
        // 自分が前面なら次の regular アプリ
        return NSWorkspace.shared.runningApplications
            .first { $0.activationPolicy == .regular && $0.bundleIdentifier != myBundleId }
    }
}

// MARK: - グローバルホットキー

/// Carbon API でグローバルホットキーを登録・管理する。
/// デフォルトは未登録。UI から設定・クリアできる。
@MainActor
final class GlobalHotKeyManager: ObservableObject {
    /// 登録中のホットキーの表示文字列。未登録なら nil。
    @Published private(set) var registeredDescription: String?
    /// キー入力待ち受け中か。
    @Published var isListening: Bool = false

    private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?
    private var currentKeyCode: UInt32 = 0
    private var currentModifiers: UInt32 = 0
    private var callback: (() -> Void)?

    init() {}

    /// コールバックを設定（AppDelegate が togglePanel を登録）。
    func setCallback(_ callback: @escaping () -> Void) {
        self.callback = callback
    }

    /// グローバルイベントハンドラをインストール（アプリ起動時に1回だけ呼ぶ）。
    nonisolated func installEventHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, refCon, _) -> OSStatus in
                                guard let refCon else { return noErr }
                                let raw = UnsafeRawPointer(refCon)
                                let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(raw).takeUnretainedValue()
                                Task { @MainActor in manager.fire() }
                                return noErr
                            },
                            1, &eventSpec, selfPtr, &eventHandler)
    }

    @MainActor
    fileprivate func fire() {
        callback?()
    }

    /// 次に押したキーをホットキーとして登録するモードに入る。
    func startListening() {
        isListening = true
        // 既存のホットキーを一旦解除（入力を奪わないように）
        unregister()
    }

    /// 待ち受けモードをキャンセル。
    func cancelListening() {
        isListening = false
    }

    /// キー入力を受け取って登録（HotKeyRecorder から呼ばれる）。
    func record(keyCode: UInt32, modifiers: UInt32) {
        guard isListening else { return }
        isListening = false
        register(keyCode: keyCode, modifiers: modifiers)
    }

    /// ホットキーを登録。
    func register(keyCode: UInt32, modifiers: UInt32) {
        unregister()
        currentKeyCode = keyCode
        currentModifiers = modifiers

        let keyCombo = EventHotKeyID(signature: OSType(0x54524141),  // 'TRAA'
                                     id: UInt32(1))
        RegisterEventHotKey(keyCode,
                            modifiers,
                            keyCombo,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
        registeredDescription = Self.describe(keyCode: keyCode, modifiers: modifiers)
    }

    /// ホットキーを解除。
    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        registeredDescription = nil
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    // MARK: - 表示文字列化

    /// keyCode + modifiers から表示文字列を生成。
    static func describe(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0  { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0   { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0     { parts.append("⌘") }
        parts.append(keyLabel(keyCode))
        return parts.joined()
    }

    private static func keyLabel(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            // 文字キーは TIS のレイアウトから取得を試みる
            if let char = charForKeyCode(Int(keyCode)) {
                return String(char).uppercased()
            }
            return "Key\(keyCode)"
        }
    }

    /// keyCode から現在のキーボードレイアウトで1文字を取得。
    private static func charForKeyCode(_ keyCode: Int) -> Character? {
        let layoutData = TISGetInputSourceProperty(TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue(),
                                                   kTISPropertyUnicodeKeyLayoutData)
        guard let layoutData else { return nil }
        let dataRef = unsafeBitCast(layoutData, to: CFData.self)
        let layout = unsafeBitCast(CFDataGetBytePtr(dataRef), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let error = UCKeyTranslate(layout,
                                   UInt16(keyCode),
                                   UInt16(kUCKeyActionDisplay),
                                   0,
                                   UInt32(LMGetKbdType()),
                                   OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                   &deadKeyState,
                                   chars.count,
                                   &actualLength,
                                   &chars)
        guard error == noErr, actualLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: actualLength).first
    }
}

// MARK: - ホットキー記録ビュー

/// キー入力を capture してホットキーとして記録する NSView。
struct HotKeyRecorder: NSViewRepresentable {
    let onRecord: (UInt32, UInt32) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = RecorderView()
        view.onRecord = onRecord
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class RecorderView: NSView {
    var onRecord: ((UInt32, UInt32) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Esc でキャンセル
        if event.keyCode == UInt16(kVK_Escape) {
            onRecord?(0, 0)
            return
        }
        let keyCode = UInt32(event.keyCode)
        var mods: UInt32 = 0
        if event.modifierFlags.contains(.command) { mods |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.shift)   { mods |= UInt32(shiftKey) }
        if event.modifierFlags.contains(.option)  { mods |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { mods |= UInt32(controlKey) }
        onRecord?(keyCode, mods)
    }

    override func flagsChanged(with event: NSEvent) {
        // 修飾キーだけの入力は無視
    }
}

// MARK: - ウィンドウドラッグ領域

/// 透明なドラッグ領域。マウスダウンでウィンドウのドラッグ移動を開始する。
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class DragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

// MARK: - ウィンドウリサイズ領域

/// 透明なリサイズ領域。マウスドラッグでウィンドウをリサイズする。
struct ResizeHandle: NSViewRepresentable {
    let edges: NSRectEdge

    func makeNSView(context: Context) -> NSView {
        let view = ResizeView(edges: edges)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class ResizeView: NSView {
    let edges: NSRectEdge
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero

    init(edges: NSRectEdge) {
        self.edges = edges
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window = window else { return }
        startFrame = window.frame
        // NSEvent.mouseLocation はスクリーン座標
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startMouse.x
        let dy = current.y - startMouse.y
        var frame = startFrame

        switch edges {
        case .maxX:
            // 右端をドラッグ: 幅を変更
            frame.size.width = max(200, startFrame.width + dx)
        case .minY:
            // 下端をドラッグ: 高さを変更（Y軸は上が正）
            frame.size.height = max(60, startFrame.height - dy)
        case .maxY:
            frame.size.height = max(60, startFrame.height + dy)
        case .minX:
            frame.size.width = max(200, startFrame.width - dx)
        @unknown default:
            break
        }

        window.setFrame(frame, display: true, animate: false)
    }

    /// マウスが領域に入ったらリサイズカーソルに変更
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursorForEdge())
    }

    private func cursorForEdge() -> NSCursor {
        switch edges {
        case .minY, .maxY: return .resizeUpDown
        case .minX, .maxX: return .resizeLeftRight
        default:           return .crosshair
        }
    }
}

// MARK: - プレーンテキストエディタ

/// SwiftUI の TextEditor は内部に余白を持つため、NSTextView を直接ラップして
/// 余白ゼロ・背景クリアのエディタを実現する。
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selectedText: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        // 標準的なテキストエリアと同等の余白
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.textContainer?.lineFragmentPadding = 5
        // 自動改行
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        // クォート/dash/テキストの自動置換を無効化
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        // 文字列設定
        textView.string = text

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // 外部からの更新を反映（カーソル位置を維持）
        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(selectedRange)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selectedText: $selectedText)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding var text: String
        @Binding var selectedText: String
        weak var textView: NSTextView?

        init(text: Binding<String>, selectedText: Binding<String>) {
            self._text = text
            self._selectedText = selectedText
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text = textView.string
            updateSelectedText(from: textView)
        }

        /// 選択範囲が変更されたら選択テキストを更新。
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateSelectedText(from: textView)
        }

        private func updateSelectedText(from textView: NSTextView) {
            let range = textView.selectedRange()
            if range.length > 0 {
                let nsString = textView.string as NSString
                selectedText = nsString.substring(with: range)
            } else {
                selectedText = ""
            }
        }
    }
}

// MARK: - ルートビュー

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        PlainTextEditor(text: $state.text, selectedText: $state.selectedText)
            .font(.system(.body))
            // 上部: 透明なドラッグ領域（ウィンドウ移動用）
            .overlay(alignment: .top) {
                WindowDragHandle()
                    .frame(height: 14)
            }
            // 右端: リサイズ（幅）
            .overlay(alignment: .trailing) {
                ResizeHandle(edges: .maxX)
                    .frame(width: 8)
            }
            // 下端: リサイズ（高さ）
            .overlay(alignment: .bottom) {
                ResizeHandle(edges: .minY)
                    .frame(height: 8)
            }
            // 左下: ステータス
            .overlay(alignment: .bottomLeading) {
                statusOverlay
                    .padding(.bottom, 6)
                    .padding(.leading, 6)
            }
            // 右下: アプリ選択 + 送信 + 更新 / 終了
            .overlay(alignment: .bottomTrailing) {
                controlsOverlay
                    .padding(.bottom, 6)
                    .padding(.trailing, 6)
            }
            // borderless パネル用の丸角背景
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(minWidth: 200, minHeight: 60)
    }

    /// 右下に浮かぶコントロール群（アプリ選択 + 送信 + 更新 / 終了）。
    private var controlsOverlay: some View {
        HStack(spacing: 4) {
            Picker("", selection: $state.targetBundleId) {
                Text("前面のアプリ").tag(nil as String?)
                ForEach(state.runningApps, id: \.bundleIdentifier) { app in
                    Text(app.localizedName ?? app.bundleIdentifier ?? "?")
                        .tag(app.bundleIdentifier as String?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Button("送信") {
                state.sendText()
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Cmd + Enter で送信")

            // 送信後に Enter で確定するトグル
            Toggle(isOn: $state.sendEnterAfterPaste) {
                Text("Enter")
                    .font(.caption)
                    .foregroundStyle(state.sendEnterAfterPaste ? .primary : .secondary)
            }
            .toggleStyle(.button)
            .help("オン: 送信後に Enter を送って確定（ターミナル等）")

            Divider().frame(height: 14)

            // グローバルホットキー設定
            hotKeyControl

            Divider().frame(height: 14)

            Button(action: { state.refreshApps() }) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("アプリ一覧を更新")
            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("終了")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: Capsule())
        .popover(isPresented: Binding(
                    get: { state.hotKeyManager.isListening },
                    set: { if !$0 { state.hotKeyManager.cancelListening() } }),
                 attachmentAnchor: .point(.top),
                 arrowEdge: .bottom) {
            hotKeyListeningView
        }
    }

    /// ホットキー設定ボタン。登録済みなら表示、未登録なら「未設定」。
    private var hotKeyControl: some View {
        Button(action: { state.hotKeyManager.startListening() }) {
            HStack(spacing: 3) {
                Image(systemName: "keyboard")
                    .font(.caption)
                if let desc = state.hotKeyManager.registeredDescription {
                    Text(desc)
                        .font(.caption)
                } else {
                    Text("未設定")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.borderless)
        .help("クリックしてホットキーを設定")
    }

    /// ホットキー入力待ち受け中の popover 内ビュー。
    private var hotKeyListeningView: some View {
        VStack(spacing: 8) {
            Text("キーを押してください")
                .font(.callout)
            Text("Esc でキャンセル")
                .font(.caption)
                .foregroundStyle(.secondary)
            HotKeyRecorder { keyCode, modifiers in
                if keyCode == 0 {
                    // Esc キャンセル
                    state.hotKeyManager.cancelListening()
                } else {
                    state.hotKeyManager.record(keyCode: keyCode, modifiers: modifiers)
                }
            }
            .frame(width: 120, height: 30)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
    }

    /// 左下に浮かぶステータス表示。
    private var statusOverlay: some View {
        Text(state.status)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?
    private var state: AppState?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // borderless でも丸角・影・背景を手動で設定
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true

        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false  // クリックで即キー
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isRestorable = false

        let state = AppState()
        let hosting = NSHostingController(
            rootView: ContentView().environmentObject(state)
        )
        panel.contentViewController = hosting
        panel.center()
        panel.orderFrontRegardless()

        state.panel = panel
        self.panel = panel
        self.state = state

        // グローバルホットキー: イベントハンドラをインストールし、コールバックを設定。
        // デフォルトは未登録。UI から設定する。
        state.hotKeyManager.setCallback { [weak state] in
            state?.togglePanel()
        }
        state.hotKeyManager.installEventHandler()
    }
}

// MARK: - アプリエントリ

@main
struct TextAreaFloaterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
