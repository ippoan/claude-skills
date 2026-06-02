---
name: large-codebase-setup
description: 大規模コードベース (数十万行以上、multi-language) で Claude Code を最大効率で動かすための初期セットアップ skill。Anthropic 公式 blog "How Claude Code works in large codebases" (2026) ベース。階層 CLAUDE.md / Stop hook による自己反省 / LSP 統合の 3 本柱で navigation 精度と context 効率を底上げする。トリガー:「大規模 codebase」「monorepo セットアップ」「CLAUDE.md 階層化」「stop hook 設定」「LSP 統合」「symbol navigation」「navigation 精度」「large codebase best practices」「multi-language repo セットアップ」「Claude Code 効率化」等。
---

# large-codebase-setup — 大規模コードベース向け Claude Code 初期セットアップ

Anthropic 公式 blog [How Claude Code works in large codebases](https://claude.com/blog/how-claude-code-works-in-large-codebases-best-practices-and-where-to-start) (2026) で示された 3 本柱を repo に適用するための skill。

## 適用条件

以下のいずれかに該当する repo:

- 数十万行〜数百万行クラスの monorepo / multi-package repo
- 複数言語混在 (Rust + TypeScript + Python など、symbol 衝突が起きやすい)
- サブシステムごとに lint / test / build コマンドが異なる
- 初参加の Claude session が grep / find で迷子になる頻度が高い
- 同名関数 / クラスが言語境界をまたいで重複しており pattern-match が信用できない

該当しない小規模 repo (~10k 行、単一言語) には適用しない。CLAUDE.md 1 枚で足りる。

## 3 本柱

| 柱 | 目的 | 効果 |
|---|---|---|
| **階層 CLAUDE.md** | context の局所化 | root を lean に、subdir に local convention |
| **Stop hook (reflection)** | session の知見を CLAUDE.md に還流 | 学びの揮発を防ぐ、deterministic |
| **LSP 統合** | symbol-level navigation | "go to definition" / "find references" で正しい symbol に着地 |

---

## Pillar 1: 階層 CLAUDE.md

### 原則

- **Root CLAUDE.md** は **pointers と critical gotchas のみ**。「everything else drifts into noise」
- **Subdirectory CLAUDE.md** に local convention / scoped command を置く
- ファイルは Claude が navigate するたびに **additively** ロードされる
- skill に属する「再利用可能な expertise」は CLAUDE.md ではなく **skill** にする
- repo root ではなく **subdirectory で初期化** する（root は最小限に）

### 推奨レイアウト

```
repo/
├── CLAUDE.md                    # 100 行未満。pointer + 致命的 gotcha だけ
├── .claude/
│   └── settings.json            # version-controlled exclusion / permission
├── docs/
│   └── codebase-map.md          # 非標準構造の folder 説明 map
├── packages/
│   ├── api/
│   │   └── CLAUDE.md            # api 固有の test / lint / build コマンド
│   ├── web/
│   │   └── CLAUDE.md            # web 固有の dev server / e2e 手順
│   └── shared/
│       └── CLAUDE.md            # 共有ライブラリの不変条件
└── infra/
    └── CLAUDE.md                # terraform / k8s の操作 gotcha
```

### Root CLAUDE.md テンプレ (大規模 monorepo 用)

```markdown
# <project> codebase pointers

Multi-package monorepo. Each package owns its own CLAUDE.md with scoped
commands. Do NOT run repo-wide test/lint — they are too slow and noisy.

## Layout

- `packages/api/` — Rust + Axum HTTP API. See `packages/api/CLAUDE.md`.
- `packages/web/` — Nuxt 4 frontend. See `packages/web/CLAUDE.md`.
- `packages/shared/` — TypeScript types generated from Rust via ts-rs.
- `infra/` — Terraform + Cloudflare. See `infra/CLAUDE.md`.

For folder layout outside the above, see `docs/codebase-map.md`.

## Critical gotchas (read before editing anything)

- `packages/shared/types.ts` is **generated** — edit the Rust source in
  `packages/api/src/types.rs` instead. Run `cargo test --features ts-rs`
  to regenerate.
- DB migrations under `packages/api/migrations/` must be tested via the
  `migrate-test` skill before commit (RLS lint runs there).
- Never `git push --force` on `main` — production deploy is wired to
  `main` HEAD.

## Skills used in this repo

- `pr-push`, `wt-quick`, `migrate-test`, `coverage-check`
```

### Subdirectory CLAUDE.md テンプレ

```markdown
# packages/api — Rust + Axum

## Scoped commands

```bash
cargo test -p api               # this package only
cargo clippy -p api -- -D warnings
cargo run -p api                # listens on :3000
```

## Local conventions

- Handler functions live in `src/handlers/`. One file per resource.
- DB access goes through `src/repo/` — never call `sqlx::query!` from
  handlers directly.
- New endpoint? Add OpenAPI annotation, then regenerate `shared/`.

## Gotchas

- `sqlx::query_as!` requires `DATABASE_URL` at compile time. If `cargo
  check` fails with "set DATABASE_URL", start the local PG via
  `docker compose up db` first.
```

### Codebase map (非標準構造用)

非標準 / 歴史的命名の folder が多い repo には `docs/codebase-map.md` を置き、root CLAUDE.md からリンクする:

```markdown
# Codebase map

| Folder | 何が入っているか | 主担当 skill / コマンド |
|---|---|---|
| `legacy/v1/` | 旧 API。read-only。新規追加は `packages/api/` へ | - |
| `tools/jp-pdf/` | 内部 PDF 生成 CLI。Go 製 | `make -C tools/jp-pdf test` |
| `experiments/` | 実験 branch の残骸。動かない | 触らない |
```

### `.claude/settings.json` で除外

```jsonc
{
  "permissions": {
    "deny": [
      "Read(./node_modules/**)",
      "Read(./target/**)",
      "Read(./.next/**)",
      "Read(./dist/**)",
      "Read(./**/*.lock)"
    ]
  }
}
```

### CLAUDE.md に書かないもの

| ❌ 書くな | ✅ 正しい置き場所 |
|---|---|
| 再利用可能な手順 (deploy / release) | **skill** (`.claude/skills/<name>/SKILL.md`) |
| handover メモ / WIP 状態 | `~/.claude/projects/<proj>/memory/handover_*.md` |
| 完了済み progress / design doc | `docs/` または `.claude/plans/` |
| 全 repo 共通ルール | global `~/.claude/CLAUDE.md` |
| 50 行を超える how-to | skill 化 (CLAUDE.md は lean を保つ) |

---

## Pillar 2: Stop hook による self-reflection

### 目的

session 終了時、context がまだ fresh なうちに「今回学んだこと」を CLAUDE.md / skill に還流する。**Claude に instruction を覚えさせるよりも deterministic**。

### 仕組み

`Stop` hook は Claude の応答が終わるたびに発火する。そこで「今 session の transcript を見て、新しい convention / gotcha があれば CLAUDE.md update を提案する」スクリプトを噛ませる。

### 最小構成 (`~/.claude/settings.json` または `.claude/settings.json`)

```jsonc
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/home/<you>/.claude/hooks/stop-reflect.sh",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### `stop-reflect.sh` の雛形

```bash
#!/usr/bin/env bash
# Stop hook: scan recent transcript, suggest CLAUDE.md updates.
# Output is shown to Claude as additional context on NEXT turn,
# so phrase it as a hint, not an automated edit.
set -euo pipefail

SESSION_LOG="${CLAUDE_SESSION_TRANSCRIPT:-}"
[ -z "$SESSION_LOG" ] && exit 0
[ ! -f "$SESSION_LOG" ] && exit 0

# Heuristic: was a new gotcha discovered this turn?
# Look for patterns like "actually X" / "turns out Y" / failed-then-fixed.
if grep -qE "(turns out|actually,|gotcha|surprising)" "$SESSION_LOG"; then
  cat <<'EOF'
reflect: this turn may contain a new convention or gotcha worth
capturing. Consider whether the nearest CLAUDE.md (root or subdir)
should be updated, OR whether a new skill is warranted. Do NOT
auto-edit — propose the diff and ask the user first.
EOF
fi

exit 0
```

### 設計上の注意

- **自動編集はしない**。提案だけして user 確認を取る。誤学習が CLAUDE.md に焼き付くと負債化する
- **lean を保つ**。root CLAUDE.md が膨らんだら subdir に下ろす or skill 化する
- **timeout を短く** (30s 以下)。Stop hook が遅いと体感劣化が大きい
- **hook 設定変更は必ず `update-config` skill 経由**で行う

### バリエーション

| バリエーション | 用途 |
|---|---|
| **lint enforcement** | Stop 時に `cargo fmt --check` を回し、未整形なら fail にして次 turn で修正を促す |
| **CLAUDE.md drift detection** | root CLAUDE.md の行数 / sha を baseline と比較し、想定外の膨張を警告 |
| **skill recommendation** | transcript に頻出する操作を検出して「これ skill 化したら？」と提案 |

---

## Pillar 3: LSP 統合 (Language Server Protocol)

### 目的

`grep` / `find` ベースの pattern matching は **同名 symbol が複数言語にまたがる大規模 repo で誤爆する**。LSP を噛ませると Claude は IDE 開発者と同じ navigation (`go to definition` / `find all references`) を使えるようになり、**正しい symbol に着地できる**。

公式 blog: 「For multi-language codebases, this is one of the highest-value investments.」あるエンタープライズ顧客は C/C++ navigation の信頼性を担保するため、Claude Code rollout 前に **org 全体に LSP を deploy** したと紹介されている。

### 何が変わるか

| 操作 | LSP なし | LSP あり |
|---|---|---|
| `User` 型の定義に飛ぶ | grep で 47 hit → 推測 | `go to definition` で 1 発 |
| `getUserById` の呼び出し元一覧 | grep で漏れ / 誤検知 | `find all references` で正確 |
| TS の `User` と Rust の `User` 区別 | 不可能 | 言語別に正しく解決 |
| rename refactor の影響範囲 | sed で誤爆 | LSP が安全に列挙 |

### セットアップ手順

1. **言語ごとの language server をインストール**
   - Rust: `rustup component add rust-analyzer`
   - TypeScript: `npm i -g typescript typescript-language-server`
   - Python: `pip install python-lsp-server` または `pyright`
   - Go: `go install golang.org/x/tools/gopls@latest`
   - C/C++: `clangd` (apt / brew)

2. **Claude Code 側の LSP plugin を有効化** (環境により MCP server / plugin / IDE 拡張のいずれか)
   - VS Code 経由なら、対象言語の公式 LSP 拡張を入れた状態で Claude Code IDE 拡張を使う
   - CLI セッションでは LSP 対応 MCP server (例: `mcp-language-server`) を `~/.claude/settings.json` に登録する

3. **動作確認**
   - 「`User` 型の定義に飛んで」と依頼 → LSP 経由で 1 ファイルに着地すれば OK
   - 「`getUserById` の呼び出し元を全部リストして」 → grep より少ない / 正確な結果が返れば OK

### `.claude/settings.json` 例 (LSP MCP server を載せる場合)

```jsonc
{
  "mcpServers": {
    "lsp": {
      "command": "mcp-language-server",
      "args": [
        "--workspace", ".",
        "--language", "rust",
        "--language", "typescript"
      ]
    }
  }
}
```

### 投資対効果

- **single-language の小 repo**: 効果薄。grep で十分
- **multi-language monorepo**: **最優先投資**。symbol 衝突による誤編集事故が激減
- **legacy C/C++ codebase**: header 経由の symbol 解決が grep だと事実上不可能 → LSP 必須

---

## 適用フロー (新規 repo に当てる時)

1. **現状診断**: `wc -l $(git ls-files | grep -v node_modules)` で規模を見る、`git ls-files | awk -F. '{print $NF}' | sort -u` で言語数を見る
2. **Pillar 1 (CLAUDE.md)** から着手 — まず root を lean に刈り込み、subdir に下ろす
3. **Pillar 3 (LSP)** を multi-language なら同時に — 効果が一番見えやすい
4. **Pillar 2 (Stop hook)** は運用が回ってから — 早すぎると CLAUDE.md にゴミが溜まる

## 関連 skill

- `init` — 単一 CLAUDE.md の初期化 (小規模 repo 向け)
- `update-config` — settings.json / hook 設定変更は必ずこの skill 経由で
- `memory-prune` — CLAUDE.md / memory が膨らんだ時の再分散
- `session-start-hook` — Stop hook と対になる SessionStart hook の設計
- `fewer-permission-prompts` — `.claude/settings.json` の permission 調整

## 参考

- 公式 blog: https://claude.com/blog/how-claude-code-works-in-large-codebases-best-practices-and-where-to-start
- 公式 docs (memory / CLAUDE.md): https://code.claude.com/docs/en/memory
- 公式 docs (hooks): https://code.claude.com/docs/en/hooks
- Skills launch (2025-10): https://claude.com/skills
