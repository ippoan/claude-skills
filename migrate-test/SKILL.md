---
name: migrate-test
description: "Supabase + SQLx プロジェクトのマイグレーションセキュリティ検証 + 統合テスト＋デプロイ。ローカルPostgresにマイグレーション適用後、splinter(Supabase Postgres Linter)でRLS/セキュリティチェックを実行する。トリガー: マイグレーションファイル(migrations/*.sql)を追加・変更した時、「マイグレーションテスト」「migrate test」「migration lint」「RLSチェック」「splinter」等。"
---

# Migration Test + Test & Deploy

## 前提条件

- Docker、`sqlx-cli`、`psql`
- カレントディレクトリに `migrations/` が存在すること

## スクリプト

### migrate_test.sh — マイグレーション検証のみ

```bash
# ローカルPostgresで全マイグレーション適用 + セキュリティlint
bash ~/.claude/skills/migrate-test/scripts/migrate_test.sh

# 本番DBに対してlintのみ
bash ~/.claude/skills/migrate-test/scripts/migrate_test.sh --db-url="$DATABASE_URL"
```

プロジェクト固有の初期化が必要な場合は `scripts/init_local_db.sql` を配置する。
`.env` の `DATABASE_URL` に `?options=` があれば自動的に `sqlx migrate` に引き継ぐ。

### test_and_deploy.sh — 統合テスト + デプロイ

```bash
# テストのみ
bash ~/.claude/skills/migrate-test/scripts/test_and_deploy.sh

# テスト + デプロイ
bash ~/.claude/skills/migrate-test/scripts/test_and_deploy.sh --deploy

# オプション
--skip-integration   インテグレーションテストをスキップ
--skip-frontend      フロントエンドテストをスキップ
--skip-extra         プロジェクト固有テストをスキップ
```

設定は `.test-config` (プロジェクトルート) で行う:

| 変数 | 説明 | 例 |
|------|------|----|
| `TEST_DB_PORT` | テスト用DB ポート | `54322` |
| `TEST_DB_OPTIONS` | DB URL クエリパラメータ | `options=-c search_path=alc_api` |
| `FRONTEND_DIR` | フロントエンドディレクトリ | `alc-app/web` |
| `FRONTEND_TEST_CMD` | フロントエンドテストコマンド | `npm test -- --run` |
| `FRONTEND_DEPLOY_CMD` | フロントエンドデプロイコマンド | `npm run deploy` |
| `CLOUD_RUN_SERVICE` | Cloud Run サービス名 | `rust-alc-api` |
| `CLOUD_RUN_REGION` | Cloud Run リージョン | `asia-northeast1` |
| `EXTRA_TEST_CMD` | プロジェクト固有テスト | `bash scripts/csv_compare_test.sh` |
| `UNIT_TEST_FILTER` | cargo test フィルタ | `restraint_report` |

## lint失敗時

1. `{SECURITY}` カテゴリの警告内容を確認
2. マイグレーションファイルを修正して再実行
