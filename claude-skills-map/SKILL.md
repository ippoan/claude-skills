---
name: claude-skills-map
generated-from: claude-skills:11d265f2ad3e110850c90e9c3beb04978e7da424
description: ippoan/claude-skills (この repo 自身。Claude Code 共有 skill 集) の構造ナビゲーション。skill ディレクトリ群を「種別 (per-repo map / PR・CI 運用 / 構造把握メタ / secret・MCP / テスト・カバレッジ / freee・egov ドメイン / ブラウザ・ファイル・その他)」ごとにグループ索引化し、SKILL.md レイアウト規約・README 追記・scripts/.claude の位置を 1 枚にまとめる。トリガー:「claude-skills」「skill 一覧」「skill 追加」「どの skill」「SKILL.md 規約」「<repo>-map どこ」「skill 索引」「skill 種別」等。
---

# claude-skills-map — ippoan/claude-skills 構造ナビゲーション

ippoan プロジェクト共通の Claude Code **skill 集** (この repo 自身)。各 skill は
`<name>/SKILL.md` ディレクトリ単位。この repo を project として開くと全 skill が `/<name>`
で使える。別 repo からは `claude-hooks/session-start-install-skills.sh` が symlink する。

> ここは索引 (pointer)。個々の skill の使い方は各 `SKILL.md` が正 (description は繰り返さない)。
> frontmatter の `generated-from` が現在の repo tree-sha とズレたら session-start hook が
> 再生成を促す → その時 tree-sha を更新する。**新しい skill を追加したら本 map と
> README.md の両方を更新する** (skill 追加 = tree-sha 変化 = 鮮度警告のトリガー)。

## skill グループ (種別ごとの索引)

| グループ | 代表 skill | 役割 |
|---|---|---|
| **per-repo map** (`<repo>-map`) | `auth-worker-map` `ci-dashboard-map` `rust-alc-api-map` `secrets-inventory(-gcp)-map` `release-wave-gcp-map` `ci-workflows-map` `freee-map` `HealthConnectReader(Worker)-map` `nuxt-*-map` `dtako-scraper-map` 他多数 | 1 repo の構造ナビゲーション。frontmatter に `generated-from: <repo>:<tree-sha>` を持ち鮮度追跡される。**新規は `repo-map` skill で作る** |
| **構造把握メタ** | `repo-map` `cross-repo-symbol-index` `ippoan-infra-map` `large-codebase-setup` | per-repo map の作り方 / 横断 symbol 方針 / CCoW 基盤 5 repo 地図 / 大規模 codebase setup |
| **PR / CI 運用** | `pr-push` `pr-subscribe` `ci-init` `ci-cache-patterns` `tag-release` `branch-issue-linking` `auto-merge-401` `gh-actions-phantom-permission` `check-issue` | PR 作成・購読 / CI bootstrap / release tag / 命名規約 / CI fail トラブルシュート |
| **テスト / カバレッジ** | `nuxt-vitest` `worker-vitest` `coverage-check` `coverage-test-patterns` `migrate-test` `type-safe-pipeline` `verify-env` | 各種テストハーネス / coverage gate / 型安全 pipeline / env 検証 |
| **secret / MCP / package** | `secret-inject` `mcp-user-setup` `package-publish-debug` `npm-supply-chain` | no-leak secret 投入 / user-scope MCP attach / publish デバッグ / supply chain |
| **ドメイン (freee / egov)** | `egov-api` `egov-spec` (freee 系は freee repo 同梱) | e-Gov 電子申請 API / 仕様取得 |
| **ブラウザ / ファイル / 配信** | `cdp-browser` `ui-preview` `ui-preview-map` `eml-read` `ref-files-bulk` `wrangler-logs` | CDP 操作 / UI preview 配信 / eml 解読 / ref-files 一括 DL / Workers ログ |
| **worktree / open** | `worktree-cleanup` `wt-direct-push` `open-multirepo` `open-multirepo-smoke` `repo-migrate` `memory-prune` | worktree 掃除・直 push / multirepo 起動 URL / 移行 / memory 整理 |

> 完全な人間向け一覧と各 1 行説明は `README.md` の「スキル一覧」が正。本表はグループ索引。

## 区画 (top-level レイアウト)

| パス | 中身 |
|---|---|
| `<name>/SKILL.md` | 旧来の top-level layout (引き続きサポート)。現状の skill の大半 |
| `.claude/skills/<name>/SKILL.md` | **新しい skill の推奨パス**。現状 `gh-actions-phantom-permission` `ippoan-infra-map` `large-codebase-setup` `open-multirepo` `ui-preview` |
| `scripts/extract_symbol.py` | source から特定 symbol を抽出して context 節約 (Rust/Python/TS/Go/PHP)。`cross-repo-symbol-index` 系が使う |
| `README.md` | 人間向け skill 一覧 + install 方法 (SessionStart hook / 手動) |
| ルートの単独 `*.md` | skill ではない note: `backend-check.md` `bazel-rust.md` `compare-pdf.md` `smart-read.md` |

## entrypoint / 使い方

- 実行 entrypoint は無い (skill リポジトリ)。各 skill は Claude が `/<name>` または description トリガーで起動する。
- 別 repo から使うには `claude-hooks` の `session-start-install-skills.sh` を `~/.claude/settings.json` に登録 (= `~/.claude/sources/` に shallow clone → 各 SKILL.md を `~/.claude/skills/<name>` に symlink、冪等 TTL 1h)。

## gotcha (README 由来)

- **新規 skill は `.claude/skills/<name>/SKILL.md` を使う** (top-level は legacy)。
- `yhonda-ohishi/claude-skills` から移行した repo。secret 値や内部インフラ詳細を埋めていた skill (`secrets.md` `supabase-r2` `incus-sandbox` `wt-quick` `secret-rotate-pipe` `dev-proxy-debug`) は **移行時に意図的に除外**。同種を再追加しない。
- per-repo map を足したら README の「スキル一覧」にも 1 行追記する (この repo 自身の tree-sha が変わり、claude-skills-map の鮮度警告も出る)。

## CCoW / CI から見た立ち位置

- CCoW container では `session-start-install-skills.sh` (claude-hooks) がこの repo を clone して全 skill を配る。`session-start-skill-coverage` hook が「開いた repo に対応 `<repo>-map` skill が無い / 鮮度切れ」を検知して `repo-map` 起動を促す。
- skill の鮮度追跡は frontmatter の `generated-from: <repo>:<tree-sha>` を SessionStart hook が tree-sha 比較する仕組み (`cross-repo-symbol-index` skill に設計の結論)。

## 関連 skill

- `repo-map` — per-repo map (`<repo>-map`) を新規作成 / 更新するメタ skill。本 repo の map 群の生成元
- `cross-repo-symbol-index` — map 鮮度 hook と横断 symbol 把握の方針 (保存せずその場 ctags)
- `ippoan-infra-map` — CCoW 基盤 5 repo の地図 (skill 配布元の claude-hooks を含む)
- `memory-prune` / `skill-creator` (外部) — skill 化 / 整理の運用
