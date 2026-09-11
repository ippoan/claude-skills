---
name: gh-actions-live
description: >
  GitHub Actions の run 状態変化を、Windows Chrome 拡張 (ippoan/gh-actions-live) →
  Linux の常駐 bridge → Monitor の ws /watch で **自分の repo / run だけ push で受け取る**運用。`gh run list` を sleep
  ループで叩く代わりに使う。Claude から拡張の設定・ウィンドウ起動・更新が
  github.com のタブ経由 / bridge 経由でできる。トリガー: 「CI を見張って」
  「PR の CI 待ち」「Actions を watch」「gh-actions-live」「bridge」「ダッシュボード
  開いて」「拡張の設定を入れて」「run の変化を通知」「update.xml / alive socket」等。
  Access 保護下の zone を Linux から叩くときの承認にも使う。トリガー:
  「Access ログイン」「cloudflared access login」「wrangler dev --remote が止まる」
  「access-login」「Approve が押せない」等。
---

# gh-actions-live — Actions の変化を push で受ける

**repo**: https://github.com/ippoan/gh-actions-live (public)。Release は main merge ごとに自動採番。

```
Windows Chrome 拡張 ──ws://<linux tailscale>:8799──▶ gh-actions-bridge (Rust、systemd --user で常駐)
   (extension = ダッシュボード / extension-bg = service worker)     │ ws /watch?repo=…&run=…
Claude ── POST localhost:8799/cmd {"command":...} ────────────────▶│ (条件に合う run だけ 1 行ずつ)
                                                                   ▼
                                                 各セッションの Monitor (ws ソース)
Claude ── Claude in Chrome で github.com タブ → chrome.runtime.sendMessage(<拡張ID>, {command:...})
```

拡張は GitHub の **Actions ページそのもの**をスナップショットにし、alive.github.com の
WebSocket を購読する。集約ダッシュボード (repo あたり 1〜2 件に畳むもの) と違い、
**同一 repo の並列 run が全部個別に見える**。

## 1. CI を見張る (Linux 側)

**bridge は systemd --user で常駐している。セッションから起動しない / 止めない**
(Node 版 `bridge/ws-bridge.mjs` は廃止 ippoan/gh-actions-live#42。セッションが起動していた頃は 8799 を取り合い、
全 repo の変化が起動したセッションにだけ流れて「無関係な通知」が続いた)。見張りは `/watch` に条件を付けて繋ぐ:

```
Monitor({ ws: { url: "ws://127.0.0.1:8799/watch?repo=ippoan/rust-alc-api&workflow=CI&run=1619" },
          description: "rust-alc-api CI #1619", persistent: true, timeout_ms: 3600000 })
```
- 1 フレーム = 1 通知 (`<repo> <workflow> #<run>: <from> → <to> [<ref>] — <title>`)。条件に合わない run は来ない
- 条件: `repo` / `ref` (branch 完全一致。長い名前は先頭 40 文字) / `run` / `workflow` (部分一致・大小無視) / `by`。
  同じ key を重ねると OR、違う key は AND。条件なしは 400 (`all=1` で全量)
- 繋いだ直後に現在値が 1 行来る (進行中の run と、`run` 指定の run)。既に終わった run でも待ちぼうけにならない
- `run` 指定なら、その run が終わると bridge が socket を閉じる (close 1000 `done`) = 見張りが自動で終わる。
  run 番号は workflow ごとなので `workflow` と併用。**re-run は同じ番号で走り直す** → 閉じた後に re-run したら張り直す
- PR の branch 全体を見るなら `ref=<branch>` (こちらは閉じない)
- **`ref` が付かない run・main 以外の ref で走る run がある**: `repository_dispatch` で走る workflow (例: Release Wave = release-wave-flip) は
  Actions ページに branch が出ないので `[<ref>]` 無しで流れ、`ref=main` に一致しない。タグ push で走る配信の CI は ref がタグ名 (`v0.0.162` 等)。
  PR → マージ → 配信まで見るなら /watch を分けて張る: ① `ref=<PR の branch>` ② `workflow=Release Wave` (repo と AND)。
  タグの CI は `ref=<タグ>` か `workflow=CI&run=<番号>`。実害 2026-09-11: `ref=main` だけで待ち、Release Wave の完了を取りこぼした (Refs ippoan/alc-app-s3#135)
- `watch: 拡張 (ダッシュボード) が…` の行は拡張が bridge から外れた / 戻った合図 (外れている間は変化が届かない)。
  bridge が落ちれば socket が閉じる
- watch 対象の repo は拡張の設定 (`set-config` の `repos`、**全セッション共通**)。無い repo は足す。
  **絞るために repos を減らさない** (他セッションの見張りが止まる)

bridge の状態:
- `curl -s localhost:8799/` の `clients` に `extension-bg@<win tailscale ip>` が居れば拡張が生きている。
  `extension@…` はダッシュボードが開いている印。`watchers` は今繋がっている /watch の条件
- 全 repo の変化・ack・接続ログは `journalctl --user -u gh-actions-bridge -f`
- 入っていない / 更新したとき: `cd ~/claude260730/gh-actions-live && cargo install --locked --path bridge`、
  初回だけ `cp bridge/gh-actions-bridge.service ~/.config/systemd/user/ && systemctl --user enable --now gh-actions-bridge`、
  更新後は `systemctl --user restart gh-actions-bridge`

**bridge を再起動すると拡張側は最大 30 秒で再接続**する (指数バックオフ)。

## 2. Claude から拡張を操作する

bridge 経由 (拡張が接続中のとき):
```
curl -s -X POST localhost:8799/cmd -d '{"command":"open-dashboard","mode":"popup"}'   # 遠隔でウィンドウを開く
curl -s -X POST localhost:8799/cmd -d '{"command":"set-config","repos":["o/r1","o/r2"],"notify":false}'
curl -s -X POST localhost:8799/cmd -d '{"command":"snapshot"}'      # 全 run の要約を bridge の journal に出す
curl -s -X POST localhost:8799/cmd -d '{"command":"update"}'        # native host → update.ps1 → 拡張が自分で reload
curl -s -X POST localhost:8799/cmd -d '{"command":"status"}'        # alive socket の診断 (ダッシュボードの {type:status} と bg の ack の 2 行)
curl -s -X POST localhost:8799/cmd -d '{"command":"alive-reset"}'   # alive socket を閉じて張り直す (status が connected:false のまま戻らないとき)
curl -s -X POST localhost:8799/cmd -d '{"command":"access-login","url":"https://<host>/cdn-cgi/access/cli?..."}'  # Access の承認ページを開く (§3)
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

## 3. Cloudflare Access のログインを通す (`access-login`)

**症状**: Access 保護下の zone に対して `wrangler dev --remote` を回すと、
`cloudflared access login` の対話待ちで**無限にブロック**する。承認できるブラウザが
Linux 側に無いのが原因なので、待っても放置しても解けない。

**★ これは無人化ではない。** 縮んだのは「承認できるブラウザを探して URL を開く」手間だけで、
`session_duration` ごと (既定 24h) に**人が Approve を押す運用は残る**。
無人で回る cron / スケジュール実行の途中にこの手順を挟まないこと (誰も押さないまま止まる)。

**解**: トークンを `cloudflared` のキャッシュに入れておけば通る。**承認を押すのは
Windows の Chrome でよい** — トークンを取りに行くのは Linux 側の `cloudflared` 自身で、
ブラウザは Approve を押すだけだから。
(実証 2026-08-27: `wrangler dev` Ready :8787 / `nuxt dev` Ready :3000 (HMR)、
`curl :8787` → 200 / `:3000` → 200)

```
# 0. 許可ホストを入れる (deny-by-default。未設定だと必ず拒否される)
curl -s -X POST localhost:8799/cmd -d '{"command":"set-config","accessLoginHosts":["dtako.ippoan.org"]}'

# 1. cloudflared を起動する。URL を出して承認を待ち受ける (ここでブロックする)
cloudflared access login dtako.ippoan.org

# 2. 出た URL を Windows Chrome に開かせる → 人が Approve を押す
curl -s -X POST localhost:8799/cmd \
  -d '{"command":"access-login","url":"https://dtako.ippoan.org/cdn-cgi/access/cli?..."}'
```

`get-config` に `accessLoginHosts` が返るので現在値を確認できる。

**有効期限は `session_duration` (既定 24h)。** 切れたら同じ手順で入れ直す。
キャッシュ本体 `~/.cloudflared/*token` (0600) は**残してよい**。

**★ トークンをログやファイルに残さない。** `cloudflared` は**標準出力に JWT を出す**。
リダイレクトで書き出したら取得後に `shred` / `rm` する。貼り付け・grep 結果・
親への報告にも載せない。

### 開ける URL の 4 条件 (v0.0.30 以降)

bridge に認証は無く、8799 に届く者が Chrome で任意のページを開けると capability の
穴になる。そこで `access-login` が開くのは**全条件を満たす URL だけ**:

1. スキームが `https:`
2. **userinfo が空** — `https://dtako.ippoan.org@evil.example.com/...` は見た目が
   正規ホストなのに開く先は evil。`URL.host` に userinfo は入らないので
   ホスト検査だけでは防げない
3. ホストが `accessLoginHosts` に**完全一致** (大小文字は無視。後方一致・ワイルドカード無し。
   `endsWith('.ippoan.org')` 型は `evil-ippoan.org` を通す)。
   **未設定・空配列なら全拒否** — 入れ忘れた環境が一番危険になる既定は採らない
4. パスが `/cdn-cgi/access/cli` **ちょうど** (`new URL()` が `..` を畳んだ後の値で)

**fail-closed 側の既知挙動 2 件** (どちらも「弾かれる」方向なので事故にはならないが、
初見だと設定ミスに見える):

- **ポート付きは allowlist に別エントリが要る。** 判定に使うのは `u.host` で**ポートを含む**ため、
  `dtako.ippoan.org:8443` は `dtako.ippoan.org` のエントリに一致しない。使うならポート込みで足す
- **末尾ドットの FQDN** (`dtako.ippoan.org.`) は弾く。正規化しないので完全一致から外れる

弾いた URL は**ログにも応答にも全体を出さない** (`token=` の nonce が乗るため。
出すのはホスト名とパスまで)。

## 4. Windows 側の導入 (1 回だけ・admin 不要)

1. Release の `gh-actions-live-x.y.z-x64.msi` を実行 (perUser)。
   `msiexec /i … REPOS=o/r BRIDGEURL=ws://<linux>:8799` で設定ごと入れられる
2. `chrome://extensions` → デベロッパーモード → 「パッケージ化されていない拡張機能を読み込む」→
   `%LOCALAPPDATA%\Programs\gh-actions-live\extension` (**ここだけ手動**。非管理 Windows では
   Chrome が Web Store 外の force_installed を捨てるため。`chrome://policy` に `[BLOCKED]` が出たらこれ)
3. 以降の更新はダッシュボードの「更新」ボタン (native host 経由) か、上の `update` コマンド

## 5. 罠 (踏み抜き済み)

- **`gh run list` をループで叩かない。** この拡張が watch 対象なら変化は勝手に届く。
  watch 対象に無い repo は `set-config` で足す
- **bridge をセッションから起動しない / kill しない。** 8799 は systemd の `gh-actions-bridge` が持つ。
  node の bridge を起動すると取り合いになり、systemd 側が `Address already in use` で再起動を繰り返す
  (journal に出る)。「無関係な通知が続く」は bridge の stdout を Monitor していたのが原因 → `/watch` で絞る
- `pkill -f '<文字列>'` は**その文字列を含む自分の bash -c ごと殺す** (exit 144 で何も出ずに終わる)。pid を指定して kill する
- PR を出した直後の `update` は「最新 = 旧版」と返ることがある (update.xml の反映が Release 完了から数秒遅れる)。少し待って再送
- ack / status の結果は `/watch` には来ない (通知ノイズ防止)。`journalctl --user -u gh-actions-bridge` を grep
- `.ps1` は **UTF-8 BOM 必須** (5.1 が Shift_JIS で読んで壊れる)。Release 資産は octet-stream なので
  `Invoke-WebRequest` の `.Content` が byte[] で返る。両方 update.ps1 で対策済み・CI で検査
- host_permissions に `release-assets.githubusercontent.com` が要る (`releases/latest/download` のリダイレクト先)
- 拡張ページからの alive WebSocket は `Origin: chrome-extension://` を弾かれる → DNR で書き換え (v0.0.19〜)
- 切断時に無条件で Actions ページを取り直すと 5 秒周期ポーリングになる → バックオフ必須
- 詳細な経緯・未解決は repo の issue と memory (`gh-actions-live-bridge`, `chrome-policy-needs-hklm-permachine`,
  `ps1-needs-utf8-bom-on-japanese-windows`)
- `ref=main` だけの /watch で配信を待たない (Release Wave は ref 無し、タグの CI は ref がタグ名。§1)
