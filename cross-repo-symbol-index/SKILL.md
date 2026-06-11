---
name: cross-repo-symbol-index
description: CCoW で 30+ repo を跨ぐ構造把握 (どの repo の何処に symbol があるか) のやり方と、その設計検討の結論。結論はシンプル:symbol が要る時はその場でローカル ctags (全 31 repo で 3.8 秒)、保存はしない。唯一永続的に要るのは「手書き skill (ippoan-infra-map 等) が code と乖離してないか」の鮮度チェックで、これは SessionStart hook が generated-from の tree-sha 比較で行う。トリガー:「横断 symbol 検索」「repo 跨ぎの構造」「symbol index」「どこに関数がある」「skill 鮮度」「ctags でローカル抽出」「cross-repo index」「構造把握が毎回遅い」等。
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
持つ。

### 新形式: commit-sha + paths (Refs claude-hooks#18 PR1)

単一 repo を指す `<repo>-map` は `generated-from: <repo>:<commit-sha>` と、map が
参照するコードのスコープ `paths:` を持つ:

```yaml
---
name: <repo>-map
generated-from: <repo>:<commit-sha>
paths: [src/, proto/]
---
```

- **commit-sha** (`git -C /home/user/<repo> rev-parse HEAD`): CI が
  `git rev-list --count <commit>..HEAD -- <paths>` で**乖離距離**を測れる。
  旧 **tree-sha** は完全一致判定のため 1 コミットで常時 stale 化し (オオカミ少年)、
  これが鮮度警告が機能しなかった根本原因の 1 つ (claude-hooks#18)。
- **paths**: この paths 下に変更があった時だけ stale 扱い。無関係な変更
  (`README.md` 等) で stale にならない。

### 鮮度判定は CI へ移譲 (hook は縮小)

stale 判定は SessionStart hook から **skills-check CI (PR diff 判定、ci-workflows#118)**
へ移譲された。CI が「`paths` に変更があるのに map が同 PR で更新されていない」場合に
warn する。map は各 repo の `.claude/skills/<repo>-map/` へ同居移行し
(Refs claude-skills#59)、コードと同じ PR で更新される (クロスリポ書き込み・push 忘れ
消失問題が消える)。

SessionStart hook (claude-hooks **`session-start-skill-coverage.sh`**) は **「map の無い
attached repo の通知」(uncovered) だけに縮小** される (claude-hooks#18 PR2)。
`generated-from` を持たない skill は対象外 (opt-in)。

### 旧形式 (tree-sha) の移行

複数 repo を space 区切りで列挙する横断 map (例 `ippoan-infra-map`) と、未移行の
`<repo>-map` は当面 `<repo>:<tree-sha>` のまま残る。移行期間中は **旧形式を warn のみ
で判定スキップ** (claude-hooks#18 Q1)。`repo-map` で再生成する時に新形式へ寄せる。

```yaml
# 横断 map (移行対象外・当面 tree-sha 維持)
generated-from: claude-md:<tree-sha> claude-hooks:<tree-sha> mcp-relay-rs:<tree-sha> ...
```

> 別名注意: `session-start-stale-skills-check.sh` は**別 hook** (sources clone が
> remote から古くないかを見る bootstrap 鮮度チェック)。code↔map の鮮度はこの
> `skill-coverage.sh` の方。

> 鮮度判定に ctags は不要 — commit-sha + paths の比較だけ。symbol が実際に要る時に
> 初めてローカル ctags する。

### どのロジックがどこに居るか (動作=claude-hooks / 配線=claude-md)

`ippoan-infra-map` の「動作は claude-hooks、配線は claude-md」ルールに従う:

| 何 | 置き場 |
|---|---|
| **stale 判定** (paths diff、新方式) | **ci-workflows** `skills-check.yml` (PR diff、#118) |
| coverage (map 無し repo 通知) の**判定ロジック** | **claude-hooks** `session-start-skill-coverage.sh` (#18 で縮小) |
| hook の **SessionStart 登録 + env** | **claude-md** `.claude/settings.json.template` |
| `<repo>-map` / `ippoan-infra-map` (map 実体) | **claude-skills** |

### 運用上の除外と空 repo の扱い

- **claude-skills 自身は coverage 対象から除外** (`CLAUDE_SKILL_COVERAGE_IGNORE=claude-skills`、
  claude-md の settings env)。理由: claude-skills は map の置き場そのもので、追従すべき
  外部 code を持たない。自分自身を map した `claude-skills-map` は repo が変わる度に
  無意味に stale 化する (自分のコミット後 tree-sha を自分に書けない鶏卵) → ノイズなので
  既定で外す。**「code→map の鮮度」は外部 code repo にだけ意味がある**、が原則。
- **空 repo (commit ゼロ・HEAD 無し)** は `<repo>-map` の `generated-from` に git の
  **empty-tree-sha** (`4b825dc6…`) を入れた placeholder を置く (例: `ippoan-drift-map`)。
  hook 側は `git rev-parse --verify -q 'HEAD^{tree}'` で HEAD 無しを `cur=""` 扱いにし
  鮮度比較をスキップ → covered かつ鮮度 OK。最初の commit が入ると cur が実 tree-sha に
  なり empty-tree-sha と不一致 → stale → `repo-map` で実体化を促す。
  (素朴な `rev-parse 'HEAD^{tree}'` は失敗時に literal を stdout に出し stale 誤検出するので不可。)

## 関連 skill

- `smart-read` — file 全体でなく symbol 単位でローカル抽出 (これの org 横断版が
  「その場 ctags」)
- `ippoan-infra-map` — 手書きの基盤 5 repo マップ。`generated-from` を持たせる第一候補
- `secret-inject` — (この検討の副産物) no-leak secret 投入 skill。単体で有用なので残置
