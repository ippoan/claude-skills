---
name: cross-repo-symbol-index
description: CCoW で 30+ repo を跨ぐ構造把握 (どの repo の何処に symbol があるか) のやり方と、その設計検討の結論。結論はシンプル: symbol が要る時はその場でローカル ctags (全 31 repo で 3.8 秒)、保存はしない。唯一永続的に要るのは「手書き skill (ippoan-infra-map 等) が code と乖離してないか」の鮮度チェックで、これは SessionStart hook が generated-from の tree-sha 比較で行う。トリガー: 「横断 symbol 検索」「repo 跨ぎの構造」「symbol index」「どこに関数がある」「skill 鮮度」「ctags でローカル抽出」「cross-repo index」「構造把握が毎回遅い」等。
---

# cross-repo-symbol-index — 横断構造把握 (結論: ローカル ctags + skill 鮮度 hook)

CCoW では 30+ repo が `/home/user/<repo>` に clone される。「どの repo の何処に何が
あるか」を毎 session 人力で grep し直すのが当初の課題だった。**長い検討の結論は
「index を作って保存する必要は無い」**。

## 結論 (これだけ)

```
symbol が要る時:  その場でローカル ctags。全 31 repo で 3.8 秒、auth-worker 単体 0.3 秒。
                  保存しない。MCP も D1 も CI も要らない。
                  (universal-ctags は .git/依存を default 除外。--output-format=json で
                   name/kind/開始終了行が出る。smart-read skill も同系統。)

唯一 永続的に要るもの:  手書き skill (ippoan-infra-map 等) が code と乖離してないか
   → SessionStart hook が skill の `generated-from` (記録した tree-sha) vs
     現在の repo の tree-sha を比較し、ズレた skill を warning。
   → Claude は警告を見てローカル ctags 等で skill を作り直す。
```

### 実測 (この結論の根拠)

| | 時間 |
|---|---|
| ローカル ctags 全 31 repo | **3.8 秒** / 199,845 symbols |
| auth-worker 単体 (271 files) | 0.32 秒 |
| 同 build-payload 整形 | 0.14 秒 |

抽出が 0.3 秒なら「index を D1/R2 に保存して serve」する旨みは無い。必要な時に
ローカルで舐めれば済む。

## なぜ「index を保存・serve」しないか (撤去した過剰設計の記録)

当初は per-repo CI で ctags → D1 に投入 → MCP `search_symbols` で query、という形を
作ったが**全部撤去した**。理由:

1. **per-repo CI 生成は旧式 (LSIF 方式)**。Zoekt/Sourcegraph 等の横断 code index は
   「専用 indexserver による中央 pull 型」で per-repo CI を**回避する**のが定石。実測でも
   per-repo CI は **5 分/repo** (apt install ctags + runner + checkout が overhead の 99%、
   ctags 本体は 0.3 秒) と最悪だった。
2. **symbol 検索はローカルで完結する** (repo が clone 済み)。MCP `search_symbols` も外した
   — clone 済み repo を MCP 往復で引く意味が無い。
3. **保存先を D1/R2 にしても**、bulk を HTTP で送るなら secret が要り (CF Access 配線も要る)、
   MCP で送るなら 20 万行が context を食う。**そもそも保存不要**なので全部消える。
4. CCoW では D1 への小さな write は **D1 MCP (`d1_database_query`) が認証済み**で secret 不要。
   が、保存物が無いので使わない。

撤去したもの: ci-dashboard の D1 binding / ingest endpoint / `search_symbols` MCP /
freshness・head endpoint、`SYMBOL_INDEX_INGEST_SECRET`、ci-workflows の generator
workflow、auth-worker の per-repo CI job、D1 database 本体。

## skill 鮮度チェックの規約 (generated-from)

code から起こした手書き skill (構造 map 等) は frontmatter に **`generated-from`** を
持つ。形式は `repo:tree-sha` を space 区切りで 1 行:

```yaml
---
name: ippoan-infra-map
generated-from: claude-md:<tree-sha> claude-hooks:<tree-sha> mcp-relay-rs:<tree-sha> ...
---
```

`tree-sha` は生成時の `git -C /home/user/<repo> rev-parse HEAD^{tree}`。

SessionStart hook (claude-hooks `session-start-stale-skills-check.sh` 内) が
`~/.claude/skills/*/SKILL.md` を走査し、`generated-from` の各 repo について現在の
tree-sha と比較。ズレてたら「この skill は <repo> の変化に追従していない」と
additionalContext で警告する。`generated-from` を持たない skill は対象外 (opt-in)。

> 鮮度判定に ctags は不要 — tree-sha の比較だけ。symbol が実際に要る時に初めて
> ローカル ctags する。

## 関連 skill

- `smart-read` — file 全体でなく symbol 単位でローカル抽出 (これの org 横断版が
  「その場 ctags」)
- `ippoan-infra-map` — 手書きの基盤 5 repo マップ。`generated-from` を持たせる第一候補
- `secret-inject` — (この検討の副産物) no-leak secret 投入 skill。単体で有用なので残置
