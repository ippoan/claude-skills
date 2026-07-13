---
name: pr-watch
description: >
  desktop / CLI の Claude Code から GitHub の PR/Issue を「CI 失敗・新規コメント・merge/close」まで監視する。
  ユーザーが特定の PR や Issue を「監視して」「watch して」「マージまで追って」「CI 落ちたら教えて」
  「進捗を見張って」等と頼んだとき、または URL / 番号を貼って様子を追いたそうなときに必ず使う。
  desktop の Claude Code は CCoW と違い webhook push が届かない (pr-subscribe の re-wake 経路は
  CCoW web セッション限定、cc-relay #69) ため、既定では Claude を介さず「ユーザー自身の端末で回す
  gh delta/ETag ポーリングスクリプト」を渡す (LLM トークン消費ゼロ・セッションを閉じても生存)。
  CCoW web セッションで動いているなら pr-subscribe を使うこと (このスキルではない)。
---

# pr-watch — GitHub PR/Issue 監視 (desktop/CLI 向け)

## pr-subscribe との使い分け

同じ「PR を見張る」でも実行環境で正解が違う:

| 環境 | 使うスキル | 機構 |
|---|---|---|
| **CCoW (Claude Code on Web) セッション** | `pr-subscribe` | webhook push で session を re-wake (別 identity の comment/CI 失敗のみ、self-loop filter あり) |
| **desktop / CLI (このスキル)** | `pr-watch` | webhook push が届かないので、ユーザー端末で `gh` を delta/ETag ポーリング |

CCoW で動いているセッションなら `pr-subscribe` を使うこと。desktop/CLI (ターミナルの Claude Code、
IDE 拡張等) では push 経路が無いので、このスキルの端末スクリプト方式が唯一実用的な解になる。

## これは何を解決するか

「この PR を merge/close まで見張って」を素朴にやると、Claude 自身が定期ポーリングしたくなる。
だが desktop 環境ではそれが**高くつくか、そもそも効かない**:

- **connector のイベントキュー (`subscribe_issue_activity` + `get_pending_events`) は push ではない。**
  webhook は auth-worker の Durable Object に溜まるだけで、それを「反応」に変えるドレインは
  CCoW(web) の hibernate ライフサイクルにしか無い。desktop はそのライフサイクルが無く、
  remote MCP notification で勝手にターンも開始しないので、**溜めたまま何も起きない**。
- **`/loop` で Claude にドレインさせると、空ポーリングのたびに全コンテキストを再読込 = LLM トークンを毎 tick 消費**する。

したがって既定解は **「Claude を一切介さないスタンドアロンの `gh` ポーリングループをユーザーの端末で回す」**。
GitHub API rate しか使わず (delta/ETag モードなら idle は実質 0)、LLM トークンは 0、
Claude のセッションが閉じても動き続ける。これが速くて安い。

## 判断: どちらの方式を渡すか

| 状況 | 方式 |
|---|---|
| 既定 / 「監視して」「マージまで追って」 | **A: 端末スクリプト** (`scripts/watch-pr.ps1` or `.sh`) をユーザーが叩く |
| 「Claude 側で見張って」「このセッションで追って」と明示 | **B: Monitor ツール** (下記) — セッション寿命に紐づく |

迷ったら A。B はユーザーが Claude に張り付かせたいと明言したときだけ。

## A. 端末スクリプト (既定・推奨)

1. gh 認証を確認: `gh auth status`。未認証なら `gh auth login` はユーザーに促す (代行しない)。
2. スクリプトのパスとコマンドをユーザーに渡す。番号だけ差し替えれば他 PR にも使える。

**Windows / PowerShell:**
```powershell
powershell -ExecutionPolicy Bypass -File "%USERPROFILE%\.claude\skills\pr-watch\scripts\watch-pr.ps1" -Repo <owner/repo> -Pr <番号>
```

**Git Bash / Linux / macOS:**
```bash
bash ~/.claude/skills/pr-watch/scripts/watch-pr.sh <owner/repo> <番号>
```

オプション: PowerShell 版は `-IntervalSec 60` で間隔変更、`-NoBeep` でビープ抑制。
sh 版は第3引数で間隔秒。間隔を詰めても実質コスト0 (idle は 304 で rate 0、出力が無ければ
Claude 側のトークンも0) なので、迷ったら短め (10〜30s) でよい。

**挙動 (両版共通・delta/ETag モード):**
- 既定 120 秒間隔で、**issue** と **check-runs** の2本を**条件付きリクエスト (ETag → 304)** で叩く。
  無変化なら両方 304 = **rate limit 消費0・即返り** (GitHub 側が差分を計算して「変わってない」と返す)。
  変化があった endpoint だけ本体を読む。
- **新規/編集コメント** → issue が変化した時だけ `?since=<前回時刻>` で取得。**id だけでなく
  `updated_at` も追跡**し、新規は `COMMENT`、既存 id の本文書き換えは `COMMENT (edited)` として報告する。
  staging-deploy 通知のような **sticky bot (edit-in-place、スパム防止で新規投稿せず同一コメントを
  更新し続ける)** は id watermark だけだと一切検知できないので注意 (実際に踏んだ罠)。
- **CI 失敗** (terminal な `failure` / `timed_out` / `cancelled` / `startup_failure` / `action_required`) → 赤字で check 名。
  `in_progress` / `pending` は無視 (成功待ちを失敗と誤報しない)。REST の conclusion は小文字
- **merge / close** → 緑 `MERGED` か黄 `CLOSED` を出して**終了** (PowerShell 版はビープ)
- 停止は **Ctrl+C**

実装メモ:
- **`gh pr view` / `gh pr diff` / `gh run list` 等の高レベルサブコマンドは GraphQL** を使い、REST
  (`core`) とは別 rate 枠。調査中にこれらを多用すると GraphQL だけ枯渇し、それに依存する処理だけ
  突然落ちる。本スクリプトは head ref / state / merged_at をすべて `gh api repos/{o}/{r}/pulls/{n}`
  (REST) で取り、GraphQL に一切依存しない。
- PowerShell 版: `gh api` のヘッダ引数は ETag 内の `"` を PS5.1 が壊すため、条件付き GET は
  `Invoke-WebRequest` を使う (304 は例外で飛ぶので `catch` して StatusCode 304 を判定)。bash 版は
  `gh api --include` + `If-None-Match` でヘッダ安全に渡せる。
- `.ps1` は **ASCII のみ**で書く。Windows PowerShell 5.1 は BOM なしファイルを ANSI として読むため、
  日本語コメント/文字列入りだと偽のパースエラーや実行時文字化けになる。
- CI は PR head ref の check-runs を見る (fork 等で ref 取得不可なら CI 監視のみ無効化し
  comments/merge は継続)。

## B. Monitor 方式 (Claude セッション内で見張る場合のみ)

ユーザーが「Claude 側で追って」と明言したときだけ。`Monitor` ツールに **シェルの `gh` ポーリング**を
`persistent: true` で回させる。ポイントは **`get_pending_events` (MCP/LLM 経由) ではなく `gh` を直接**
叩くこと — そうすればアイドル中は Claude が起動せず LLM トークン 0、本物の変化 (CI 失敗・新コメント・
merge/close) が出た時だけ 1 ターン起きる。

Monitor に渡すコマンドの中身は `scripts/watch-pr.sh` (または `.ps1`) と同じロジック
(seed → sleep → 差分判定 → 終端で break)。silence ≠ success の原則通り、CI 失敗と終端状態の
両方を必ず emit させること。merge/close で `break` すれば自然終了する。

## よくある落とし穴

- **Issue 番号と PR 番号は共有**。GitHub では `/issues/46` と `/pull/46` は同一。
- **`gh` 内蔵 jq を使う** (`-q`)。外部 `jq` に依存しない (Windows で無いことが多い)。
- **CI が全部 skipped** のときは失敗ではない。`conclusion` が明示的な失敗系のときだけ鳴らす。
- **desktop の connector キューをドレインする方式は既定にしない** (上の「これは何を解決するか」の理由)。
- **sticky/edit-in-place コメント bot は id watermark だけでは検知不可**、`updated_at` も見る (上記)。
