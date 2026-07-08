# AGENTS.md

このプロジェクトでエージェント（AI アシスタント）が作業する際の指針。

## プロジェクト概要

**TextAreaFloater** は macOS 専用のフローティングテキストエリアアプリ。常に最前面に浮き、入力したテキストを任意のアプリへ送信（ペースト）できる。ターミナル等の入力しづらいアプリで、一旦このアプリで編集してから送信する用途。

## 技術スタック

- **言語**: Swift
- **UI**: SwiftUI + AppKit
- **ビルド**: `swiftc` 直接実行（Xcode プロジェクトなし・SwiftPM なし）
- **ターゲット**: macOS 13+ (Arm64 / x86_64)
- **依存フレームワーク**: SwiftUI, AppKit, ApplicationServices, Carbon

## ビルド・実行

```bash
./build.sh                    # ビルド
open build/TextAreaFloater.app  # 起動
```

ビルドログは標準出力・標準エラーに出力される。エラー時は末尾を確認:

```bash
./build.sh 2>&1 | tail -20
```

## コード構成

全実装が `Sources/TextAreaApp/App.swift` 1ファイル（約850行）に集約。新機能追加も原則このファイルに追記する。ファイル分割は可読性が著しく損なわれるまで行わない。

### 主要コンポーネント

| コンポーネント | 行付近 | 役割 |
|---|---|---|
| `FloatingPanel` | 先頭付近 | `NSPanel` サブクラス |
| `AppState` | 15行〜 | 状態管理・送信ロジック・権限管理 |
| `GlobalHotKeyManager` | 246行〜 | Carbon API によるホットキー管理 |
| `HotKeyRecorder` | 400行付近 | キー入力 capture |
| `WindowDragHandle` / `ResizeHandle` | 440行〜 | ウィンドウ操作 |
| `PlainTextEditor` | 542行〜 | `NSTextView` ラッパー |
| `ContentView` | 611行〜 | SwiftUI ルートビュー |
| `AppDelegate` | 710行〜 | パネル生成・初期化 |

## コーディング規約

### Swift

- Swift 5 記法（`@MainActor`, `ObservableObject`, `NSViewRepresentable` を活用）
- `@MainActor` は UI 操作・AppKit API を呼ぶクラスに付与
- `nonisolated` は Carbon コールバック等、メインアクター外で呼ばれる必要があるものに限定
- Sendable 警告は出さない（`nonisolated(unsafe)` で必要に応じて抑制）
- コメントは日本語で記述

### SwiftUI

- `overlay(alignment:)` でコントロールを浮かせる（VStack/HStack で全面レイアウトを組まない）
- `.background(.regularMaterial, in: Capsule())` でマテリアル背景のカプセル
- `keyboardShortcut` でショートカット定義
- `popover` の `isPresented` は `let` プロパティの `@Published` に直接 bind できないため `Binding(get:set:)` を使う

### AppKit

- `NSPanel` は `borderless` + `nonactivatingPanel`。タイトルバーなし
- 丸角・影・背景は `borderless` だと消えるので手動設定:
    - `isOpaque = false`
    - `backgroundColor = .clear`
    - `hasShadow = true`
- `isMovableByWindowBackground = true` は `TextEditor` がマウスを消費するため効かない。専用のドラッグ領域を置く
- `NSViewRepresentable` で AppKit ビューを SwiftUI に桥接

## 送信ロジック

### フロー

1. アクセシビリティ権限チェック（`AXIsProcessTrusted`）
2. 送信内容決定: 選択範囲があればそれだけ、なければ全体
3. クリップボード退避 → テキストセット
4. パネル一時非表示（`orderOut`）→ 対象アプリアクティブ化
5. 0.4秒待って AppleScript でペースト:
    - 方法1: メニューバー「Paste」をクリック（`click menu item "Paste" of menu "Edit" of menu bar 1`）
    - 方法2（フォールバック）: `keystroke "v" using command down`
6. `sendEnterAfterPaste` がオンなら更に `keystroke return`
7. クリップボード復元 → パネル再表示

### AppleScript のポイント

- プロセスは **PID（`unix id`）** で特定。アプリ名だとローカライズで不一致になる
- `tell application id "..." to activate` ではなく `NSRunningApplication.activate()` でアクティブ化し、AppleScript はペースト操作のみに使う
- `NSAppleScript.executeAndReturnError` のエラー辞書から `NSAppleScript.errorMessage` を取り出して表示

## 権限

| 権限 | 用途 | API |
|---|---|---|
| アクセシビリティ | AppleScript で他アプリ操作 | `AXIsProcessTrusted()` / `AXIsProcessTrustedWithOptions` |
| 入力監視 | グローバルホットキー | Carbon `RegisterEventHotKey`（実行時にプロンプト） |

権限未許可時はステータスバーに `⚠️` 付きで表示し、システム設定画面を自動で開く。

## よくある落とし穴

### `NSRectEdge` のケース名

SDK バージョンによってケース名が異なる:

- SDK 26+: `.maxX` / `.minY` / `.maxY` / `.minX`
- 旧 SDK: `.maxXEdge` / `.minYEdge` 等

ビルドエラーになったら SDK の提案に従う。

### `performDrag` は移動であってリサイズではない

`window?.performDrag(with:)` はウィンドウ移動。リサイズは `mouseDragged` で `window.setFrame` を直接呼ぶ。

### SwiftUI `TextEditor` の余白

`TextEditor` は `textContainerInset` と `lineFragmentPadding` が固定で、`.padding(-x)` で無理やり相殺するとクリッピングする。`NSViewRepresentable` で `NSTextView` を直接ラップして制御する。

### `popover` の `isPresented` と `let` プロパティ

`@StateObject` / `@EnvironmentObject` の `let` プロパティ内の `@Published` には `$` bind が使えない。`Binding(get:set:)` で明示的に取得・設定する。

## 変更時のチェックリスト

- [ ] `./build.sh` が警告・エラーなしで完了する
- [ ] アプリ起動後、テキスト編集・送信が動作する
- [ ] ウィンドウ移動・リサイズが動作する
- [ ] ホットキー設定・動作が機能する
- [ ] 選択範囲送信が動作する
- [ ] Enter 確定オプションが動作する

## やらないこと

- Xcode プロジェクトの導入（`swiftc` 直接ビルドを維持）
- ファイルの過剰な分割（1ファイル構成を維持）
- クロスプラットフォーム対応（macOS 専用）
- 外部依存の追加（標準フレームワークのみ）
