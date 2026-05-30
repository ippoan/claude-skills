---
name: repo-migrate
description: >
  Repository パターン移行の並列ワークフロー。
  Agent 並列でコード書き → cherry-pick で統合 → 1 PR で merge。
  トリガー: 「repo-migrate」「リポジトリ移行」「repository pattern」等。
---

# Repository Pattern Migration — Cherry-Pick Workflow

並列 Agent でリポジトリファイルを作成し、cherry-pick で統合ブランチにまとめて 1 PR で merge するワークフロー。

## Workspace 構成

```
rust-alc-api/                    # ルート (バイナリ: main.rs, migrate.rs)
├── crates/
│   ├── alc-core/                # 共通基盤 (認証, JWT, ミドルウェア, DB models, repository, webhook, FCM)
│   │   └── src/auth/            # google.rs, jwt.rs, lineworks.rs, middleware.rs
│   ├── alc-carins/              # 車検証管理 (car_inspections, carins_files, nfc_tags)
│   ├── alc-compare/             # 比較ロジック
│   ├── alc-csv-parser/          # CSV パーサー (kudgivt, kudguri, work_segments)
│   ├── alc-devices/             # デバイス登録・管理
│   ├── alc-dtako/               # デジタコ (restraint_report, scraper, upload 等)
│   ├── alc-misc/                # その他ルート (employees, measurements, timecard 等)
│   ├── alc-pdf/                 # PDF 生成
│   ├── alc-storage/             # ストレージ抽象 (R2, GCS)
│   ├── alc-tenko/               # 点呼 (sessions, schedules, records, webhooks, equipment)
│   └── alc-test-helpers/        # テスト用 (mock_storage, mock repos, app_state)
├── tests/                       # インテグレーションテスト
│   ├── common/mod.rs            # テストハーネス
│   └── mock_*/                  # mock テスト (crate 別バイナリ)
├── migrations/                  # SQLx マイグレーション
└── coverage_100.toml            # カバレッジ 100% ファイル登録簿
```

### 依存関係

- 各 crate は `alc-core` に依存 (models, repository, auth 等)
- `workspace.dependencies` で全バージョンを一元管理
- `alc-test-helpers` は `[dev-dependencies]` 専用

## 概要

```
[Agent 1] ─→ worktree/file_a ─→ commit ─┐
[Agent 2] ─→ worktree/file_b ─→ commit ─┤  cherry-pick
[Agent 3] ─→ worktree/file_c ─→ commit ─┤  ─→ 統合ブランチ ─→ 共有ファイル更新 ─→ push ─→ CI ─→ merge
[Agent N] ─→ worktree/file_n ─→ commit ─┘
```

## 手順

### Step 1: worktree 一括作成

```bash
# 対象ファイル名を列挙
FILES="auth bot_admin carins_files carrying_items"

# main から各 worktree 作成
for name in $FILES; do
  git worktree add -b "wip/repo_${name}" ".claude/worktrees/${name}" main
done
```

### Step 2: Agent 並列起動

各 Agent に以下を指示:
- **Bash 不使用** — Read/Write/Edit/Glob/Grep のみ
- worktree パスを明示: `/home/yhonda/rust/rust-alc-api/.claude/worktrees/<name>/`
- 変更対象:
  - `src/db/repository/<name>.rs` — **新規作成** (trait + Pg実装)
  - `src/routes/<name>.rs` — **書き換え** (repository 経由に)
- **共有ファイルは変更しない** (mod.rs, lib.rs, main.rs, tests/common/mod.rs)

```
Agent プロンプトテンプレート:
"""
Repository パターン移行。Do NOT use Bash. Read/Write/Edit/Glob/Grep のみ。

Working directory: /home/yhonda/rust/rust-alc-api/.claude/worktrees/<name>/

参照パターン:
- src/db/repository/employees.rs — trait + PgXxxRepository のパターン
- src/db/repository/mod.rs — TenantConn

タスク:
1. src/db/repository/<name>.rs を新規作成 (trait + Pg実装)
2. src/routes/<name>.rs を書き換え (state.<name>.*() 経由に)

**重要**: 以下のファイルは変更しないでください:
- src/db/repository/mod.rs
- src/lib.rs
- src/main.rs
- tests/common/mod.rs
"""
```

### Step 3: Agent 完了後 — 各 worktree で commit

```bash
for name in $FILES; do
  cd /home/yhonda/rust/rust-alc-api/.claude/worktrees/${name}
  cargo fmt
  git add src/db/repository/${name}.rs src/routes/${name}.rs
  git commit -m "wip: ${name} repository"
  cd -
done
```

**注意**: `git add` は repository ファイルと routes ファイルのみ。共有ファイルは add しない。

### Step 4: 統合ブランチ作成 + cherry-pick

```bash
# main から統合ブランチ
git checkout main && git pull origin main
git checkout -b fix/repo_batch_xyz

# 各 worktree の commit を cherry-pick
for name in $FILES; do
  # worktree ブランチの HEAD commit hash を取得
  hash=$(git log --format=%H -1 "wip/repo_${name}")
  git cherry-pick --no-commit "$hash"
done
```

### Step 5: 共有ファイルを1回だけ更新

手動または Agent で以下を更新:

1. **`src/db/repository/mod.rs`** — `pub mod xxx;` + `pub use xxx::{XxxRepository, PgXxxRepository};` を追加
2. **`src/lib.rs`** — AppState に `pub xxx: Arc<dyn XxxRepository>,` を追加
3. **`src/main.rs`** — `PgXxxRepository::new(pool.clone())` 構築 + AppState に追加
4. **`tests/common/mod.rs`** — 3つの `setup_app_state*` に追加

### Step 6: check + push + CI

```bash
cargo fmt && cargo clippy -- -D warnings
git add -A
git commit -m "refactor: introduce XxxRepository traits (batch)"
git push -u origin fix/repo_batch_xyz

gh pr create --base main --head fix/repo_batch_xyz --title "refactor: repository pattern batch" --body "..."
# CI 待ち → merge
```

### Step 7: クリーンアップ

```bash
for name in $FILES; do
  git worktree remove ".claude/worktrees/${name}"
  git branch -D "wip/repo_${name}"
done
```

## Agent プロンプト — 詳細版

以下を Agent に渡す:

```
Repository パターン移行。Do NOT use Bash. Read/Write/Edit/Glob/Grep のみ。

## Working directory
/home/yhonda/rust/rust-alc-api/.claude/worktrees/<NAME>/

## 参照パターン
まず以下を読んでパターンを理解:
- src/db/repository/mod.rs — TenantConn
- src/db/repository/employees.rs — trait + PgEmployeeRepository (参照)
- src/routes/<NAME>.rs — 移行対象の現在のコード

## タスク
1. src/db/repository/<NAME>.rs を新規作成
   - XxxRepository trait (async メソッド)
   - PgXxxRepository struct (pool: PgPool, new(pool))
   - TenantConn::acquire() でテナントコンテキスト
   - テナント不要のクエリは pool.acquire() 直接

2. src/routes/<NAME>.rs を書き換え
   - state.pool + set_current_tenant → state.<NAME>.*() に置換
   - HTTP ロジック (StatusCode, Json, エラーマッピング) はハンドラに残す
   - import: use crate::db::repository::XxxRepository; を追加
     (注: mod.rs に pub use がまだないので、フルパスで import)
     → use crate::db::repository::<NAME>::XxxRepository;

## 変更禁止ファイル
- src/db/repository/mod.rs
- src/lib.rs
- src/main.rs
- tests/common/mod.rs

## 注意
- clippy::too_many_arguments が出る場合は trait に #[allow(clippy::too_many_arguments)] を付ける
- model 型はローカル定義のまま or db/models.rs から import
```

## トラブルシューティング

### cherry-pick でコンフリクト
repository ファイルは新規作成なのでコンフリクトしない。routes ファイルも各 Agent が別ファイルを編集するのでコンフリクトしない。共有ファイルを変更していなければコンフリクトは起きない。

### カバレッジリグレッション
リファクタで行の書き方が変わるとカバレッジツールが未カバー判定することがある。
- `ok_or_else(|| { tracing::error!(...); StatusCode })` → `ok_or(StatusCode)` に簡略化
- `if x { "a" } else { "b" }` → `x.map(|_| "a").unwrap_or("b")` に変換
- 統合ブランチで `cargo clippy` 後に確認
