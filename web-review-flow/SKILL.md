---
name: web-review-flow
description: >
  draft PR レビューの統一フロー (SoT)。draft PR 作成 → cc-webreview-ext (手元 Chrome
  side panel + claude -p) で Web Review → `<!-- web-review -->` コメント投稿 → 購読中の
  CCoW が webhook 起床して「CCoW への引き継ぎ」チェックリストを処理 → user が ready 化
  → CI → auto-merge、の一本道と各役割の規約をまとめる。出す側 (draft 判断基準・draft の
  副作用 3 点・勝手に ready 化しない)、受ける側 (marker 検出・チェックリスト処理・frugal
  reply)、他レビュー経路 (pr-chat-bridge / review-with-fable / review-with-opus) との
  使い分けと、レビューが無駄な動きをする時の実測ベースのトラブルシュート (旧テンプレ
  同梱 agent / claude-in-chrome 未 provision / debug.sqlite の分解手順、cc-webreview-ext#33)
  を収録。トリガー:「レビューの流れ」「レビューフロー」「web review」「Web Review
  結果」「draft PR レビュー」「<!-- web-review -->」「CCoW への引き継ぎ」「レビューコメント
  を処理」「draft で出すべき?」「ready にしていい?」「レビュー統一」「web-review-flow」
  「レビューが無駄」「レビュー 高い/遅い」「debug.sqlite」「debug-dump」等。
  PR 作成時に「レビューを挟むか」を判断する場面、および web-review コメントの webhook で
  起床した時に必ず参照。
---

# web-review-flow — draft PR レビューの統一フロー

org の PR レビューは次の **一本道** に統一する。分岐 (ブラウザ検証・セルフレビュー) は
この幹に接ぎ木する形で使う (末尾の使い分け表)。

```
CCoW が draft PR 作成 ─▶ side panel (cc-webreview-ext) で Web Review (ブラウザ確認)
        │                        │ <!-- web-review --> コメント投稿
        │ subscribe_pr_activity  ▼
        └──────────▶ webhook で CCoW 起床 → 「CCoW への引き継ぎ」処理 → push
                                 │ (必要なら再レビュー: 再走は --edit-last 更新)
                                 ▼
                     user が ready for review 化 → CI → auto-merge
```

実装: [ippoan/cc-webreview-ext](https://github.com/ippoan/cc-webreview-ext)
(tracking issue #7、レビューフロー #5)。セットアップは同 repo README。

## 役割分担

| 役者 | やること | やらないこと |
|---|---|---|
| **author CCoW** | draft で PR 作成・`subscribe_pr_activity`・引き継ぎ処理・修正 push | ready 化・`enable_pr_auto_merge` |
| **reviewer** (手元 Chrome + cc-webreview-ext の claude -p) | **実ブラウザでの確認専任** (表示・動作・console + `pr-chat-bridge:request` の実施、`--chrome` 時)・`<!-- web-review -->` コメント投稿 | ソース (diff) レビュー・CI 調査 (2026-07-09 user 決定: CCoW の方が速い。allowlist から `gh pr diff` / `gh pr checks` を除外して構造的に不可、cc-webreview-ext#32)。対象 PR の merge / close / 修正 (read-only allowlist で担保) |
| **user** | レビュー結果の確認・**ready for review 化 (= merge 許可)** | — |

## 出す側 (author CCoW) の規約

### draft で出すか non-draft で出すか — **repo 種別で分ける**

判断は「変更の種類 (docs か code か)」ではなく **repo 単位** (2026-07-09 user 決定):

| repo 種別 | 既定 | 理由 |
|---|---|---|
| **コード / 実行物 repo** — アプリ・worker・バイナリ・deploy される成果物を持つ repo (cc-webreview-ext, nuxt-\*, rust-\*, auth-worker, ci-workflows 等) | **draft** で出し、Web Review → user が ready 化 | non-draft は CI green の瞬間に auto-merge され、レビューの余地が消える (cc-webreview-ext#27 の実例) |
| **ドキュメント配布 repo** — `ippoan/claude-skills` / `ippoan/claude-md` (skill 本文・CLAUDE.md テンプレ・knowledge) | **non-draft 直行** (CI green → auto-merge) | テキストのみで実行物に影響せず、修正 PR での巻き戻しが容易。draft を挟む価値が薄い |

- user の明示指示は、どちらの既定よりも常に優先する。
- ドキュメント配布 repo を増やしたら上の表を更新する (表に無い repo は draft 側に倒す)。
- draft → ready は 1 クリック、merge の取り消しはできない。迷ったら draft。

### draft の副作用 (must know、3 点)

1. **staging に deploy されない** — frontend-ci の deploy-staging / publish-dev は
   `draft == false` gate。preview 導入 repo (create-preview) だけは push で preview が出る
   (詳細は pr-chat-bridge skill の分岐表)。
2. **PR CI から prerelease を出す repo は draft gate の有無を確認** — repo により方針が
   分かれる。cc-webreview-ext の dev-release (MSI) は **draft でも出す** (draft レビュー中の
   実機確認にこそ dev build が要るため gate を撤去、cc-webreview-ext#27)。他 repo で
   `draft == false` gate が残っている場合、実機確認は ready 化後になる。
3. **auto-merge が効かない** — draft は auto-merge 対象外。さらに **non-draft → draft
   変換は auto-merge の enable を解除し、ready 化しても自動では復活しない** (GitHub 仕様、
   cc-webreview-ext#27 で実測)。org 標準 CI (ci-workflows) は `ready_for_review` trigger で
   再走し auto-merge job が enable し直すので、放置でよい。変換直後の走行中 run の
   Auto Merge job が赤くなるのは cosmetic (GitHub が draft の merge を拒否するため)。

### 作成後

- 同じ turn で `subscribe_pr_activity` (org 共通規約)。
- **勝手に ready 化しない**。ready 化 = merge 許可であり user の判断。レビュー対応が
  済んだら「ready 化はお任せします」と報告して turn を終える。

## 受ける側 (購読中の CCoW) の処理規約

webhook でコメントイベントを受けたら:

1. コメント 1 行目に `<!-- web-review -->` marker があるか確認する。無ければ通常の
   PR コメントとして扱う (この skill の対象外)。
2. `## Web Review 結果` の指摘と `## CCoW への引き継ぎ` の `- [ ]` チェックリストを読む。
   - 解釈が割れる指摘・アーキテクチャに響く指摘は **AskUserQuestion で確認**してから動く。
   - 明確で小さい指摘はそのまま対応する。
3. 対応を **同じ branch に push** する。対応内容の記録は PR の diff — 往復のたびに
   返信コメントを書かない (frugal reply)。返信するのは「全項目対応が完了した」報告か、
   指摘に反論・質問がある時だけ。書く場合も 1 コメントに集約し `Refs #N` 規約を守る。
4. 再レビューが要るなら user に ready 化ではなく **side panel からの再走**を案内する
   (再走は `<!-- web-review -->` 冪等マーカーにより既存コメントの `--edit-last` 更新に
   なり、重複投稿されない)。
5. ready 化・`enable_pr_auto_merge` はしない。merge / close まで購読を維持し、
   `send_later` の self check-in (約 1 時間) を再アームする。

## コメント契約 (フロー全体の interface)

書式の **SoT は cc-webreview-ext の
[`host/prompts/review.md`](https://github.com/ippoan/cc-webreview-ext/blob/main/host/prompts/review.md)**
(agent バイナリに同梱され self-update で配布される)。ここでは互換性に関わる要点だけ:

- 1 行目に `<!-- web-review -->` (冪等マーカー)
- `## Web Review 結果` (指摘リスト、重大度順) + `## CCoW への引き継ぎ` (`- [ ]` 形式)
- issue 参照は `Refs #N` のみ (auto-close キーワード禁止)
- レビューセッションの応答最終行はコメント URL の単独行 (side panel が完了カードに抽出)

**変更する時はテンプレ本体・受ける側の処理 (本 skill)・side panel の抽出処理を同時に
見直すこと** — 片側だけ変えるとフローが無言で壊れる。

## 他レビュー経路との使い分け

| 経路 | 何をする | いつ使う |
|---|---|---|
| **web-review** (この skill) | draft PR の**実ブラウザ確認** (表示・動作・console + bridge 依頼の実施) → PR コメント。ソースレビューはしない | merge 前にブラウザで見ておきたい PR (幹) |
| **pr-chat-bridge** skill | chat 側 (Cowork/Desktop + Claude in Chrome) に実ブラウザ検証を依頼 | user がリンクを運ぶ手動経路。cc-webreview の `--chrome` レビューが動く環境では web-review が同じ依頼コメントを自動処理する |
| **review-with-fable / review-with-opus** | push 前のセルフレビュー (CCoW 内で完結、コメントなし) | **ソースレビューの主経路** (push 前の品質ゲート)。web-review はソースを見ないため、コードの正しさ/設計はここで担保する |

推奨順序: セルフレビュー (push 前、ソース担保) → draft PR + web-review (ブラウザ確認) →
user が ready 化。

### PR コメント marker 一覧 (org 内の機械可読 marker)

| marker | 意味 / 処理者 |
|---|---|
| `<!-- web-review -->` | Web Review 結果。購読中の CCoW が引き継ぎを処理 (本 skill) |
| `<!-- pr-chat-bridge:request -->` | ブラウザ検証依頼。処理者は 2 系統: chat 側 Claude (pr-chat-bridge skill、user がリンクを運ぶ) / **cc-webreview reviewer** (`--chrome` レビュー時に自動検出・実施。依頼コメント作者が PR 作者・OWNER/MEMBER/COLLABORATOR の場合のみ、データ変更操作は SKIP。cc-webreview-ext#32) |
| `<!-- pr-chat-bridge:result -->` | 上記依頼への回答。依頼側セッションが読んでチェックボックスを更新する |

新しい marker を導入する時はこの表に追記する (衝突・二重処理防止)。

## トラブルシュート: レビューが無駄な動きをする / 高い / 遅い

2026-07-09 の実測 (debug.sqlite 全 run 分解、ippoan/cc-webreview-ext#33) で確定した
チェック順:

1. **配布 agent のテンプレが旧版でないか** — review.md はバイナリ同梱 (include_str!) の
   ため、repo を直しても **agent self-update が済むまで旧テンプレ + 旧 allowlist で走る**。
   旧版 (diff/checks 許可) だと checkout の無い環境で `gh api contents` / graphql / clone を
   使ったソース考古学に迷い込む (実測: 28 call 中 ~15 が空振り・重複、$1.05/29 turns)。
2. **`-p` に claude-in-chrome が provision されているか** — stream-json の `system/init` の
   `mcp_servers` を見る。browser 不在だと model は「できること」= ソース掘りに流れる
   (新テンプレでは「未実施」と書いて終わる設計)。provision 問題は cc-webreview-ext#31。
3. context の荷物 (無関係 plugin MCP / skills 30+ 個で prefill ~40K tokens/run) は実在する
   が第 3 因子 — cache が効き起動→init は 1.2〜1.6s。rate limit 待ち / CLI コールド
   スタート犯人説は実測で棄却済み。

計測のやり方: `%LOCALAPPDATA%\cc-webreview\debug.sqlite` を取得し、`kind='claude'` の
payload (`{data: <stream-json>}` ラッパー付き) を `system/init` 単位で run 分割 →
各 run の init.mcp_servers / assistant usage (prefill) / tool_use 時系列 / result
(num_turns, duration_api_ms, total_cost_usd) を見る。`cc-webreview-agent --debug-dump N`
でも直近 N event を取れる。
