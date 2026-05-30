---
name: cdp-browser
description: >
  Chrome DevTools Protocol (CDP) 経由でリモート Windows Chrome を操作するスキル。
  スクリーンショット撮影、ページ遷移、クリック、テキスト入力、JS実行、HTML取得、PDF保存が可能。
  トリガー: 「ブラウザ」「スクリーンショット」「画面確認」「CDP」「Chrome操作」「ページを開いて」
  「画面を見て」「ブラウザで確認」「Webページ」などブラウザ操作に関するリクエスト時に使用。
---

# CDP Browser — リモート Chrome 操作

Windows Chrome に CDP (port 9223) で接続し、Playwright 経由で操作する。

## セットアップ

Windows 側で Chrome を起動済みであること:
```
chrome.exe --remote-debugging-port=9222 --remote-allow-origins=* --user-data-dir=C:\temp\chrome-debug
```
Windows 側で portproxy 設定済み（`0.0.0.0:9223` → `127.0.0.1:9222`）。

## コマンド

`scripts/cdp.js` を使用。環境変数 `CDP_ENDPOINT` でエンドポイント変更可（デフォルト: `http://100.95.51.87:9223`）。

```bash
CDP_SCRIPT="/home/yhonda/.claude/skills/cdp-browser/cdp-browser/scripts/cdp.js"
NODE_PATH="/home/yhonda/.npm/_npx/86170c4cd1c5da32/node_modules"
```

### tabs — タブ一覧
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT tabs
```

### screenshot — スクリーンショット
```bash
# ページ全体
NODE_PATH=$NODE_PATH node $CDP_SCRIPT screenshot /tmp/screenshot.png
# フルページ
NODE_PATH=$NODE_PATH node $CDP_SCRIPT screenshot /tmp/full.png --full
# 要素指定
NODE_PATH=$NODE_PATH node $CDP_SCRIPT screenshot /tmp/el.png --selector "table"
```
撮影後は Read ツールで画像を表示してユーザーに見せること。

### navigate — ページ遷移
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT navigate "https://example.com"
# 追加待機
NODE_PATH=$NODE_PATH node $CDP_SCRIPT navigate "https://example.com" --wait 3000
```

### click — クリック
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT click "button.submit"
```

### type — テキスト入力
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT type "input[name=email]" user@example.com
```

### eval — JavaScript 実行
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT eval "document.title"
```

### html — HTML 取得
```bash
# ページ全体
NODE_PATH=$NODE_PATH node $CDP_SCRIPT html
# 要素指定
NODE_PATH=$NODE_PATH node $CDP_SCRIPT html --selector "#main"
```

### pdf — PDF 保存
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT pdf /tmp/page.pdf
```

### wait — 要素待機
```bash
NODE_PATH=$NODE_PATH node $CDP_SCRIPT wait ".loading-done" --timeout 5000
```

## 典型的なワークフロー

### Web アプリの動作確認
1. `navigate` で対象ページに遷移
2. `screenshot` で画面キャプチャ → Read で表示
3. 問題があれば `click` / `type` で操作して再度 `screenshot`

### フォーム入力テスト
1. `navigate` でフォームページに遷移
2. `type` で各フィールドに入力
3. `click` で送信ボタンをクリック
4. `wait` で結果表示を待機
5. `screenshot` で結果を確認
