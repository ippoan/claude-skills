---
name: code-search
description: ippoan/code-search-index (公開 repo 横断の意味検索 + 重複検知) の利用と運用の知識。semantic_code_search MCP tool の使い方・クエリのコツ、⚠ near-duplicate 警告 4 層の意味と対応 flow、full-rebuild / cache / checkpoint の運用、踏み抜き済みの罠を 1 枚にまとめる。トリガー:「code-search」「semantic_code_search」「意味検索」「セマンティック検索」「既存実装を探す」「似たコード」「重複コード」「near-duplicate」「dup-pairs」「code-search-index」「索引の再構築」「full-rebuild」等。実装前の既存実装調査、⚠ [code-search] 警告への対応、索引の保守を行うタスクは着手前に読む。
---

# code-search — 意味検索と重複検知の利用・運用

実体は **ippoan/code-search-index**。ippoan / ohishi-exp の public 全 repo を
関数単位でチャンク化し、jina-embeddings-v2-base-code + sqlite-vec で索引化。
Release asset `code-index.db.gz`(索引)と `dup-pairs.json`(重複台帳)が成果物。

## 検索の使い方 (semantic_code_search MCP tool)

- 自然言語で挙動を書く。**技術語を 1 語混ぜると精度が跳ねる**
  (「JWT を検証してテナント解決」「W5500 の Ethernet 初期化」は◎)。
  純ドメイン語だけ (「運行NO の桁解析」等) は弱い — その時は grep 系と併用。
- `repo` 引数は **`org/name` 形式** (`ippoan/auth-worker`)。距離 (dist) は
  小さいほど近い。0.75 以下なら強い一致、0.95 超は当てにならない。
- tool 名の実体は `mcp__code-search__semantic_code_search`。ToolSearch は
  名前空間付きで select する (素の名前で「無い」と誤判定しない)。

## ⚠ 重複警告の 4 層と対応 flow

| いつ | 仕組み |
|---|---|
| 検索時 | 結果に `⚠ near-duplicate: <相方> (sim)` が付く |
| Read/Edit/Write 時 | PostToolUse hook (`scripts/claude-dup-warn.sh`) が台帳照合 |
| push 時 | global pre-push hook (`scripts/pre-push-similar.sh`) が追加差分を索引照合 |
| merge 後 | index CI が台帳を更新し、**新規ペアのみ** issue を自動起票 |

警告を見たら: ①相方ファイルにも同じ変更が必要か確認 ②可能なら共通化を提案
(lib-first ★strict、rule of two) ③すぐ動けないなら重複解消の issue を立てる。
警告は全て advisory — push や CI をブロックしない。

## 運用 (保守するときだけ読む)

- 更新 3 経路: 日次 cron / merge 連動 (ci-dashboard が public repo の
  default-branch push で dispatch、index repo 自身は除外) / `full-rebuild`
  workflow (shard 並列 + chunk・vector cache。**全量やり直しは必ずこれ**)。
- cache が温かい full-rebuild は 10 分級。モデル・`embed_text`・チャンク形状を
  変えたら cache key の `caches-v1` prefix を bump して full rebuild。
- MCP server は各マシンの clone (`~/code-search-index` + venv) を
  `claude mcp add -s user code-search -- <venv>/python <repo>/mcp/server.py`
  で常設。DB は Release から自動同期 (`CODE_INDEX_REFRESH_SECONDS`、既定 6h)。
- repo の詳細ルールは code-search-index の `CLAUDE.md` が正。

## 踏み抜き済みの罠

- **直列 run での全量埋め込みは runner VM が死ぬ** (メモリ圧で 2 回全損)。
  shard 並列 + 途中 checkpoint が正。
- 素の `pip install mcp` は 2.x で `FastMCP` が無い (MCPServer に改名)。
  server.py の両対応 import を壊さない。
- sqlite 接続はスレッド跨ぎで恒久故障する — `check_same_thread=False` を維持
  (プロセスは生きたままなので ps では見えない)。
- global git hook の wrapper で `git rev-parse --git-path hooks/X` を使うと
  hooksPath を尊重して**自分自身を呼び fork 爆弾**になる。`--git-dir` で引く。
- 埋め込み入力は 2000 字 cap (attention は系列長の 2 乗)。索引とクエリは
  必ず同一モデル (`indexer/db.py` の `MODEL_NAME` が正)。
