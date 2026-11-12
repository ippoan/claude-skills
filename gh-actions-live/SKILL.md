---
name: gh-actions-live
description: >
  GitHub Actions の run 状態変化を、拡張 (ippoan/gh-actions-live。Linux の headless Chromium) →
  Linux の常駐 bridge → Monitor の ws /watch で **自分の repo / run だけ push で受け取る**運用。`gh run list` を sleep
  ループで叩く代わりに使う。Claude から拡張の設定・ウィンドウ起動・再読込が
  bridge 経由 / github.com のタブ経由でできる。トリガー: 「CI を見張って」
  「PR の CI 待ち」「Actions を watch」「gh-actions-live」「bridge」「ダッシュボード
  開いて」「拡張の設定を入れて」「run の変化を通知」「alive socket」等。
  Access 保護下の zone を Linux から叩くときの承認にも使う。トリガー:
  「Access ログイン」「cloudflared access login」「wrangler dev --remote が止まる」等。
  PR 作成時に bridge へ自動で繋ぐ Claude Mod (pr-bridge-watch、function hooks) の導入・挙動・
  archive との関係にも使う。トリガー: 「pr-bridge-watch」「Claude Mods」「function hooks」
  「CLAUDE_CODE_ENABLE_FUNCTION_HOOKS」「PR を作ったら自動で見張る」「Monitor が archive を塞ぐ」「[pr-bridge-watch:stop]」等。
  CI を会話の中・横に見せる口にも使う。トリガー: 「ウィジェット」「actions_dashboard」「右側パネル」
  「/actions-pane」「connector を繋ぎ直す」「ホスト診断」等。
---

# gh-actions-live — Actions の変化を push で受ける

**repo**: https://github.com/ippoan/gh-actions-live (public)。配布物 (Release / インストーラー) は無く、
作業ツリーの `extension/` を Chromium が `--load-extension` で直接読む。

```
Linux headless Chromium の拡張 ─ws://127.0.0.1:8799─▶ gh-actions-bridge (Rust、systemd --user で常駐)
   (extension = ダッシュボード / extension-bg = service worker)     │ ws /watch?repo=…&run=…
Claude ── POST localhost:8799/cmd {"command":...} ────────────────▶│ (条件に合う run だけ 1 行ずつ)
                                                                   ├─▶ 各セッションの Monitor (ws ソース)
                                                                   └─▶ POST /mcp (読み取りだけ) ─▶ ウィジェット / 右側パネル
Claude ── 拡張が入った Chromium の github.com タブ → chrome.runtime.sendMessage(<拡張ID>, {command:...})
```

拡張は GitHub の **Actions ページそのもの**をスナップショットにし、alive.github.com の
WebSocket を購読する。集約ダッシュボード (repo あたり 1〜2 件に畳むもの) と違い、
**同一 repo の並列 run が全部個別に見える**。

**拡張は Linux の headless Chromium だけで動く (#62。Windows の拡張・MSI・native host は #79 で撤去)。** 拡張を bridge と同じ Linux の headless Chromium
(`gh-actions-browser.service`、systemd --user) に載せて常駐させる。snap の Chromium、プロファイルは
`~/snap/chromium/common/gh-actions-live-profile`、CDP は `127.0.0.1:9223` だけ (外へ出さない — ログイン済み
ブラウザの全権になる)。GitHub のログインは `linux-browser/github-login.sh` (2FA は GitHub Mobile。
パスキーは headless で使えない)。導入は repo の README「Linux で拡張を動かす」(§4)。

## 0. 見る (ウィジェットと右側パネル)

見張り (§1 の Monitor) とは別に、run の一覧を**人に見せる**口が 2 つある。どちらも bridge の `POST /mcp`
(読み取りだけ) を読み、GitHub の API は叩かない。

- **ウィジェット**: PR を作ったら**その場で** connector の `actions_dashboard` を
  `{ repo: "<owner/repo>", since: "<PR 作成 1 分前の UTC>" }` で 1 回呼ぶ。**全 repo は出さない**。
  - ツールは claude.ai の custom connector 経由の `mcp__<uuid>__actions_dashboard` を使う。
    `claude mcp add` のローカル MCP (`mcp__gh-actions-live__…`) ではウィジェットは描かれない (テキストだけ)
  - Code タブのホストは `hostCapabilities` に `serverTools` を出さない (ウィジェットからの `tools/call` は -32601) が
    `serverResources` は出す → ウィジェットは `resources/read` (`gh-actions-live://dashboard?repo=…&since=…`) で
    5 秒ごとに更新する (#73 で診断・#74)。ウィジェット下の「ホスト診断」で `mode` (tools / resources / none) と
    `firstRead` が見える。`none` なら自動更新されないので呼び直す
  - **ウィジェットの HTML やツールの引数を変えたら、claude.ai の設定 → Connectors で connector を切断 → 接続し直す。**
    claude.ai は接続時に `ui://` を先読みして使い回す (bridge の入れ替えでも新しいセッションでも読み直さない)。
    古いかは見出しの版 (`v<版>+<HTML のハッシュ>`) で見分ける
- **右側パネル**: pr-bridge-watch 0.1.5 の `hooks/pane.tsx`。PR を作ると、その repo の run (PR 作成 1 分前以降) が
  Code タブの右側パネルに 5 秒ごとに出る。`/actions-pane owner/repo` で repo を足して開く (引数なしは開くだけ)。
  plugin の更新は**新しいセッションからしか効かない**
- push で現れた run は bridge が最初に見た時刻 (`seenAt`) を持つ (#76)。経過時間は実際より短く出うる

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

### PR を作ると自動で繋がる (pr-bridge-watch、Claude Mod)

**`gh pr create` / `pr-push.sh` の後に自分で Monitor を張らない。** plugin `pr-bridge-watch@gh-actions-live`
(ippoan/gh-actions-live の `mods/pr-bridge-watch`、function hooks = Claude Mods) が Bash の `tool.call` を包み、
PR の URL が出たら `gh pr view --json headRefName` の branch で `/watch?repo=…&ref=<branch>` に Monitor を張る。
tool 結果の直後に context が 1 行来るので、それを読んで判断する:

| context | 意味 / やること |
|---|---|
| `…に Monitor で繋いだ (task <id>)。local の branch が消えたら次の Actions 通知で…自動で止める` | 何もしない。通知を待つ |
| `pr-bridge-watch: この PR の CI はウィジェットで見せる…actions_dashboard を { repo, since } で 1 回呼ぶ` | 書いてある引数でそのまま呼ぶ (connector 経由。§0) |
| `… → Monitor (task X) は既に終わっていた` | bridge の再起動で Monitor が先に閉じていただけ (0.1.4〜)。害は無い |
| `local に branch <ref> が見つからず突合では止まらない` | 別 clone で作った PR 等。要らなくなったら自分で `TaskStop` |
| `bridge (…) に届かない。…戻ったら Monitor({ … })` | bridge を直し (§1 bridge の状態)、書いてある引数で自分で張る |
| `Monitor を張れなかった (…)` / `Monitor の起動に失敗 (…)` | 書いてある引数で自分で張る |
| `task ID が取れず自動では止められない` | 要らなくなったら自分で `TaskStop` (残すと archive が塞がる) |
| `branch が分からず bridge に繋いでいない` | `ref=<branch>` で自分で張る |
| `auto mode では hook から Monitor を張れない…CI を見張るため自分で Monitor({ … })` | **Claude desktop** の auto mode。書いてある引数で自分で張る (model が張った ws Monitor は通る) |
| `auto mode では hook から Monitor を張れない…gh pr checks で確認する` | CLI の auto mode。PR の監視か `gh pr checks` で見る |
| (何も来ない) | 同じセッション・同じ branch は二度張らない仕様。または mod が読まれていない (下の導入) |

- **CI の途中経過を会話に出さない。** queued ⇄ currently running は job の切り替わりで何度も行き来する。
  待つのは background の agent に任せ (hook の Monitor は `TaskStop` してよい)、報告は完了・失敗・merge の 1 回だけ
  (ユーザー指示 2026-11-12「むだにだすのやめろ」「agentにまかせろ」)。見た目はウィジェット / 右側パネル (§0) が受け持つ
- **Monitor は archive を塞がないように止まる。** persistent な Monitor は `archive_session` を「still has live work」で
  拒否させる。mod の止めどきは 3 つ (ログに `…を止めた` が出る):
  - **Actions 通知 (task-notification) が来るたびに全部の見張りを local branch と突合**し、消えていたら `TaskStop`。
    PR は親が作る → 子の archive + worktree-janitor で branch が消える → 親に次の通知が来た時点で止まる
    (通知が来るまでは残る。gh の polling はしない)
  - `archive_session { session_id: "self" }` の直前に全部止める
  - **他のセッションの archive が live work で断られたら**、mod が相手へ `[pr-bridge-watch:stop]` 入りの
    `send_message` を送って 3 秒後に 1 回やり直す。相手の mod はそれを飲み込み (turn を起こさない) 全部止める。
    やり直しの結果に `やり直して畳めた` / `まだ畳めない` が添えられる。**`[pr-bridge-watch:stop]` が本文で届いたら**
    相手の mod が古い / 入っていない — `TaskStop` で Monitor を止めるだけで返信は要らない
- **Claude desktop でも張る** (0.1.2〜。今の版は 0.1.5)。desktop の app が起こすのは Auto-fix オンの PR の失敗だけで、CI の成功・merge は
  届かない。desktop の Monitor は `persistent` が無く `timeout_ms` は 30 分まで — 切れたら通知が来るので同じ引数で張り直す。
  0.1.1 の「Claude desktop では app が PR の CI を監視するので…張らない」が出たら mod が古い (`claude plugin update`)。自分で
  `Monitor({ ws: { url: "ws://127.0.0.1:8799/watch?repo=<owner%2Frepo>&ref=<branch>" }, description: "…", timeout_ms: 1800000 })`
- Release Wave / タグの CI は ref が branch ではないので mod は張らない。配信まで見るなら §1 の注意どおり別に張る
- 導入 (Claude Code **2.1.260 以上**。デスクトップアプリの CLI は `~/.claude/remote/ccd-cli/<版>`):
  ```
  # ~/.claude/settings.json の env に "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1"
  claude plugin marketplace add ippoan/gh-actions-live
  claude plugin install pr-bridge-watch@gh-actions-live
  ```
  入れた / 更新した plugin は**起動中のセッションでは読み直されない** (新しいセッションから効く)。
  install 時の「userConfig option not yet set」は既定値 (`bridgeUrl` = `ws://127.0.0.1:8799`) で動くので無視してよい
- mod を直すときは ippoan/gh-actions-live の README「PR を作ったら bridge に自動で繋ぐ」と CLAUDE.md。
  **`plugin.json` の version を必ず上げる** (上げないと `claude plugin update` が「最新」と返して取り込まれない。#70 で踏んだ)。
  `hooks.json` の `modules` は 1 plugin に 1 つ (2 つ目は validate が拒否) → 入口 `hooks/index.ts` で束ねる

bridge の状態:
- `curl -s localhost:8799/` の `clients` に `extension-bg@127.0.0.1…` が居れば拡張が生きている。
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
curl -s -X POST localhost:8799/cmd -d '{"command":"status"}'        # alive socket の診断 (ダッシュボードの {type:status} と bg の ack の 2 行)
curl -s -X POST localhost:8799/cmd -d '{"command":"alive-reset"}'   # alive socket を閉じて張り直す (status が connected:false のまま戻らないとき)
```
拡張を読み直す (作業ツリーを `git pull` した後など) ときは `curl -s -X POST localhost:8799/cmd -d '{"command":"reload"}'`
(Chromium の起動時に `linux-browser/developer-mode.mjs` がデベロッパー モードをオンにしているので数秒で bridge に戻る。§5)。
`status` の `alive.connected:false` が続くなら `alive.lastState` / `alive.background.relay.readyState`
(0=CONNECTING 1=OPEN null=socket 無し) を見る。v0.0.22 以降は watchdog が勝手に張り直す (#25)。
`delivered_to: 0` なら拡張が繋がっていない。

github.com タブ経由 (**bridge URL が未設定でも届く**。鶏と卵の解):
拡張は `externally_connectable` で `https://github.com/*` からのメッセージを受ける。**拡張が入っている
ブラウザ = Linux の headless Chromium** の github.com タブ (拡張が開く pinned の Actions ページ等) で実行する
(CDP `127.0.0.1:9223` から。Claude in Chrome はユーザー自身の Chrome を操作するので、拡張の入っていない
そちらでは届かない):
```js
chrome.runtime.sendMessage('oaadakmclelmnaieokjbhldfacfckaaj',
  { command: 'set-config', repos: ['o/r'], bridgeUrl: 'ws://127.0.0.1:8799', notify: false }, r => r)
```
`chrome.runtime.sendMessage` が undefined なら拡張が古い (externally_connectable 無し) か未導入。
`get-config` で版と設定が分かる。
**別拡張の `chrome-extension://…/options.html` へは navigate できない** (Chrome が拒否)。

## 3. Cloudflare Access のログインを通す

**症状**: Access 保護下の zone に対して `wrangler dev --remote` を回すと、
`cloudflared access login` の対話待ちで**無限にブロック**する。承認できるブラウザが
Linux 側に無いのが原因なので、待っても放置しても解けない。

**解**: `cloudflared access login <host>` が出した承認 URL を、**そのままチャットに貼って**
ユーザーに開いてもらい、Approve を押してもらう。トークンを取りに行くのは Linux 側の
`cloudflared` 自身で、ブラウザは Approve を押すだけなので、**ブラウザはどこでもよい**
(ユーザーの手元の PC・スマホ)。

```
# cloudflared を背景で起動する。URL を出して承認を待ち受ける (ここでブロックする)
cloudflared access login <host>
# → 出た https://<host>/cdn-cgi/access/cli?... をチャットに貼り、ユーザーに Approve を押してもらう
```

**★ これは無人化ではない。** `session_duration` ごと (既定 24h) に**人が Approve を押す運用は残る**。
無人で回る cron / スケジュール実行の途中にこの手順を挟まないこと (誰も押さないまま止まる)。

**有効期限は `session_duration` (既定 24h)。** 切れたら同じ手順で入れ直す。
キャッシュ本体 `~/.cloudflared/*token` (0600) は**残してよい**。

**★ トークンをログやファイルに残さない。** `cloudflared` は**標準出力に JWT を出す**。
リダイレクトで書き出したら取得後に `shred` / `rm` する。貼り付け・grep 結果・
親への報告にも載せない (チャットに貼るのは承認 URL だけ)。

## 4. 拡張の導入

Linux の拡張の立ち上げ (systemd の `gh-actions-browser`・GitHub のログイン) は ippoan/gh-actions-live の
README「Linux で拡張を動かす」を見る。

## 5. 罠 (踏み抜き済み)

- **`gh run list` をループで叩かない。** この拡張が watch 対象なら変化は勝手に届く。
  watch 対象に無い repo は `set-config` で足す
- **bridge をセッションから起動しない / kill しない。** 8799 は systemd の `gh-actions-bridge` が持つ。
  node の bridge を起動すると取り合いになり、systemd 側が `Address already in use` で再起動を繰り返す
  (journal に出る)。「無関係な通知が続く」は bridge の stdout を Monitor していたのが原因 → `/watch` で絞る
- `pkill -f '<文字列>'` は**その文字列を含む自分の bash -c ごと殺す** (exit 144 で何も出ずに終わる)。pid を指定して kill する
- ack / status の結果は `/watch` には来ない (通知ノイズ防止)。`journalctl --user -u gh-actions-bridge` を grep
- alive の WebSocket は github.com のタブ (content script) で張る。拡張ページから張ると `Origin: chrome-extension://` で
  握手直後に 1006 で切られ、DNR では握手の Origin を変えられない (v0.0.19 で実測・失敗)
- **Chrome 133+ では unpacked 拡張はデベロッパー モードのときだけ有効。** オフだと `reload` で `unsupportedDeveloperExtension` として
  無効化され bridge に戻らない。`chromium.sh` が起動時にオンにしている。止まったら gh-actions-live の main clone で
  `node linux-browser/developer-mode.mjs` (再起動不要) か `systemctl --user restart gh-actions-browser`
- 切断時に無条件で Actions ページを取り直すと 5 秒周期ポーリングになる → バックオフ必須
- 詳細な経緯・未解決は repo の issue と memory (`gh-actions-live-bridge`)
- `ref=main` だけの /watch で配信を待たない (Release Wave は ref 無し、タグの CI は ref がタグ名。§1)
- **mod (pr-bridge-watch) で `$` を変数に代入しない。** `claude plugin validate` が拒否し、module ごと読まれない
  (install は成功して見える)。dispatch を越える timer は `session.start` で `$.clock.every(…)` の閉包を持つ
- **plugin が張った Monitor の task ID は transcript に残らない。** 旧版 (task ID を context に出さない) が張った
  Monitor は後から `TaskStop` できず、そのセッションの archive を塞ぐ → アプリのタスク一覧から止める
- **Monitor の通知ごとに「まだ終わっていません」と返さない。** 途中経過は黙り、完了・失敗・merge の 1 回だけ報告する (§1)
- **bridge を入れ替えると ws の Monitor は 1006 で閉じる。** CI の途中なら張り直すか、待ちを agent に任せる
