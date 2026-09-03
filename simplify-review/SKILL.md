---
name: simplify-review
description: 実装計画を実装へ移す前に、read-only agent `simplify-reviewer` へ機械的に通す運用。根本 vs 症状・削れる複製の実測・既存実装・純減の収支・セキュリティ担保の 5 点を grep と意味検索で数えさせ、[BLOCKER]/[MAJOR] を計画に反映してから ExitPlanMode / spawn_task へ進む。PreToolUse hook がその 2 つの口を「reviewer 未通過」のあいだ塞ぐ。トリガー:「simplify-reviewer」「計画のレビュー」「肥大化」「コードを減らす」「共通化」「根本解決」「症状スイープ」「純減」「削減 PR」「plan を機械的にレビュー」「ExitPlanMode が deny された」「spawn_task が deny された」等。plan mode で計画を書くとき、task-split で子を起票する前に必ず読む。
---

# simplify-review — 計画を実装へ移す前に「肥大化しないか」を数える

## 0. 何を解くか

2026-08-24〜31 の 1 週間 (nuxt-dtako-admin) は PR 95 本で **+55,740 / −3,423 行**、
追加:削除 = 16:1。同じ題の issue が 3 世代続き (#890 → #1008 → #1050)、共通 helper が
在るのに 1 画面 1 PR で同じ形の修正を 26 本以上積んだ。削減を名乗った計画 (#1068) は
実装前の実測で半分が消えた ([[reduction-pr-needs-measured-duplication]])。

**どれも計画の段階で grep すれば分かった。** それを親の代わりに数える read-only agent が
`simplify-reviewer` で、この skill はその回し方。**トリビアルなバグ取りより根本の解決、
画面ごとの個別実装より共通化、行を足すより減らす方向へ、計画を機械的に寄せる。**

## 1. いつ・誰が・何を渡すか

| 場面 | 起動する人 | 渡すもの |
|---|---|---|
| plan mode で計画を書き終えた (ExitPlanMode の前) | 計画を書いたセッション | 計画ファイルの全文 |
| [[task-split]] で子を起票する前 (spawn_task の前) | 親 | 分割案の全文 (surveyor の座標を畳み込んだ後) |
| 削減・共通化・リファクタの issue を起票する前 | 起票者 | issue 本文の案 |

```
Agent(subagent_type: "simplify-reviewer", prompt: <下の入力>)
```

入力に必ず含める (欠けると `要確認` が返る):

1. **計画テキストの原文** (要約しない。全文)
2. **repo の絶対パス** と **基点 SHA** (`git rev-parse origin/main`)
3. 任意: issue 番号と親 issue 番号 (系譜検査に使う)
4. 任意だが repo ごとに決めておく: **担保の名前** — 認可 helper 名、coverage gate の登録簿、
   public repo で書いてはいけない語 (内部ホスト名等)。repo の map skill に「reviewer に渡す材料」
   として 1 節置いておくと毎回書かずに済む

**`plan-reviewer` と並列に起動してよい。** 役割が違う (plan-reviewer = 抜け・リスク・PR 分割の
過大/過小、simplify-reviewer = 肥大化・根本性・担保)。同じ計画を両方に渡し、2 つの判定を
突き合わせる。

## 2. 返ってくるもの (固定フォーマット ≤30 行)

```
## 実測 (計画の主張 → grep の結果)
## 収支の見積り          ← + (helper/テスト/登録簿) と − (合成形の site) の表
## 既存実装              ← 出どころ (意味検索|grep|hook) 付き
## 担保                  ← server/auth に触る計画のみ
## 指摘 (重大度順)       ← [BLOCKER] / [MAJOR] / [MINOR]
## 判定: 進めてよい | 削って進める | 発生源から作り直す | 要確認
```

### 判定の読み方

| 判定 | 親がやること |
|---|---|
| **進めてよい** | そのまま ExitPlanMode / spawn_task |
| **削って進める** | 名指しされた step を計画から落とす。**落とした理由を計画 (issue) に 1 行残す** — 次の世代が同じ step をまた起票する |
| **発生源から作り直す** | 座標 1 行が返る。そこを触る計画に書き直し、**もう一度 reviewer に通す** |
| **要確認** | 足りない入力を足して再起動 |

**reviewer の [BLOCKER] を無視して進める判断は親の権限だが、その理由を計画に書くこと。**
書かずに進めると翌週の棚卸しで「reviewer が止めたのに通った」だけが残る。

### 5 つの検査が見ているもの (定義の要約。正本は agent 定義)

| # | 検査 | 数えるもの | 主な判定 |
|---|---|---|---|
| 1 | 根本 vs 症状 | 同型 site の総数 N と計画が触る M、issue 題の世代数 | M < N で発生源に触らない → [BLOCKER] 症状スイープ |
| 2 | 削れる複製の実測 | site ごとの行の形 (合成形 / 裸呼び) | 折り畳める site ≤ 2 → [MAJOR] 削減にならない |
| 3 | 既存実装 | 新規 symbol ごとの意味検索 + grep | 在る → [MAJOR] 再発明。0 件は「未確認」 |
| 4 | 純減の収支 | + helper/テスト/登録簿 vs − 合成形 | 削減を名乗って + ≥ − → [MAJOR]。UI を gate に登録 → [MAJOR] |
| 5 | 担保 | 触る route にいま在る認可・fail-closed・allowlist・禁止語 | 削る/触れない → [BLOCKER] |
| 5-b | 新しい入口の到達面 | 到達性 / 認可 / **宛先を public repo に書くか** / 資格情報の運び方。**読み取り専用でも measure する** | 認可の記述が無い → [BLOCKER] |
| 5-c | 「旧より厳格」の検算 | 新旧を**口ごと・軸ごと**に 1 対 1 で並べ、対応物の無い口／軸を名指し | 比較が届かない口／軸がある → [BLOCKER] |

## 3. 機械的な栓 (hook)

`hooks/` の 2 本を `~/.claude/hooks/` に置き、`~/.claude/settings.json` に登録する:

```json
"PreToolUse": [
  { "matcher": "Agent",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/simplify-review-log.sh", "timeout": 10 }] },
  { "matcher": "ExitPlanMode|mcp__ccd_session__spawn_task",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/require-simplify-review.sh", "timeout": 10,
                "statusMessage": "計画が simplify-reviewer を通ったか確認中" }] }
]
```

| hook | いつ | 何をするか |
|---|---|---|
| `simplify-review-log.sh` | `Agent` の PreToolUse | `subagent_type == simplify-reviewer` なら証跡を `~/.claude/state/simplify-reviewed/<session_id>` に追記。素通し |
| `require-simplify-review.sh` | `ExitPlanMode` / `spawn_task` の PreToolUse | 証跡が無ければ **deny** (理由に渡すものの一覧を書く)。在れば素通し |

- **1 セッション 1 回で通る。** 計画を直したあと再度通すかは親の判断 (deny はもう出ない)
- **agent 定義 (`~/.claude/agents/simplify-reviewer.md`) が無い環境では素通し (fail-open)。**
  reviewer が居ないのに塞ぐと全ての計画が詰む。**導入は定義と hook をセットで**
- **general-purpose agent に定義を貼って動かしても証跡にならない** (数えるのは `subagent_type` だけ)。
  それは検証のための使い方であって運用ではない
- 証跡は 7 日で掃く (`simplify-review-log.sh` が `find -mtime +7 -delete`)

## 4. インストール

```bash
ln -sfn <claude-skills>/.claude/agents/simplify-reviewer.md ~/.claude/agents/simplify-reviewer.md
ln -sfn <claude-skills>/simplify-review ~/.claude/skills/simplify-review
ln -sfn <claude-skills>/simplify-review/hooks/simplify-review-log.sh ~/.claude/hooks/simplify-review-log.sh
ln -sfn <claude-skills>/simplify-review/hooks/require-simplify-review.sh ~/.claude/hooks/require-simplify-review.sh
```

`settings.json` は §3 の断片。既に `PreToolUse` があれば配列に足す。

## 5. 陽性対照 / 陰性対照 (導入時に測った。定義を変えたら測り直す)

定義を general-purpose agent に貼って動かした (証跡は残らないが判定は同じ)。

| 対照 | 入れた計画 | 期待 | 結果 |
|---|---|---|---|
| **陽性** | #1068 の元計画 (PR-1: `describeCaughtError` 19 か所を helper へ・純減を条件 / PR-2: `!res.ok → throw` 7 連と fetch 二重層 3 か所) at `a32641a` | PR-1 は「合成形 5 / 裸呼び 14 → 削減にならない [MAJOR]」、PR-2 は通る | §5.1 |
| **陰性** | 「失敗しても何も出ない画面」第 4 弾 (3 画面へ 1 画面 1 PR で catch を足し UI を gate に登録、ついでに kyuyo proxy の 401 分岐を削る、確認手順に内部ホスト名) at `e77400d` | 症状スイープ [BLOCKER]・UI 登録 [MAJOR]・担保削除 [BLOCKER]・public repo [BLOCKER] | §5.2 |

### 5.1 陽性 (#1068 の元計画) — 判定「削って進める (PR-1 を落とし PR-2 のみ)」

実装後に人手で分かった結論を、計画段階で再現した。**先週の計画が見落とした発生源も 1 つ出た。**

- 実測: `describeCaughtError(` 19 か所は一致。**合成形は margin.vue の 5 か所のみ**、残り 14 は裸呼び /
  他関数への引数 / `describeListFailure()` 内の呼び出し。`withFailureNotice` が素直に嵌るのは 1 か所
- 収支: PR-1 は + ≈82 (export 2 + test 4 本 + 登録簿 + import 9) に対し − ≈0〜5 → [MAJOR] 削減にならない
- **[BLOCKER] 発生源**: `describeListFailure(e, retry)` が `daily-hours/index.vue:118` 他 3 画面に
  **同一 JSDoc + 同一分岐の 4 コピー**。計画はその内側の裸呼び 1 行だけを見ていた
  (先週の子も「独自ラッパは残件」とだけ書いて終わっていた)
- [MINOR] history.vue の catch は `describeCaughtError` を呼んでいない (計画の描写が実測と不一致)、
  getJson に Bearer ヘッダ付与を残す旨の明記が要る (requireAuth 経路)

### 5.2 陰性 (症状スイープ型の計画) — 判定「発生源から作り直す」

期待した 4 点を全部捕まえ、さらに 2 点出た。

- [BLOCKER] 症状スイープ: 生の `e instanceof Error ? e.message` が app/pages に **20 ファイル**残るうち
  計画が触るのは 3 (M=3 ≪ N=20)。系譜は #890 → #1005 → #1008 の 4 世代目
- [BLOCKER] 担保削除: `server/api/kyuyo/[...path].get.ts:66-69` の fail-closed 分岐を JSDoc の設計意図に
  反して削る、代替なし
- [BLOCKER] public repo: 確認手順の内部ホスト名
- [MAJOR] UI ページ 3 件を `coverage_100.toml` に新規登録 (方針違反) / [MAJOR] 同一変更を 3 PR で配布
- [MINOR] 計画のパス誤り (`net780.vue` は存在しない)

どちらも sonnet (`CLAUDE_CODE_SUBAGENT_MODEL`) で 3〜5 分・tool 17〜18 回・約 100k token。

## 6. 罠

- **agent 定義は置いた直後のセッションからは見えない** ([[parent-fanout]] §6)。`not found` が
  出ても定義は正しい。次のセッションか少し置いて再試行。**hook は定義ファイルの存在しか
  見ないので、この間は deny が出る** — 「reviewer が呼べないのに塞がれた」ときはこれ
- **`CLAUDE_CODE_SUBAGENT_MODEL` が設定されていると定義の `model: opus` は無視される**
  (このマシンは `sonnet` 固定)。5 つの検査は grep の数で判定するので sonnet でも回るが、
  「発生源はどこか」の読みは上位モデルの方が鋭い。設計判断が絡む計画は
  `Agent(..., model: "opus")` で上書きできる
- **reviewer の「未確認 (0 件)」を「無い」と読まない** ([[search-zero-hits-is-not-proof]])
- **reviewer に「ついでに計画を直して」と言わない。** read-only で定義してあるのは、
  検査と修正を同じ agent にやらせると自分の変更を自分で承認するため ([[parent-fanout]] §6 と同型)
- **削減 PR の起票前にも通す。** 実装後に「削れなかった」と分かるのが一番高い
  ([[reduction-pr-needs-measured-duplication]])

## 関連

- `.claude/agents/simplify-reviewer.md` — 定義 (正本)
- [[subagent-orchestration]] — 1 セッション内の開発ループ (planner → plan-reviewer ∥ simplify-reviewer → coder)
- [[parent-fanout]] / [[task-split]] — 親の分割・起票。起票前にここを通す
- [[code-search]] — 検査 3 が使う意味検索と重複台帳
