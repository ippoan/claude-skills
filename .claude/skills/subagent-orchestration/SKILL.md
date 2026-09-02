---
name: subagent-orchestration
description: CCoW の重コンテキスト環境で sonnet サブエージェントを thrash させずに回すオーケストレーション運用書。planner→plan-reviewer→coder→code-reviewer の開発ループと diet-worker→diet-reviewer の CLAUDE.md ダイエットループを、確定済みの再利用 agent 定義 (.claude/agents/) で駆動する。親 (Opus) が「絶対パスを渡す・短ターンに縛る・wave で並列する・自分で検証する」ための手順。トリガー:「subagent thrash」「サブエージェント 落ちる」「autocompact thrashing」「並列 diet」「diet-worker」「coder agent」「code-reviewer agent」「planner agent」「sonnet subagent 設計」「agent オーケストレーション」「wave 実行」等。
---

# subagent-orchestration — 重コンテキストで sonnet subagent を確実に回す

CCoW は attach 全 repo の CLAUDE.md を**セッション開始スナップショット**として注入し、
sonnet サブエージェントはこの巨大な基底 (~150k) を継承する。これを踏まえた実運用書。

## 確定した事実 (実測、ippoan/claude-md#90 の session で検証)

- **注入はセッション開始スナップショット (attach-list 由来)。live disk を読んでいない**
  → セッション途中で repo / CLAUDE.md を削除しても subagent の token は不変
  (152,941 vs 152,878 = 差 63 token/0.04% = 実質同一 = 空振り)。**「途中で消す・別フォルダに
  clone」は無意味。**
- **短ターン subagent (1 read → 出力) は full context でも 57KB を読んで完遂して survive**。
  thrash の正体は「基底固定 → 残余 ~30-50k を **各ターンの (ツール結果サイズ + 報告サイズ)
  の累積**が食い潰す」。初期に落ちたのは「多数 Write → report ターンで反復 autocompact」型。
- durable な効きどころは 2 つ: **(1) lazy skill 化 (=CLAUDE.md ダイエット、次セッションの
  スナップショットを縮める) + (2) 短ターン指示**。削除の choreography は不要。

## 再利用 agent 定義 (`.claude/agents/`、全 sonnet・`context: fork` なし)

| agent | tools | 役割 |
|---|---|---|
| `planner` | Read/Grep/Glob | 実装計画 + PR 分割 + リスク (read-only) |
| `plan-reviewer` | Read/Grep/Glob | 計画レビュー (抜け・過大/過小分割) |
| `simplify-reviewer` | Read/Grep/Glob/Bash(固定)/ToolSearch | 計画の肥大化検査 (根本 vs 症状 / 削れる複製の実測 / 既存実装 / 純減の収支 / 担保)。運用は `simplify-review`。hook が ExitPlanMode / spawn_task を未通過のあいだ塞ぐ |
| `coder` | Read/Write/Edit/Grep/Glob | 実装 (Bash なし= fmt/test は親) |
| `code-reviewer` | Read/Grep/Glob/Bash(固定) | 差分レビュー (重大度順) |
| `diet-worker` | Read/Write/Edit | CLAUDE.md 骨格化 + map へ verbatim 移設 |
| `diet-reviewer` | Read/Bash(固定) | diet の 4 点検証 (サイズ/追記のみ/欠落/規範) |
| `task-surveyor` | Read/Grep/Glob/Bash(固定)/ToolSearch | 分割前の調査 (座標・既存実装・罠)。運用は `parent-fanout` |
| `child-auditor` | Read/Grep/Glob/Bash(固定) | 子 branch の裏取り (compare vs [完了] 申告)。運用は `parent-fanout` |

**この skill が扱うのは「1 セッション内で実装を回すループ」** (planner→coder→review)。
**複数の子セッション (spawn_task) を監督する親が、調査と子 PR の裏取りを並列に逃がす
ループは `parent-fanout`** — 下 2 行の agent はそちら側の道具で、`task-split` と対になる。
subagent の thrash 対策・短ターン・wave の考え方はこの skill が正本で、`parent-fanout`
からも参照している。

起動は `agentType: <name>`。制約 (tools allowlist + 手順表 + 報告フォーマット) は
定義に焼いてあるので、**親は「可変データ (絶対パス) を渡す」だけでよい**。
前提: `CLAUDE_CODE_SUBAGENT_MODEL` 未設定 (設定されると `model: sonnet` が上書きされる)。

## 開発ループ

```
planner → (plan-reviewer ∥ simplify-reviewer) → coder → code-reviewer → 親が commit/PR
```

- `planner` に課題 + 対象**絶対パス**を渡す → 計画テキストを得る。
- 大きな設計なら `plan-reviewer` に計画テキスト + 関連 source パスを渡す。
- **`simplify-reviewer` には必ず通す** (計画原文 + repo 絶対パス + 基点 SHA)。plan-reviewer と
  並列でよい。[BLOCKER]/[MAJOR] を計画に反映してから coder へ (運用と hook は `simplify-review`)。
- 計画の各 PR を `coder` に渡す (絶対パス + 変更範囲を明示)。coder は Bash が無いので
  **fmt/test/commit は親がやる**。
- `code-reviewer` に diff (本文で渡す or repo パス) を渡してレビュー。code-reviewer の
  固定 Bash は **read-only の `git diff`/`log`/`show --stat`/`wc` のみ** (test/build は含まない
  = 親と重複しない)。
- 親が `cargo fmt`/test 等 → commit → PR。**git 操作・test 実行は必ず親**。

## CLAUDE.md ダイエットループ

```
diet-worker → diet-reviewer → 親が audit.sh 確認 → commit/PR (1 PR/repo)
```

- `diet-worker` に **2 つの絶対パス** (対象 `<repo>/CLAUDE.md` と
  `<repo>/.claude/skills/<repo>-map/SKILL.md`) を渡す。map が無ければ新規作成を指示。
- `diet-reviewer` に repo パス + 両ファイルパスを渡して 4 点検証 (pass/fail)。
- 親が `claude-md-audit` skill の `audit.sh <repo>/CLAUDE.md` で ≤50行/2000字 を最終確認。
- commit + PR。map 更新と CLAUDE.md 骨格化は同 PR。

## 並列 wave (親の運用)

- **thrash は並列度と無関係** (各 subagent は独立 context)。制約は親の report 蓄積
  (固定フォーマットなら 1 repo 数百 token で無視可) と検証スループット。
- **5 並列 × 複数 wave**。wave 完了 → 検証 → commit → 次 wave で失敗を wave 内に閉じ込める。
- **巨大 CLAUDE.md (rust-alc-api 級 50KB+) は単独 wave に隔離**。隔離理由は並列度ではなく
  **worker 単体の context 消費 (read + 移設本文出力) と親の検証負荷**が大きいため。
- 巨大 repo を分割する場合は **必ず直列** (worker A 完了 → worker B)。同一 CLAUDE.md /
  同一 map SKILL.md を 2 worker が並列 Write/Edit すると lost update になる。

## 親の検証チェックリスト (worker にやらせない / `diet-reviewer` に委譲可)

`audit.sh` は `claude-md-audit` skill (`scripts/audit.sh`、≤50行2000字 + `claude-md-size-exempt`
marker + `.claude/` 除外)。検証 2/3 は **diet-worker def の「触るのは 2 ファイル」「SKILL.md は
追記のみ」制約と対**なので、片側だけ改訂して乖離させないこと。

1. `audit.sh <repo>/CLAUDE.md` → ≤50行/2000字
2. `git -C <repo> status --short` → **既存 map 更新時は modified 2 ファイル / 新規 map 時は
   modified(CLAUDE.md) 1 + untracked(SKILL.md) 1** のみ
3. **既存 map 更新時のみ**: `git diff -- <SKILL.md>` が**追加行のみ** (削除・frontmatter
   変更あれば reject)。**新規 map 時**は全行追加なので diff 判定はせず、frontmatter 雛形
   (`name`/`description`/`generated-from`/`paths`) が正しいか目視 (generated-from の tree-sha
   は **親が付与**。worker は Bash 無しで取れない)
4. **欠落**: 旧 CLAUDE.md 削除行から特徴トークン 5-8 個 grep → map に全出現
5. **規範残存 (最重要)**: 旧 CLAUDE.md を `禁止|しない|必須|してはいけない` で grep した
   hard constraint / 安全系が **骨格 CLAUDE.md に残っている** こと。**map のみに移っていたら
   reject** (map は lazy で読まれず消灯するため。骨格 or map の "or" は不可)
6. **発見可能性**: 新/更新 map の `description` に、移設した見出し由来のトリガー語が入っている
   こと (無いと silent knowledge loss)
7. **捏造チェック**: 骨格 CLAUDE.md の diff を目視し、元に無い記述を worker が発明していないか

### reject 後
- 差分指摘のみを添えて同 agent に再 dispatch (fresh context)。**上限 2 回**、超えたら親が直接直す
  (反復 dispatch で親コストが膨らむのを防ぐ = この skill が防ごうとする挙動の再現回避)。

## 指示テンプレート (可変データのみ渡す)

diet-worker:
```
対象 repo: <name>
読む/書くファイル (この 2 つ以外触るな):
- /home/user/<repo>/CLAUDE.md
- /home/user/<repo>/.claude/skills/<repo>-map/SKILL.md
  (無ければ Read エラーを 1 回確認 → 追記でなく新規 Write、frontmatter 雛形: <雛形>)
定義の手順表どおり 3 ターンで完結。git 操作は不要 (親がやる)。
```

## アンチパターン (指示に書くと thrash / 品質低下)

- 「慎重に再確認」「書いた後 read で検証」「diff を取って確認」→ 再 read / Bash でターン増。
- 「他 repo も参考に」「関連規約と整合」→ read の fan-out。
- 「TodoWrite で進捗管理」「作業過程を詳しく報告」→ report 肥大 (report ターンで死ぬ)。
- 「2000字以内・ただし情報を捨てるな」を**移設ルール無しで**併記 → 書き直しループ。
  必ず「map へ verbatim 移動しろ」とセットで言う (要約するな、移動しろ)。

## 切り分け (agent def と skill の責務)

- **agent 定義** (`.claude/agents/*.md`) = worker の不変制約 (tools・手順・報告・禁止)。
- **本 skill** = 親の運用 (repo 選定・wave 構成・パス充填・検証・commit/PR)。
- **起動プロンプト** = 可変データ (repo 名・絶対パス) のみ。

_設計 SoT: fable-advisor (ippoan/claude-md#90 session)。size gate/PreToolUse guard/audit は導入済み。_
