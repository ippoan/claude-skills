---
name: cross-repo-symbol-index
description: CCoW で 30+ repo を跨ぐ構造把握 (どの repo の何処に symbol があるか) を人力で毎 session 辿り直すコストを消すための index システムの設計。CI で LSP 抽出した symbol(開始/終了行付き) を D1 に貯め、ci-dashboard の search_symbols が D1 を読んで返す。ippoan-infra-map (手書き 5 repo) の自動化版。トリガー: 「横断 symbol 検索」「search_symbols の中身」「repo 跨ぎの構造」「symbol index」「LSP を CI で」「D1 に symbol」「どこに関数がある」「cross-repo index」「構造把握が毎回遅い」等。
---

# cross-repo-symbol-index — 横断 symbol index の設計

CCoW では 30+ repo が `/home/user/<repo>` に clone されるが、各 repo の CLAUDE.md
は遅延ロードで、起動時の「どの repo の何処に何があるか」は依然ゼロ知識。結果、
毎 session/毎タスクで grep + source 読みで構造を再構成しており、context とターンを
浪費している。これを **CI で機械抽出した symbol index を D1 に貯め、MCP で返す** 形で
自動化する。

`ippoan-infra-map` skill (手書きで 5 repo を維持) の弱点 — 人力ゆえ腐る — を生成物で
置き換えるのが本旨。

## 結論 (1 枚)

```
生成 (CI / 各 repo, ci-workflows の reusable workflow)
  test の後 (依存が cargo build / npm ci で温まった状態) → LSP で抽出:
     symbols(name, kind, file_path, start_line, end_line, signature)
     deps(manifest 由来)  /  links(import 静的解析; 後で LSP 参照に格上げ)
     src_hash (git rev-parse HEAD:src 等)
  → D1 に push (machine write・PR 無し)

保管 (D1 = 共有冷蔵庫, ci-dashboard が所有)
  repos / symbols / deps / links     content-hash キー・src_hash で鮮度

query (ci-dashboard MCP server)
  既存 search_symbols の backend を D1 に差し替え
  返り値に repo/file:start_line-end_line を含める

消費 (CCoW / install.sh 改修不要)
  Claude が既存 MCP search_symbols を呼ぶ → ci-dashboard が D1 をサーバ側で読む
  → repo/file:42-67 を返す → ローカル clone のその行だけ Read
  (D1/MCP が WHERE を返し、ローカル clone で READ する分業)
```

## なぜこの形か (設計判断の経緯)

設計に至るまでに潰した選択肢と理由。再検討時にループしないための記録。

### 1. per-folder CLAUDE.md は repo 内層だけ。横断は埋まらない

階層 CLAUDE.md (公式 best practice) は「その repo に入った後」を速くするが、CCoW でも
`/home/user` に CLAUDE.md は無く各 repo の CLAUDE.md は遅延ロードなので、起動時の
「30 のうちどれを開くか + 各 repo の全体像」は埋まらない。LSP も workspace=repo 単位で
同じ。→ 横断層は別途 index が要る。

### 2. 保管は skills(markdown) でなく D1

| | markdown skills | MCP + D1 |
|---|---|---|
| クエリ | 全文ロード/grep | 構造クエリ (symbol を 1 行で返す・token 10x減) |
| 横断リンク | 人/生成で維持 | SQL で関係を持てる |
| 鮮度 (remote/pull) | ローカル git では remote 最新を知れない | generator が main で走り D1 に刻む・サーバ側で stale 判定 |

lean な TOC (どの repo が何か) だけ markdown/user-memory に常駐、詳細 (symbol/link) は D1。

### 3. 生成エンジンと場所: LSP を CI で

- **LSP vs tree-sitter**: 開始/終了+symbol だけなら tree-sitter で足りる。LSP の上乗せ
  価値は意味的な参照 (どこから呼ばれてる)。それを取るなら LSP。
- **install.sh で生成しない**: LSP は対象 repo の依存が解決済み (`cargo fetch`/`npm install`)
  でないと正確に動かない。`git clone` はソースだけでライブラリを持ってこない。ephemeral な
  CCoW コンテナの install.sh でやると **毎 session 30 repo 分の依存解決を cold で繰り返す**。
- **CI で生成する**: 各 repo の CI は test のために既に依存をビルド済み。その温まった状態を
  再利用すれば LSP 抽出はほぼタダ。install.sh は **生成せず D1 から取得するだけ** (実際は
  ci-dashboard MCP がサーバ側で D1 を読むので、install.sh 改修すら不要)。

### 4. query は新 server でなく ci-dashboard の既存 tool 格上げ

ci-dashboard は既に org 横断 query の MCP server (`search_symbols` / `search_code` /
`get_file_tree` / `list_org_issues`)。`search_symbols` は description で "LSP-like definition
finder" を名乗るが、実装は GitHub `/search/code` のテキスト検索 (`"fn 関数名"` heuristic) で
行範囲なし・誤爆あり。→ **新 server も新 tool も作らず、この既存 tool の backend を D1 に
差し替える**だけ。

### 5. 人の merge を data path から排除

map を commit して PR で同期、は静的 markdown 時代の名残。生成物は「作り直すもの」で
レビュー対象ではない。data は全部 CI→D1 の machine write で、PR/merge を一切経由しない。
人が触る PR は generator / hook の **コードそのもの** (普通の開発) だけ。

## 担当 repo (どこに何を足すか)

| 部品 | repo | 内容 |
|---|---|---|
| 設計 doc (これ) | **claude-skills** | 結論と経緯 |
| generator | **ci-workflows** | reusable workflow `symbol-index.yml`。test 後に LSP 抽出 → D1 push |
| D1 + query | **ci-dashboard** | wrangler に D1 binding / schema / `search_symbols` の D1 化 |
| 消費 | (変更なし) | 既存 MCP `search_symbols` を呼ぶだけ |

関連 issue: claude-skills#10 / ci-dashboard#205 / ci-workflows#90

## D1 schema (契約)

全部品が依存する中心の契約。

```sql
CREATE TABLE repos (
  repo        TEXT PRIMARY KEY,      -- 'rust-alc-api'
  summary     TEXT,                  -- 1 行説明
  lang        TEXT,                  -- 主要言語
  head_sha    TEXT,
  src_hash    TEXT,                  -- 鮮度キー (git rev-parse HEAD:src 等)
  updated_at  INTEGER
);

CREATE TABLE symbols (
  repo        TEXT NOT NULL,
  name        TEXT NOT NULL,
  kind        TEXT NOT NULL,         -- function/class/struct/interface/type/enum/trait/mod
  file_path   TEXT NOT NULL,
  start_line  INTEGER NOT NULL,      -- LSP range.start.line
  end_line    INTEGER NOT NULL,      -- LSP range.end.line
  signature   TEXT,
  file_hash   TEXT                   -- incremental 用 (変更 file だけ再抽出)
);
CREATE INDEX idx_symbols_lookup ON symbols(repo, name, kind);

CREATE TABLE deps (
  repo TEXT NOT NULL, name TEXT NOT NULL, version TEXT, kind TEXT
);

CREATE TABLE links (
  from_repo TEXT NOT NULL, from_symbol TEXT,
  to_repo TEXT, to_symbol TEXT, kind TEXT   -- import / call / cross-service
);
```

## 鮮度

- generator が push 時に `src_hash` を更新。query tool は repo の現 `src_hash` と
  比較して `stale: N` を返せる。
- ローカル基準 (手元 clone) と main 基準 (CI) を分離: 「pull してない」状況でも
  ローカルは手元と一致、main の鮮度は CI が更新するので破綻しない。
- → push 前 hook / CI gate / 追加 PR reconcile といった drift 機構は **detail 層には不要**。

## フォールバック

- 普段は D1 から取得 (ci-dashboard MCP 経由)。
- 今いじってる repo だけ最新が確実に要る → その repo だけ `npm install` + 再抽出、
  または D1 の最新を取得。30 repo 全部を手元で再生成することは無い。
- D1 が未投入/空の repo は ci-dashboard 側で既存 GitHub code-search に graceful fallback。

## 関連 skill

- `ippoan-infra-map` — 手書きの 5 repo 横断マップ。本 index の前身 (これを生成物化する)
- `large-codebase-setup` — 階層 CLAUDE.md / Stop hook / LSP の 3 本柱 (repo 内層)
- `smart-read` — file 全体でなく symbol 単位で抽出して context 節約 (ローカルで READ する側)
