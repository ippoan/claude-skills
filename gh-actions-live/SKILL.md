---
name: gh-actions-live
description: >
  GitHub Actions の run 状態変化を、Windows Chrome 拡張 (ippoan/gh-actions-live) →
  Linux の ws-bridge → Monitor で **push で受け取る**運用。`gh run list` を sleep
  ループで叩く代わりに使う。Claude から拡張の設定・ウィンドウ起動・更新が
  github.com のタブ経由 / bridge 経由でできる。トリガー: 「CI を見張って」
  「PR の CI 待ち」「Actions を watch」「gh-actions-live」「bridge」「ダッシュボード
  開いて」「拡張の設定を入れて」「run の変化を通知」「update.xml / alive socket」等。
---

# gh-actions-live — Actions の変化を push で受ける

**repo**: https://github.com/ippoan/gh-actions-live (public)。Release は main merge ごとに自動採番。

```
Windows Chrome 拡張 ──ws://<linux tailscale>:8799──▶ bridge/ws-bridge.mjs ──stdout──▶ Monitor (通知)
   (extension = ダッシュボード / extension-bg = service worker)      ▲
Claude ── POST localhost:8799/cmd {"command":...} ────────────────────┘
Claude ── Claude in Chrome で github.com タブ → chrome.runtime.sendMessage(<拡張ID>, {command:...})
```

拡張は GitHub の **Actions ページそのもの**をスナップショットにし、alive.github.com の
WebSocket を購読する。集約ダッシュボード (repo あたり 1〜2 件に畳むもの) と違い、
**同一 repo の並列 run が全部個別に見える**。

## 1. セッションで最初にやること (Linux 側)

```
Monitor({ command: "cd ~/claude260730/gh-actions-live && exec node bridge/ws-bridge.mjs 8799",
          description: "gh-actions-live bridge", persistent: true })
```
- stdout 1 行 = 1 通知 (`<repo> <workflow> #<run>: <from> → <to> [<ref>] — <title>` / `snapshot: N runs…`)
- ack / status / 接続ノイズは **stderr** (= Monitor の出力ファイル `/tmp/claude-1001/…/tasks/<id>.output` を grep)
- `curl -s localhost:8799/` の `clients` に `extension-bg@<win tailscale ip>` が居れば拡張が生きている。
  `extension@…` はダッシュボードが開いている印

**bridge を再起動すると拡張側は最大 30 秒で再接続**する (指数バックオフ)。

## 2. Claude から拡張を操作する

bridge 経由 (拡張が接続中のとき):
```
curl -s -X POST localhost:8799/cmd -d '{"command":"open-dashboard","mode":"popup"}'   # 遠隔でウィンドウを開く
curl -s -X POST localhost:8799/cmd -d '{"command":"set-config","repos":["o/r1","o/r2"],"notify":false}'
curl -s -X POST localhost:8799/cmd -d '{"command":"snapshot"}'      # 全 run を stdout に要約
curl -s -X POST localhost:8799/cmd -d '{"command":"update"}'        # native host → update.ps1 → 拡張が自分で reload
curl -s -X POST localhost:8799/cmd -d '{"command":"status"}'        # alive socket の診断 (ダッシュボードの {type:status} と bg の ack の 2 行)
curl -s -X POST localhost:8799/cmd -d '{"command":"alive-reset"}'   # alive socket を閉じて張り直す (status が connected:false のまま戻らないとき)
```
`status` の `alive.connected:false` が続くなら `alive.lastState` / `alive.background.relay.readyState`
(0=CONNECTING 1=OPEN null=socket 無し) を見る。v0.0.22 以降は watchdog が勝手に張り直す (#25)。
`delivered_to: 0` なら拡張が繋がっていない。

github.com タブ経由 (**bridge URL が未設定でも届く**。鶏と卵の解):
Claude in Chrome で `https://github.com/...` を開き `javascript_tool` で
```js
chrome.runtime.sendMessage('oaadakmclelmnaieokjbhldfacfckaaj',
  { command: 'set-config', repos: ['o/r'], bridgeUrl: 'ws://<linux>:8799', notify: false }, r => r)
```
`chrome.runtime.sendMessage` が undefined なら拡張が古い (externally_connectable 無し) か未導入。
`get-config` / `native-ping` で版と native host の有無が分かる。
**別拡張の `chrome-extension://…/options.html` へは navigate できない** (Chrome が拒否)。

## 3. Windows 側の導入 (1 回だけ・admin 不要)

1. Release の `gh-actions-live-x.y.z-x64.msi` を実行 (perUser)。
   `msiexec /i … REPOS=o/r BRIDGEURL=ws://<linux>:8799` で設定ごと入れられる
2. `chrome://extensions` → デベロッパーモード → 「パッケージ化されていない拡張機能を読み込む」→
   `%LOCALAPPDATA%\Programs\gh-actions-live\extension` (**ここだけ手動**。非管理 Windows では
   Chrome が Web Store 外の force_installed を捨てるため。`chrome://policy` に `[BLOCKED]` が出たらこれ)
3. 以降の更新はダッシュボードの「更新」ボタン (native host 経由) か、上の `update` コマンド

## 4. 罠 (踏み抜き済み)

- **`gh run list` をループで叩かない。** この拡張が watch 対象なら変化は勝手に届く。
  watch 対象に無い repo は `set-config` で足す
- PR を出した直後の `update` は「最新 = 旧版」と返ることがある (update.xml の反映が Release 完了から数秒遅れる)。少し待って再送
- ack は stdout に出ない (通知ノイズ防止)。結果は Monitor の出力ファイルを grep
- `.ps1` は **UTF-8 BOM 必須** (5.1 が Shift_JIS で読んで壊れる)。Release 資産は octet-stream なので
  `Invoke-WebRequest` の `.Content` が byte[] で返る。両方 update.ps1 で対策済み・CI で検査
- host_permissions に `release-assets.githubusercontent.com` が要る (`releases/latest/download` のリダイレクト先)
- 拡張ページからの alive WebSocket は `Origin: chrome-extension://` を弾かれる → DNR で書き換え (v0.0.19〜)
- 切断時に無条件で Actions ページを取り直すと 5 秒周期ポーリングになる → バックオフ必須
- 詳細な経緯・未解決は repo の issue と memory (`gh-actions-live-bridge`, `chrome-policy-needs-hklm-permachine`,
  `ps1-needs-utf8-bom-on-japanese-windows`)
