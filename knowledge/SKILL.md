---
name: knowledge
description: >
  CCoW セッションを跨いで参照できる「判断の記録」を grep 可能な形で蓄える
  knowledge ベース。decisions/ (経緯・却下案・調査結果。過去形) と standards/
  (推奨ライブラリ・reusable workflow 等の規範。現在形・結論のみ) の二層構成。
  外部 DB (Notion / D1+FTS5 / Vectorize / R2 SQL) は CCoW の標準検索 (ローカル
  grep) に乗らず素通りされるため棄却し、skill マウント経由で grep できる本
  リポジトリに置く (索引・API・認証 不要)。タスク着手前の経緯確認、新規依存・
  ツール選定時の規範参照、判断発生時の記録に使う。
  トリガー:「経緯」「前どうしたっけ」「前回どうした」「なぜこうなってる」
  「knowledge」「decision」「decisions」「standards」「規範」「却下案」
  「設計判断」「どのライブラリ」「lib 選定」「過去の調査」等。
---

# knowledge — 判断の記録 (decisions + standards)

設計判断・却下案・調査結果・規範を、CCoW の標準検索 (ローカル grep) に乗る形で
本リポジトリに蓄える。スキルマウント経由で全文 grep できるため、索引 / API /
認証は一切不要。**map (`<repo>-map`) は対象外** — map はコードの付属物として各
repo 側に同居移行する (Refs ippoan/claude-skills#59)。ここに残すのは判断の記録。

## 二層構成

| 層 | 何を置くか | 時制 | 置き場 |
|---|---|---|---|
| **decisions/** | 経緯の記録 (なぜそうしたか・何を却下したか・調査結果) | 過去形 | `decisions/YYYY-MM-DD-kebab-case.md` |
| **standards/** | 規範 (推奨 lib / reusable workflow / 運用ルールの**結論のみ**) | 現在形 | `standards/<category>/<name>.md` |
| **archive/** | `superseded` になった decision の移動先 | — | `archive/` |

「なぜ」は decisions に、「結論」は standards に置く。standards から関連 decision へ
`decision:` でリンクする。

## ワークフロー

### 1. タスク着手前 — 経緯を引く

```sh
grep -ri "<キーワード>" knowledge/decisions/ knowledge/standards/
```

ヒットしたエントリの `## Summary` (decisions) / frontmatter (standards) を読み、
必要なら本文へ。「前どうしたっけ」「なぜこうなってる」と思ったら**まず grep**。

### 2. 新規依存・ツール選定時 — 規範を先に引く

新しいライブラリ・reusable workflow・運用パターンを足す前に
`knowledge/standards/` を引く。既に `recommended` があればそれを使う。
`deprecated` を避ける。規範に無いものを採用するなら decision を 1 本書く
(なぜ既存規範で足りなかったか)。

> capability → canonical の対応表は
> [`standards/libs/org-capability-catalog.md`](standards/libs/org-capability-catalog.md)。
> 「util / helper を新規実装する前にここを引く」(lib-first) は旧
> `ippoan-lib-catalog` skill から移設したもの。

### 3. 判断・却下・調査結果の発生時 — 記録する

1. テンプレから新規エントリを作る:
   - decision: `cp knowledge/templates/decision.md knowledge/decisions/$(date +%F)-<kebab>.md`
   - standard: `cp knowledge/templates/standard.md knowledge/standards/<category>/<name>.md`
2. frontmatter と本文を埋める (規約は下記)。
3. 規約リンターを通す (PR2 で `scripts/check.py` を追加予定。それまでは
   下記規約を手動で満たす):
   ```sh
   python3 knowledge/scripts/check.py    # error 0 まで修正
   ```
4. repo-policy に従って commit / push (PR 経由・`Refs #N`・main 直 push 禁止)。

## 規約 (要点)

機械検証の定義は [`rules.json`](rules.json) が単一の真実 (check.py が読む)。
人間向けの要点:

### decisions

- ファイル名: `YYYY-MM-DD-kebab-case.md` (例: `2026-06-11-knowledge-storage-selection.md`)
- frontmatter 必須キー: `title` / `date` / `status` / `tags`
  - frontmatter は **flat な `key: value` のみ** (ネスト・複数行値は規約違反)
  - `status`: `active` | `superseded` | `rejected`
  - `superseded` のものは `superseded_by:` 必須 + **`archive/` に移動**する
- 先頭セクションは `## Summary` (3 行以内。grep 結果から本文を読むか判断する材料)

### standards

- 置き場: `standards/<category>/<name>.md` (例: `standards/libs/http-client.md`)
- frontmatter 必須キー: `title` / `category` / `status` / `recommended`
  - `status`: `recommended` | `allowed` | `deprecated`
  - `recommended` に結論 (推奨 lib 名等)、`alternatives` に代替、`decision` に
    関連 decision の slug

### 共通 (warn)

- 300 行超 → 分割提案 / 未来日付・非 ISO 日付 / tags 空・表記ゆれ

## 相互参照

- decision が issue を引く時は `branch-issue-linking` skill の規約に従い
  `Refs #N` で書く (auto-close させない。`Closes/Fixes/Resolves` は禁止)。
- capability → canonical の規範は `standards/libs/org-capability-catalog.md`
  (旧 `ippoan-lib-catalog`)。

## 注意

- **機密を書かない** (skill は public 相当 = grep 対象として全公開される前提)。
- push したエントリが grep に乗るのは**次回セッションから** (同一セッション内は
  会話コンテキストで補える)。
- map をここに足さない (map は各 repo の `.claude/skills/<repo>-map/` へ。Refs #59)。
