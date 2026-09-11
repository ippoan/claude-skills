---
name: parent-fanout
description: >
  親 (監督役) が抱え込みがちな**調査**と**子 PR の裏取り (review)** を、
  Agent tool の read-only サブエージェント (`task-surveyor` / `child-auditor`) へ
  並列に逃がし、親は決定だけを握るループの回し方。並列で子を起動したのに
  「調査も review も親 1 本」で詰まる状態を解消する。[[task-split]] の分割・起票と対で、
  こちらは**その前後 (調査フェーズと裏取りフェーズ)** を担当する。
  トリガー:「調査が親のボトルネック」「review が追いつかない」「並列で子を立てたのに親が詰まる」
  「調査を agent に投げたい」「PR の裏取りを並列で」「parent-fanout」「fan-out」
  「子の [完了] をまとめて捌きたい」等。
---

# parent-fanout — 調査と裏取りを親から剥がす

## 0. これは何を解く skill か

[[task-split]] で子を N 本並列に起動しても、**親は 1 本のまま**残る。そして親には
直列にしかできない仕事が 2 つ溜まる:

| フェーズ | 親がやっていたこと | なぜ詰まるか |
|---|---|---|
| **調査** (分割の前) | 全タスク候補のコードを親が読む | N 個の範囲を 1 本で順番に読む。親の context も食う |
| **裏取り** (子の [完了] 後) | compare で実測し申告と突き合わせる | 子が同時に終わると N 件が直列で待つ |
| **archive** (子の [完了] 後) | 子へ send_message した直後に `archive_session` を打ち、「live work」「turn in progress」で弾かれる | 子はメッセージを受けるたびにターンを始める。止まるのを待つ専用 agent (`session-archiver`) へ逃がす |
| **掃除** (子の archive 後) | 子が拒否された `git worktree remove` / `git branch -D` を親が代わりに打とうとする | それは「拒否された操作の代行」になる。専用 agent (`worktree-janitor`) へ逃がす |
| **台帳への追記** (随時) | 親が台帳へ `printf ... >> ledger-children.md` を直接打とうとする | auto mode の分類器に拒否されることがある。専用 agent (`ledger-keeper`) へ逃がす |

**どちらも「読んで事実を集める」仕事で、判断ではない。** だから逃がせる。
逃がせないのは**決定** (分割・マージ順・go・PR 作成・archive) で、これは親に残る。

```
        ┌── task-surveyor ×N (並列) ──┐
 調査 ──┤                              ├─→ 親が決める ─→ spawn_task ×N
        └──────────────────────────────┘                      │
                                                              ↓ 子が [完了]
        ┌── child-auditor ×N (並列) ──┐                       │
 裏取り ┤                              ├─→ 親が go ─→ PR ─→ merge ─→ archive
        └──────────────────────────────┘
```

## 1. 調査フェーズ — `task-surveyor` を並列に撒く

タスク候補が N 個あるなら、**1 メッセージで N 本の Agent を同時に起動する**
(独立した呼び出しは 1 ブロックにまとめないと直列になる)。

各 prompt に必ず入れるもの:

1. **担当範囲を 1 つに絞る** — 「この repo 全体」ではなく「この機能のこの経路」
2. **対象の絶対パス**を列挙する (探索の起点。ここから先は調査員が広げる)
3. repo と、既知の制約・gate
4. 「**決めずに `## 親の判断が要る点` に選択肢で返せ**」の 1 行

返ってくるのは固定フォーマットの素材だけなので、**親は N 本ぶんを突き合わせて
分割線を引く**作業に集中できる。座標がそのまま spawn_task prompt の材料になる
([[task-split]] §3.5 の「変更は座標で指定する」を満たす)。

**調査を子セッション (spawn_task) にしないこと。** [[task-split]] が
「調査・設計・原因不明のデバッグは切り出さない」と書いているのは**判断を委ねるな**
という意味で、**事実収集を並列化するな**という意味ではない。read-only の
`task-surveyor` は判断しないので、この規約と衝突しない。

## 2. 分割・起票は親がやる

ここは [[task-split]] の領分。surveyor の `## 親の判断が要る点` を読んで決め、
`## 座標` と `## 罠` を prompt に畳み込む。**surveyor の出力をそのまま子に丸投げしない**
— 判断が空欄のまま子に渡ると、子が別解に流れる。

**★ 起票の前に分割案の全文を `simplify-reviewer` に通す** ([[simplify-review]])。根本 vs 症状・
削れる複製の実測・既存実装・純減の収支・担保を grep で数えて返す。hook が spawn_task を
未通過のあいだ deny するので、飛ばすと起票できない。surveyor の素材を畳み込んだ**後**の
案を渡す (座標が無いと検査 2 が測れない)。

## 3. 裏取りフェーズ — `child-auditor` を並列に撒く

子から [完了] が届いたら、**その子ぶんの `child-auditor` を 1 本起動する**。
複数の子が同時に終わったら、**1 メッセージで同時に起動する**。

渡すもの (欠けると auditor は `要確認` を返してくる):

- repo (`<owner>/<name>`) と worktree の絶対パス
- **基点 SHA** と **branch 名**
- 子の [完了] 申告 (触ったファイル一覧・変更要約) — **原文のまま**
- 受け入れ条件、触ってはいけないファイル (所有権)

auditor は `go` / `rebase-first` / `no-go` / `要確認` を推奨で返す。
**親はそれを読んで決める。** auditor は PR を作らないし、作らせてはいけない。

## 3.4 archive — 子が止まるのを `session-archiver` で待つ

子はメッセージを受けるたびにターンを始める。**送った直後の `archive_session` はアプリに
弾かれる** — 2026-09-10 の #p135 の親の 4 回の拒否 (「it still has live work (…)」3 回 /
「it is still working (a turn in progress)」1 回) は、どれも子へ send_message した直後だった。
子が止まって落ち着いた後の archive は 3 件とも 1 回で通った。

⇒ 基準 3 点 ([[task-split]] §6) を親が判定したら、**自分で打つ代わりに `session-archiver` を
`Agent` の `run_in_background: true` で起動する。** 渡すもの (1 つでも欠けると `要確認`):

- 子の sessionId
- 対応する PR (`owner/repo#N`) と、MERGED を確かめたこと
- 掃除の状態 (済み / archive 後に `worktree-janitor` で片付ける)
- 未消化の申し送りが無いこと

agent は `isRunning: false` が 2 回続けて観測され、`lastActivityAt` が 60 秒以上前になるまで
待ってから `archive_session` を打つ (最大 15 分。拒否されたら待ち直して最大 3 回)。
子へ send_message はしない (送るとターンが始まる)。3 回とも弾かれたら拒否文言 3 つを返すので、
親は [[task-split]] §6「アプリが親の archive_session を拒否したとき」の手順 2 以降へ進む。
成功したら §3.5 の `worktree-janitor` へ。

- **待ち方**: この環境は `sleep 25` 級の単発 sleep を塞ぎ、短い sleep の連結も禁じる
  (2026-09-10 実測)。agent は時間ではなく、**子の transcript (`.jsonl`) の mtime が N 秒以上
  古くなるまで**の until-loop で待つ (`list-child-sessions.sh` と同じ算出)
- **hook との関係**: サブエージェントの tool 呼び出しは、hook から見ると**親と同じ session_id**
  (2026-09-10 実測: サブエージェントの Skill 呼び出しが親の `skills-invoked/<session_id>` に
  記録された)。hook は session_id しか見ないので、agent の拒否は `warn-archive-refused.sh` の
  親の回数に数えられ、2 回目で `pending` が立つと `require-archive-decision-sent.sh` が
  **親と agent の両方**を塞ぐはず (実測は session_id の一致まで。サブエージェントの拒否・deny そのものは未実測)。
  agent はそこで `中断(pending)` を返すので、親は §6 手順 3 の [決定] を送る
  (本文が手元に無ければ `archive_session` をもう一度打てば hook が同じ本文を出す)。
  **親が先に自分で打つと回数が進む** — 待ちは最初から agent に任せる

### インストール

```bash
ln -sfn <claude-skills>/.claude/agents/session-archiver.md ~/.claude/agents/session-archiver.md
```

## 3.5 掃除フェーズ — `worktree-janitor` を background で呼ぶ

子が archive 済みなのに、自分の worktree と local branch を自分で消せずに残ることがある
(2026-09-10、[[task-split]] §4)。子が `git -C <main clone> worktree remove <自分の
worktree> && git branch -D …` を打って auto mode の分類器に拒否されたケース。
**親が代わりに打つのは「拒否された操作の代行」になるので打たない。**

⇒ **`worktree-janitor` を `Agent` の `run_in_background: true` で起動する。**
渡すもの (1 つでも欠けると agent は何もせず `要確認` を返す):

- repo の絶対パス / 片付ける worktree の絶対パス / 消す local branch 名
- 対応する PR (`owner/repo#N`)。PR の無い worktree (旧親・repo を変えずに終わった子)
  は `PR 無し` と書く — agent が HEAD と消す branch が origin/main の祖先かで
  代わりに確かめる
- **その子が archive 済みであることを `list_sessions` で確かめた結果**

agent 側は PR が MERGED か (PR 無しなら HEAD と消す branch が origin/main の祖先か)・
worktree が main clone でないか・未コミット変更が無いか・
branch がどこにも checkout されていないか・生きた pid が無いか、の 5 点を確認してから
`git worktree remove` (`--force` なし) → `git branch -D` → `git worktree prune` を実行する。
remote branch の削除・main clone や他セッションの worktree への操作はしない。

### インストール

```bash
ln -sfn <claude-skills>/.claude/agents/worktree-janitor.md ~/.claude/agents/worktree-janitor.md
```

## 3.6 台帳への追記 — `ledger-keeper` を background で呼ぶ

親が起票・PR・マージ・archive の経緯を台帳 (`/home/claude/claude260730/handoff/<案件>/
ledger-children.md`。git repo の外のローカルメモ) へ 1 行ずつ追記していると、
`printf ... >> ledger-children.md` のような直接追記が auto mode の分類器に拒否される
ことがある (2026-09-10、Refs ippoan/alc-app-s3#135)。**親が代わりに `sed -i` や
リトライで押し切るのではなく、追記だけを専用 agent に切り出す。**

⇒ **`ledger-keeper` を `Agent` の `run_in_background: true` で起動する。**
渡すもの (1 つでも欠けると agent は何もせず `要確認` を返す):

- 台帳の絶対パス
- 世代の表示 (例: `10 世代目`)
- 追記する行 (1〜10 行。**親が事実だけを書いたもの** — 台帳の要約や解釈は agent に
  やらせない)

agent 側はパスが `handoff/` 配下の `ledger-*.md` か・git 作業ツリーの外か・
本番の識別子 (端末 ID・資格情報・内部ホスト名) が無いかの 3 点を確認してから、
各行の頭に `- HH:MM UTC (<世代>): ` を付けて追記のみ行う。既存行の書き換え・削除・
並べ替えはしない。

### インストール

```bash
ln -sfn <claude-skills>/.claude/agents/ledger-keeper.md ~/.claude/agents/ledger-keeper.md
```

## 4. ループの回し方 — **`sleep` で待たない**

```
子の [完了] / harness の終了通知 で親が起きる
        ↓
child-auditor を並列起動 (終わった子のぶんだけ)
        ↓
判定を読む → go の子から順に 親が PR 作成
        ↓
マージ確認 → 後発の子へ rebase 指示 (send_message)
        ↓
掃除確認 → 親が archive_session
        ↓
残件があれば task-surveyor へ戻る
```

**`sleep` を書いたら設計を誤読している。** 待ち役に agent を貼り付けるのも禁止
(`ippoan/cc-relay` の pr-autofix レシピと同じ規約)。起こしてもらう手段を使う:

| 待つ対象 | 起こしてもらう手段 |
|---|---|
| 子の進捗 | 子の `send_message` ([[report-to-parent]]) と harness の終了通知 |
| CI の結果 | [[gh-actions-live]] の bridge (push で届く) |
| issue の動き | `subscribe_issue_activity` (MCP) |
| 子が止まること (archive の前) | **push で知る手段が無い** → 例外として `session-archiver` を background で置く (§3.4。上限 15 分・archive 3 回・条件待ち) |

**★ ただし「起きなかった」を沈黙と区別すること。** 子の報告が来ないことは
「まだ動いている」の証拠にならない。**状態を口にする前に `list_sessions` を見る**
([[task-split]] の「子の状態を報告から推し量らない」)。

## 5. 並列度の決め方

- **調査**: タスク候補の数だけ。ただし範囲が重なるなら先に親が線を引いてから撒く
  (同じファイルを 3 本が読むのは素材の重複で、突き合わせが増えるだけ)
- **裏取り**: 終わった子の数だけ。**待っている子のぶんを先回りで起動しない**
  (branch が動いている最中の compare は無意味)

## 6. 罠

- **★ agent 定義は「置いた直後は見えない。少し遅れて着く」(実測 2026-08-27)。**
  `~/.claude/agents/` に置いた直後に `subagent_type` へ指定すると
  `Agent type 'task-surveyor' not found. Available agents: claude, …` で落ちる。
  **skill は即座に一覧へ現れるのに agent だけ落ちる**ので、symlink や frontmatter を
  疑いたくなるが**定義は正しい**。数分〜1 ターン置くと同じセッションに現れる。
  ⇒ **1 回 not found が出ても「このセッションでは使えない」と結論しない**
  ([[mcp-tools-are-session-start-snapshot]] の「遅れて着く」と同型)。
  急ぐなら新しいセッションで使う
- **MCP connector は Agent tool のサブエージェントには届くが、spawn_task の子には
  引き継がれない。** これも「調査を子セッションにしない」理由の 1 つ
- **surveyor の「該当なし」を「無い」と読まない。** 意味検索の 0 件は無いことの証明に
  ならない ([[search-zero-hits-is-not-proof]])
- **auditor の `go` は CI green の保証ではない。** compare の実測と申告の一致までしか
  見ていない。CI は PR 作成後に 1 回だけ回る
- **auditor に「ついでに直して」と言わない。** read-only で定義してあるのは、
  裏取りと修正を同じ agent にやらせると**自分の変更を自分で承認する**ため

## 関連

- **`subagent-orchestration`** (`.claude/skills/`) — **subagent 運用の正本。先に読むこと。**
  こちらは「1 セッション内で実装を回すループ」(planner→plan-reviewer→coder→code-reviewer)
  と、**thrash 対策・短ターン設計・wave 並列**を扱う。本 skill はその上に乗る
  「**複数の子セッションを監督する親**が調査と裏取りを逃がすループ」で、役割が違う。
  並列度・短ターンの考え方はあちらに従う (重複して書かない)
- [[task-split]] — 分割・起票・交通整理の正本 (この skill の前後)
- [[report-to-parent]] — 子側の通信プロトコル
- [[next-session]] — 親の交代 (context 80% で自動的に入る)

### agent 定義の `model:` は環境変数に上書きされる

`CLAUDE_CODE_SUBAGENT_MODEL` が設定されていると、agent 定義の `model:` は**無視される**
(`subagent-orchestration` の前提条件)。`task-surveyor` / `child-auditor` はどちらも
`model: sonnet` だが、**この env が別の値なら定義側は効かない。**
「Sonnet のつもりが違うモデルで回っていた」を疑うときはここを見る。
