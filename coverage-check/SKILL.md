---
name: coverage-check
description: >
  Rust プロジェクトのカバレッジ未カバー行を検索・表示するスキル。
  cargo llvm-cov --text の出力からファイル単位で未カバー行(実行回数0)を抽出する。
  トリガー: 「未カバー」「カバレッジ」「coverage」「uncovered lines」
  「どこがテストされていない」「テスト漏れ」「カバレッジ確認」等。
---

# Coverage Check

`cargo llvm-cov --text` の出力から未カバー行を抽出するスクリプト。

## スクリプト

```bash
SCRIPT="$HOME/.claude/skills/coverage-check/scripts/coverage_uncovered.sh"

# ★推奨: サマリ + 未カバー行を1回で取得 (テスト実行1回だけ)
bash $SCRIPT --refresh --full dtako_upload.rs

# コンテキスト付き一括 (前後3行 + >>> マーカー)
bash $SCRIPT --refresh --full --context dtako_upload.rs

# 特定ファイルの未カバー行 (キャッシュ使用)
bash $SCRIPT dtako_upload.rs

# コンテキスト付き
bash $SCRIPT --context dtako_upload.rs

# 部分一致で複数ファイル
bash $SCRIPT dtako_

# 未カバー行があるファイル一覧 (行数順)
bash $SCRIPT --list

# カバレッジサマリのみ
bash $SCRIPT --summary
```

## --full モード (推奨)

サマリ (パーセント) + 未カバー行を **テスト1回の実行で両方出力**。
`--context` と併用でコンテキスト付き。

```
=== Summary ===
routes/dtako_upload.rs  2425  162  93.32%  131  8  93.89%  1574  19  98.79%
TOTAL                  26504 4605  82.63% 1349 373 72.35% 19041 2774 85.43%

=== src/routes/dtako_upload.rs ===
   254:         tracing::warn!("CSV split failed (will not block): {e}");
   403:                 }
...
--- Total uncovered lines: 11 ---
```

## キャッシュ

- `cargo llvm-cov --text` は遅い (~5分) ため `/tmp/llvm-cov-cache/` にキャッシュ
- `src/` or `tests/` の `.rs` ファイルが更新されると自動再実行
- `--refresh` で強制再実行

## カバレッジ作業のワークフロー

1. `bash $SCRIPT --refresh --full --context <file>` で未カバー行 + サマリを一括取得
2. テストをまとめて全部書く (中間確認しない)
3. `cargo test` 1回だけ実行して全テスト通過を確認
4. `bash $SCRIPT --refresh --full <file>` で最終確認 (1回だけ)

**重要: 中間でカバレッジ確認しない。テスト実行は最小限に。**

## カバレッジ専用テストの分離

エラー注入やエッジケース等、カバレッジ100%のためだけのテストは通常テストから分離できる:

```rust
#[cfg_attr(not(coverage), ignore)]  // cargo test ではスキップ、cargo llvm-cov では実行
#[tokio::test]
async fn test_error_path_for_coverage() { ... }
```

- `cargo test` → `#[ignore]` 扱い → スキップ (高速)
- `cargo llvm-cov` → `cfg(coverage)` 有効 → `#[ignore]` なし → 実行
- `cargo test -- --include-ignored` で明示的に全実行も可能

詳細は `/coverage-test-patterns` スキルの「カバレッジ専用テストの分離」セクション参照。

## 100% 未達成ファイル一覧

キャッシュから Miss > 0 のファイルだけ表示する。

```bash
# キャッシュがあればそのまま (テスト実行なし)
bash $SCRIPT --not-100

# 最新データで取得 (テスト再実行)
bash $SCRIPT --refresh --not-100
```

## 100% カバレッジ リグレッション検証

`coverage_100.toml` に登録されたファイルが 100% を維持しているか検証する。
CI (GitHub Actions) でも自動実行される。

```bash
# 全ファイル検証 (DB 必要)
bash scripts/check_coverage_100.sh

# unit ファイルのみ (DB 不要、高速)
bash scripts/check_coverage_100.sh --unit-only

# Makefile 経由
make cov-check          # 全ファイル
make cov-check-unit     # unit のみ
```

100% に到達したファイルは `coverage_100.toml` に追加して CI でガードする。

## CI artifact からカバレッジ取得 (ローカル実行不要)

CI (push/PR) と coverage.yml (workflow_dispatch) が `llvm-cov-text` artifact をアップロードする。
Makefile ターゲットで artifact ダウンロード → `parse_coverage.sh` でパースできる。

```bash
# 未達成ファイル一覧 (CI最新)
make cov-not100

# 全ファイルサマリ
make cov-summary

# 特定ファイルの未カバー行
make cov-file F=devices

# workflow_dispatch で手動トリガー (GitHub UI or CLI)
gh workflow run coverage.yml --field mode=not-100
gh workflow run coverage.yml --field mode=file --field file_pattern=devices
```

ダウンロードされたデータは `/tmp/llvm-cov-cache/ci-latest.txt` にキャッシュされる。

## 前提

- `cargo-llvm-cov` がインストール済み
- プロジェクトルートで実行すること
- `.test-config` があれば自動で `source` する

## NOTE: --text vs --json の差異

`cargo llvm-cov --text` と `--json` ではカバレッジの行カウントが異なる。
`--json` は閉じ括弧等を余分にカウントするため、`--text` で 100% でも `--json` で 98% になるケースがある。
本スキルおよび `check_coverage_100.sh` は **`--text` ベース** で統一している。
