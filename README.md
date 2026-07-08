# TextAreaFloater

常に最前面に浮くシンプルなテキストエリア。入力したテキストを任意のアプリへ送信できる macOS 専用アプリ。

## 解決する課題

ターミナルなど一部のアプリはテキスト入力が使いにくい:

- カーソル移動ができない
- 選択して削除ができない
- 改行に Shift が必要

このアプリで自由に編集してから、対象アプリへテキストを送信（ペースト）できる。

## 使い方

```bash
./build.sh
open build/TextAreaFloater.app
```

### 操作

1. 最前面に浮いたパネルへテキストを入力
    - Enter: 改行（Shift 不要）
    - カーソル移動・選択・削除: 通常のテキストエリアと同じ
2. 送信先をドロップダウンで選択（デフォルト「前面のアプリ」）
3. `Cmd + Enter` または「送信」ボタンで送信
    - 対象アプリがアクティブ化され、クリップボード経由でペーストされる
    - 元のクリップボード内容は復元される

### 選択範囲のみ送信

テキストの一部を選択した状態で送信すると、**選択範囲だけ**が送信される。選択なしの場合は全体が送信される。

### Enter 確定オプション

右下の「Enter」トグルをオンにすると、ペースト後に Enter キーを送信する。ターミナル等でコマンドを即実行したい場合に便利。

### グローバルホットキー

右下の ⌨ アイコンからホットキーを設定できる。デフォルトは未設定。

1. ⌨ アイコンをクリック
2. popover が開くので、任意のキー combo を押す（例: `Cmd+Shift+J`）
3. 設定されると ⌨ アイコンに combo が表示される
4. 以降、どのアプリが前面にいてもその combo でパネルの表示/非表示をトグル

Esc でキャンセル。

### ウィンドウ操作

- **移動**: 上部の余白をドラッグ
- **リサイズ**: 右端・下端をドラッグ
- **最小サイズ**: 幅 200px / 高さ 60px

### 権限

初回起動時にシステム設定で以下を許可する必要がある:

- **アクセシビリティ (Accessibility)**: AppleScript で他アプリを操作・ペーストするため
    - システム設定 > プライバシーとセキュリティ > アクセシビリティ
    - `TextAreaFloater` をオンにする
- **入力監視 (Input Monitoring)**: グローバルホットキー用（ホットキー設定時のみ必要）
    - システム設定 > プライバシーとセキュリティ > 入力監視

許可後はアプリを再起動する。

## 技術構成

| 層 | 技术 | 役割 |
|---|---|---|
| UI | SwiftUI (`TextEditor`, `Picker`, `Toggle`, `Button`) | テキスト編集・送信先選択・オプション |
| テキストエディタ | AppKit (`NSTextView` via `NSViewRepresentable`) | 余白ゼロ・背景クリアのプレーンエディタ |
| ウィンドウ | AppKit (`NSPanel`, borderless) | 常に最前面・他アプリ操作中でも入力可能・ヘッダーなし |
| ウィンドウ操作 | AppKit (`NSView` drag/resize) | 上部ドラッグ移動・右端/下端リサイズ |
| 送信 | AppleScript (`NSAppleScript` + System Events) | メニューバー「Paste」クリック、フォールバックで `keystroke` |
| Enter 確定 | AppleScript (`keystroke return`) | ペースト後に Enter を送信 |
| グローバルホットキー | Carbon (`RegisterEventHotKey`) | 任意の combo でパネル表示トグル |
| アプリ選択 | `NSWorkspace` | 実行中アプリ一覧・アクティブ化 |
| クリップボード | `NSPasteboard` | テキスト受け渡し・退避復元 |

### 設計のポイント

- **`NSPanel` + `nonactivatingPanel` + `level = .floating`**: 他アプリが前面のまま、パネルだけ最前面に浮いて入力できる
- **borderless ウィンドウ**: タイトルバーなし、`fullSizeContentView` 相当の全面コンテンツ。丸角・影は手動設定
- **`LSUIElement = true`**: Dock に表示しない。邪魔にならない
- **送信方式**: クリップボード + AppleScript でメニューバー「Paste」をクリック。`keystroke` より確実。失敗時は `keystroke` にフォールバック
- **PID でプロセス特定**: アプリ名ではなく `unix id` でプロセスを特定し、ローカライズ問題を回避
- **クリップボード退避・復元**: 元内容を壊さない
- **パネル一時非表示**: 送信時にパネルを `orderOut` し、キーイベントがパネルに吸われないようにする
- **`PlainTextEditor`**: SwiftUI `TextEditor` は内部余白が固定で調整困難なため、`NSTextView` を直接ラップ。`textContainerInset` と `lineFragmentPadding` で余白を制御
- **選択範囲追跡**: `textViewDidChangeSelection` で選択テキストを常時同期

## ファイル構成

```
.
├── Sources/
│   └── TextAreaApp/
│       └── App.swift       # 全体実装（1ファイル・約850行）
├── Resources/
│   └── Info.plist          # バンドル設定・権限宣言
├── build.sh                # ビルドスクリプト (swiftc 直接実行)
└── README.md
```

### App.swift の主要コンポーネント

| コンポーネント | 役割 |
|---|---|
| `FloatingPanel` | `NSPanel` サブクラス。`canBecomeKey` / `canBecomeMain` をオーバーライド |
| `AppState` | `ObservableObject`。テキスト・選択・送信先・ステータス・権限管理 |
| `GlobalHotKeyManager` | Carbon API でグローバルホットキーを登録・管理。UI 設定可能 |
| `HotKeyRecorder` | `NSViewRepresentable`。キー入力を capture して combo を記録 |
| `WindowDragHandle` / `DragView` | 上部の透明ドラッグ領域 |
| `ResizeHandle` / `ResizeView` | 右端・下端の透明リサイズ領域 |
| `PlainTextEditor` | `NSTextView` をラップした余白制御可能なエディタ |
| `ContentView` | SwiftUI ルートビュー。エディタ + overlay コントロール群 |
| `AppDelegate` | パネル生成・ホットキー初期化 |

## ビルド

```bash
./build.sh
```

`swiftc` で直接コンパイルし、`.app` バンドルを生成する。Xcode プロジェクト不要。

依存フレームワーク: SwiftUI, AppKit, ApplicationServices, Carbon

## 今後の拡張候補

- ホットキー設定の永続化（`UserDefaults`）
- ホットキークリアボタン
- 送信後自動クリアオプション
- 送信履歴
- Apple Silicon ネイティブ（arm64）ビルド
- 文字数カウント・マークダウンプレビュー
