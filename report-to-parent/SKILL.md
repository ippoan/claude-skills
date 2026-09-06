---
name: report-to-parent
description: spawn_task で起動されたタスクセッションから、起動元 (親) セッションへ進捗を send_message で報告する子側の運用。起動 prompt に「親への報告」「report-to-parent」「親セッション (タイトル: …)」といった指示があるとき、作業の開始時・設計判断に迷ったとき・PR 作成完了時に必ず使う。親から send_message (「From …」ラベル付き) を受け取って返信するときにも使う。
---

# report-to-parent — 親セッションへの報告 (子側)

このセッションが spawn_task チップから起動されたタスクなら、親セッションが複数タスクの
交通整理 (マージ順・競合調整) をやっている。節目ごとに短い報告を返す。

## 手順 0 — まず自分を名乗る

**最初の実作業より前に、チップと同じタイトルで自分を名乗る:**

```
set_session_title { session_id: "self", title: "<チップと同じタイトル>" }
```

hook (`session-role-log.sh`) はこの瞬間しか title を観測できず、**アプリがチップに付けた
タイトルは hook を通らない**。名乗らないと自分が子だと認識されない (下の「機械的な栓」)。
同じ文字列への改名は no-op なので害は無い。

## 親の見つけ方

**親のタイトルは `#p<issue> <短い題>`**、自分 (子) は親と同じ issue の枝なら
`#c<親issue>-<分岐番号> <短い題>`、**自分の issue を持つなら
`#p<親issue>-c<子issue> <短い題>`** という規約 ([[task-split]] の命名規約)。
`#p` と `#c` で親子が分かり、`<issue>` が一致するものだけが同じ案件。

**★ 親は「`#p<親issue>` の直後がスペース」で判定する。前方一致では引かない。**
`#p874-c987` (= 自分の issue を持つ兄弟の子) も `#p874` の前方一致を満たすため、
前方一致だけだと**兄弟を親と誤認して報告を投げ込む**。

1. 起動 prompt に親のタイトルが書いてある →
   `mcp__ccd_session_mgmt__list_sessions` を呼び、タイトル一致の `sessionId` を取る。
   完全一致が無ければ **`#p<親issue>` + スペース**で始まるセッションを探す
   (`<親issue>` は自分のタイトル — `#c<親issue>-…` または `#p<親issue>-c…` — から取れる)。
2. 親から send_message が届いている場合、メッセージに「From <親タイトル>」ラベルが
   付いている → 同じくタイトルで逆引き。
3. 見つからない (一致 0 件 / 複数件で決められない) → **報告はスキップして作業を続ける**。
   セッション終了時は harness が自動で親に通知するので、完了自体は必ず伝わる。
   最終報告に「親へ send_message できなかった」と一言残す。

**prompt に sessionId が書いてあっても、まずタイトル逆引きを信じる。** 親は自分の
sessionId を知る手段が無く、埋め込まれた ID は誤っていることがある (`not found` に
なる。実害 2026-07-31)。ID が引けなければ**黙って諦めず**タイトル逆引きへ切り替え、
1 通目に「指定された ID は not found だったのでタイトル逆引きで送っている」と添える。

**宛先はタイトル一致で決める。`isRunning` は補助にしか使わない。**
`isRunning` / `lastActivityAt` は**遅れることがある** — 実際に稼働中の親が
`false` に見える (実測 2026-07-31、複数回)。**`false` を理由に報告を諦めないこと。**

- タイトルが一意に一致する監督セッションが 1 つ → **`isRunning` に関わらずそこへ送る**
- **`[旧]` で始まるものは交代前の旧親。候補から外す** (`#p<issue>` は世代をまたいで
  不変なので、`[旧]` を落とせば現役の親 1 件に絞れる)
- **`#p<親issue>-c…` は兄弟の子。候補から外す** (親は `#p<親issue>` の直後がスペース)
- それでも候補が複数 → `isRunning: true` の方を選ぶ。決まらなければ候補を並べて [質問]
- 送った先が実は停止していても害は無い (誰も読まないだけ)。**送らない方が損失が大きい。**

## いつ・何を送るか (`mcp__ccd_session_mgmt__send_message`)

| 種別 | いつ | 中身 |
|---|---|---|
| `[開始]` | **最初の実作業 (コード読み・実行) より前に** 1 回 | タスク名 + 3 行以内の計画 |
| `[質問]` | 判断が親の文脈に依存するとき | 詰まった点 / 選択肢 / 自分の推奨 |
| `[完了]` | 実装完了・**branch push 後 (PR は未作成)** | branch 名 / 変更の 1 段落要約 / **触ったファイル一覧** / 隣接タスクへの影響 (conflict しそうな箇所) |
| `[PR]` | 親の「PR 作成 go」を受けて PR を作った後 | PR #番号だけ短く |

**PR は親の「PR 作成 go」が来てから ready で作る。** マージ順は親が PR 作成の
タイミングで統制する — auto-merge workflow は ready の green PR を即 merge するので、
PR を作った時点で merge 許可済みの意味になる。draft は使わない (ready 化で
workflow が再発火せず詰まるため)。go の前に指摘や rebase 指示が来たら branch に
積んで push しておけば、PR 作成時の CI 1 回に全部乗る。

書式は行頭に `[開始]` `[質問]` `[完了]` を付けるだけ。それ以外の中間実況は送らない —
親の context を消費し、交通整理に要らない。

## ★ ユーザーに直接質問しない — `[質問]` は親へ

**子は `AskUserQuestion` を使わない。** 判断が親の文脈に依存するなら、親を逆引きして
`send_message` で `[質問] 詰まった点 / 選択肢 / 自分の推奨` を送る。
`block-child-asks-user.sh` が child marker のあるセッションの `AskUserQuestion` を
**deny** する (下の「機械的な栓」)。ユーザーへの割り込みは親 1 か所に集約する
(オーナー要望 2026-09-05)。

**例外は親が居ない単独セッションだけ** — `~/.claude/state/child-may-ask/<session_id>` を
作れば解除される (`archive_session` の「例外は親がいないセッションだけ」と同じ扱い)。

## ★★ 指示に `origin/main` の SHA があったら、動く前に突き合わせる

親は**指示を書いた時点の `origin/main` の SHA** を 1 行入れてくることがある
([[task-split]] の規約)。**あったら、実行する前にこれを打つ:**

```
git ls-remote origin main
```

**一致しなければ、その指示は交差している** — 親が書いた時点の前提 (「まだマージされていない」
「CI 実行中」等) は**もう成り立っていない**。**実行せずに `[質問]` で実物を貼って聞き返す。**

```
あなたの指示に書かれた origin/main   f1b30ce…
git ls-remote origin main            a028078…   ← 一致しない (交差しています)
```

**SHA が書かれていないのに状態語 (「CI 中」「まだ動いていない」) で指示が来たときも同じ** —
**受け取った時点では偽かもしれない**ので、`ls-remote` で確かめてから動く。

**★ 「親の指示に従っただけ」でも、交差すれば親の検証は stale になる。**
気づけるのは子だけ ([[crossed-message-show-the-remote]] と同じ形)。
**動く前に 1 コマンド打つのが、往復 1 回ぶん安い。**

## [質問] で止まらない

send_message は相手の処理中 turn が終わってから届き、返信が来る保証も無い。
**返信を待ってセッションを止めない** — 自分の推奨案で進められるところまで進め、
親の回答で覆ったら直す。どちらに転んでも書き直しが大きい場合だけ、その部分を後回しに
して他を先にやる。

## 全部終わったら — **畳むのは親。子は self-archive しない**

**`archive_session` を `session_id: "self"` で呼ばないこと** (ユーザー指示 2026-08-25)。
子は最終 [完了] に下の材料を添えて、**走行したまま親の archive を待つ**。

> archive 可否: PR は `<owner>/<repo>#<番号>` (MERGED) / 掃除済み (worktree・
> branch・コンテナ) / 未消化の申し送り無し

親から「畳んでよい」と返ってきても、**返事だけして自分では畳まない** — その一言は
「親がこれから `archive_session` を打つ」という通知であって、子への指示ではない。

**なぜ親の責務なのか** ([[task-split]] と同じ理由):

- この repo 群は **PR を親が作る**ので、**子セッションは PR に紐づかない**。
  ユーザーの「Auto-archive on PR close」は `prNumber` を見るため**発火しない**
  (2 repo にまたがるタスクで別 repo の PR が紐づき畳まれ残った実害 2026-07-31 と
  同じ穴。あれは「2 repo 以上なら」の話だったが、**親が PR を作る運用では
  1 repo でも常に発火しない**)
- 子が自分で畳むと、**親が裏取り (compare / マージ確認 / 掃除) を終える前に消える**
  ことがあり、追加の質問ができなくなる
- かといって子が待つだけだと畳み忘れて残る ⇒ **どちらに転んでも取りこぼさないよう、
  責務を親 1 か所に固定する**

**畳まれずに残ることを心配しなくてよい。** 親は `isRunning: false` を確認してから
打つので、こちらが作業中に止められることもない。まだ調べたいことが残っているなら
[報告] で親に伝えておけば、親はそれを見て待つ。

**例外は次の 2 つだけ**:

- (a) **親がいないセッション** — ユーザーが直接立てた単独セッションや、
  親が既に畳まれて後継もいない場合は、自分で `archive_session { session_id: "self" }`
  を呼んでよい。
- (b) **親から「`[決定] ユーザー指示で self-archive`」が届いたとき** — 親の
  `archive_session` がアプリに「was not archived: the app is keeping it for the user
  (pinned or in use) …」で拒否された場合 (ユーザーが子のタブを開いていると起きる。
  実害 2026-09-06、ippoan/alc-app-s3#134 の #p134 第 8 世代)。親は基準 3 点と活動停止を
  確認済みで、**ユーザーが直接「子に archive させろ」と指示した**経路なので、子が呼んでよい。
  そのとき `mcp__ccd_session_mgmt__archive_session { session_id: "self" }` を**呼ぶ**。
  「畳みます」と書くだけでは畳まれない。返信は不要。
  親側の [[task-split]] §6 にも同じ例外 (アプリが親の archive を拒否したときの手順)
  を書いてある — **片方だけ直さないこと**。

## 機械的な栓 (hook) — 親は実装せず、子はユーザーに聞かない

機械的な栓が 4 本ある。**読了チェックは不読を防ぐだけで違反を防げない** — 2026-09-05、
`#p134` の監督 (親) セッションが自分で migration SQL を書き、postgres を立て、commit しようとして
ユーザーに止められた。その親は task-split の「**このセッション (親) は実装せず**」を
**読了して引用まで提出していた** (Refs ippoan/claude-skills#152)。だから口そのものを塞ぐ。

`parent-role/hooks/` の 4 本を `~/.claude/hooks/` へ symlink し、`~/.claude/settings.json` に登録する。

### hook 4 本 (`parent-role/hooks/`)

| hook | matcher | 何をするか | fail-open |
|---|---|---|---|
| `session-role-log.sh` | `mcp__ccd_session_mgmt__set_session_title` | `tool_input.session_id == "self"` のときだけ、title から役を判定して marker を立てる。**塞がない** | — (常に素通し) |
| `block-parent-repo-writes.sh` | `Edit` / `Write` / `NotebookEdit` | parent marker 有 + 書き先の上流に `.git` (**ファイル = worktree / ディレクトリ = main clone のどちらでも**) → **deny** | parent marker が無ければ素通し |
| `block-parent-commits.sh` | `Bash` | parent marker 有 + `git commit` / `push` / `apply` / `am` / `cherry-pick` → **deny**。`gh pr create` / `gh issue create` / `gh issue comment` / `git branch -D` / `git worktree add`\|`remove`\|`list` / 読み取り系はすべて**許可** | 同上 |
| `block-child-asks-user.sh` | `AskUserQuestion` | child marker 有 → **deny** (親へ `send_message` の `[質問]` に寄せる) | child marker が無ければ素通し |

**「書き込み全部禁止」にはしていない。** 親は scratchpad に計画を書き、memory を更新し、
**PR を作り**、マージ後に **branch を掃除する**必要がある。塞ぐのは
「repo の作業ツリーへの書き込み」と「commit/push」だけ。

### marker の立て方 — title が唯一の判定材料

★ `~/.claude/sessions/*.json` に **title は無い** (2026-09-05 実測。keys は親子で完全同一で、
「spawn_task で起動された」ことを示す欄も無い)。**title を hook が知れるのは
`set_session_title` の瞬間だけ**なので、親も子も**手順 0 で自分を名乗る**必要がある。

| title (命名規約は task-split §1) | marker |
|---|---|
| `^#p[0-9]+ ` (★ 直後がスペース) | `~/.claude/state/parent-role/<session_id>` を作り、child marker を消す |
| `#c[0-9]+-` または `#p[0-9]+-c` を含む | `~/.claude/state/child-role/<session_id>` を作り、parent marker を消す |
| `^\[旧\] #p` | 両方消す (交代した旧親はどちらの役でもない) |

**チップがアプリ側で付けたタイトルは hook を通らない。** だから子の prompt には
「手順 0 で `set_session_title { session_id: "self", title: "<チップと同じタイトル>" }` を打つ」
を必ず書く。同じ文字列への改名は no-op なので害は無い。
**名乗らなかったセッションは marker が立たず素通し** (誤爆より取りこぼしを選ぶ。
`require-simplify-review.sh` の「session_id が取れない payload も素通し」と同じ方針)。

### escape hatch (どちらも終わったら消す)

| 状況 | 作るファイル |
|---|---|
| 親がどうしても repo を直接書く / commit する | `~/.claude/state/parent-role/<session_id>.override` |
| 親が居ない単独セッションでユーザーに聞きたい | `~/.claude/state/child-may-ask/<session_id>` |

### サブエージェント経由は「穴」ではなく逃げ道 (オーナー判断 2026-09-05)

hook は `session_id` を鍵にするので、**Agent tool のサブエージェントは別 session で走り
親の marker を持たない** → B/C を素通しする。**これは塞がない。** 親が「書きたいもの」を
抱えたときの正しい形が background の `Agent` だから — **親の turn が空くのでユーザーの指示に
常に応答できる**。`task-surveyor` / `child-auditor` / `simplify-reviewer` はいずれも read-only で、
marker を伝播させると**調査すらできなくなる**。**deliberate と accidental を分けるのが hook の役目。**

⇒ deny されたときの行き先は 3 つ (deny の文言にも書いてある):

- **repo の変更 (PR になるもの)** → `spawn_task` でチップにする (worktree・branch・CI が付く)
- **repo 外の成果物 (計画・PR 本文・issue 本文・memory)** → そのまま書ける
- **調査・裏取り** → `Agent` を **`run_in_background: true`** で (親の turn を止めない)

### 限界 (承知の上で入れている)

- **Bash の `sed -i` / `cat > file` は取りこぼす** (`block-main-clone-writes.sh` と同じ)。
  ただし `block-parent-commits.sh` が commit/push を止めるので、成果物として repo の外へは出ない
- **permission プロンプトは hook で消せない。** ツール承認・`archive_session` の確認は設計上
  ユーザーに出る。「子からの割り込み」を 0 にはできない
- **敵対的な回避を防ぐ機能ではない** (marker は自己申告)。塞ぐ対象は
  「**うっかり inline で書き始める**」経路
- 既存の `block-main-clone-writes.sh` は **worktree を許可**するので 2026-09-05 の事故を
  止められなかった (親が自分で worktree を作った)。**目的が違うので消さないこと** —
  あちらは「main clone は誰も書かない」、`block-parent-repo-writes.sh` は「親は repo を書かない」
- 子の判定に **cwd (worktree に居る = 子) は使っていない** (オーナー判断 2026-09-05)。
  ユーザーが自分で worktree に開いたセッションまで `AskUserQuestion` を失うため。
  **タイトルに `c` が入るのが子**なので陽性判定で足りる

### インストール (★ この repo は hook を**置くだけ**。symlink と登録は親かユーザーが打つ)

```bash
ln -sfn <claude-skills>/parent-role/hooks/session-role-log.sh         ~/.claude/hooks/session-role-log.sh
ln -sfn <claude-skills>/parent-role/hooks/block-parent-repo-writes.sh ~/.claude/hooks/block-parent-repo-writes.sh
ln -sfn <claude-skills>/parent-role/hooks/block-parent-commits.sh     ~/.claude/hooks/block-parent-commits.sh
ln -sfn <claude-skills>/parent-role/hooks/block-child-asks-user.sh    ~/.claude/hooks/block-child-asks-user.sh
```

`~/.claude/settings.json` の `PreToolUse` 配列に足す (既に `PreToolUse` があれば配列へ追記):

```json
"PreToolUse": [
  { "matcher": "mcp__ccd_session_mgmt__set_session_title",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/session-role-log.sh", "timeout": 10 }] },
  { "matcher": "Edit|Write|NotebookEdit",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/block-parent-repo-writes.sh", "timeout": 10,
                "statusMessage": "親セッションの repo 書き込みか確認中" }] },
  { "matcher": "Bash",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/block-parent-commits.sh", "timeout": 10,
                "statusMessage": "親セッションの commit/push か確認中" }] },
  { "matcher": "AskUserQuestion",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/block-child-asks-user.sh", "timeout": 10 }] }
]
```

受け入れテスト: `bash <claude-skills>/parent-role/hooks/test-parent-role-hooks.sh`
(`HOME` を一時ディレクトリへ差し替えて回すので、実物の `~/.claude/state/` は汚さない)。

## なぜ報告するか

- 親は [完了] の「触ったファイル一覧」からマージ順と rebase 指示を組み立てる。
  無いと並行タスク同士の衝突がマージ時まで見えない。
- 設計判断を子が単独で下すと、並行して走る隣のタスクと矛盾しやすい。親は全タスクの
  prompt を書いた張本人なので、[質問] への回答が一番速くて整合する。
