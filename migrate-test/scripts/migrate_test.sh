#!/bin/bash
set -euo pipefail

# マイグレーション検証スクリプト（プロジェクト非依存）
# カレントディレクトリの migrations/ を使い、ローカルPostgresで Supabase lint する
#
# Usage:
#   migrate_test.sh              # ローカルDBでmigrate→lint→削除
#   migrate_test.sh --db-url=URL # 指定DBに対してlintのみ実行
#
# プロジェクト固有の初期化:
#   scripts/init_local_db.sql があれば Postgres 起動後に自動適用
#   .env の DATABASE_URL に ?options= があれば sqlx migrate に渡す

CONTAINER_NAME="migrate-test-pg"
LOCAL_PORT=54321
LOCAL_DB_URL="postgresql://postgres:test@localhost:${LOCAL_PORT}/postgres?sslmode=disable"
LINT_ONLY=false
TARGET_DB_URL=""

for arg in "$@"; do
    case $arg in
        --db-url=*)
            TARGET_DB_URL="${arg#*=}"
            LINT_ONLY=true
            ;;
        --help|-h)
            echo "Usage: $0 [--db-url=URL]"
            echo "  (no args)        ローカルPostgresを起動→migrate→lint→削除"
            echo "  --db-url=URL     指定DBに対してlintのみ実行"
            echo ""
            echo "  scripts/init_local_db.sql があれば自動適用"
            echo "  .env の DATABASE_URL の ?options= を sqlx migrate に引き継ぎ"
            exit 0
            ;;
    esac
done

# migrations/ の存在確認
if [ "$LINT_ONLY" = false ] && [ ! -d "migrations" ]; then
    echo "ERROR: migrations/ directory not found in $(pwd)"
    exit 1
fi

# .env から DATABASE_URL の options パラメータを抽出
MIGRATE_DB_URL="$LOCAL_DB_URL"
if [ -f ".env" ]; then
    PROD_DB_URL=$(grep -E '^DATABASE_URL=' .env | head -1 | sed 's/^DATABASE_URL=//' | sed 's/^"//;s/"$//' || true)
    if [[ "$PROD_DB_URL" == *"options="* ]]; then
        OPTIONS_PARAM=$(echo "$PROD_DB_URL" | grep -oP '\?options=[^&]+' || true)
        if [ -n "$OPTIONS_PARAM" ]; then
            MIGRATE_DB_URL="${LOCAL_DB_URL}&${OPTIONS_PARAM#?}"
            echo "  Detected options: ${OPTIONS_PARAM}"
        fi
    fi
fi

# splinter.sql をキャッシュ付きでダウンロード（7日有効）
SPLINTER_CACHE="/tmp/splinter.sql"
if [ ! -f "$SPLINTER_CACHE" ] || [ -n "$(find "$SPLINTER_CACHE" -mtime +7 2>/dev/null)" ]; then
    echo "==> Downloading splinter.sql..."
    curl -sL https://raw.githubusercontent.com/supabase/splinter/main/splinter.sql -o "$SPLINTER_CACHE"
fi

run_splinter() {
    local db_url="$1"
    local result
    result=$(psql "$db_url" -t -f "$SPLINTER_CACHE" 2>/dev/null \
        | grep '{SECURITY}' || true)
    if [ -n "$result" ]; then
        echo "$result"
        return 1
    fi
    return 0
}

cleanup() {
    if [ "$LINT_ONLY" = false ]; then
        echo "==> Cleaning up..."
        docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [ "$LINT_ONLY" = true ]; then
    echo "=== Splinter lint (target DB) ==="
    run_splinter "$TARGET_DB_URL"
    echo "  OK"
    exit 0
fi

echo "=== Step 1: Start local Postgres ==="
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
docker run -d --name "$CONTAINER_NAME" \
    -e POSTGRES_PASSWORD=test \
    -p "${LOCAL_PORT}:5432" \
    postgres:16 > /dev/null
echo "  Waiting for Postgres to be ready..."
for _ in $(seq 1 30); do
    if pg_isready -h localhost -p "$LOCAL_PORT" -q 2>/dev/null; then
        break
    fi
    sleep 1
done
if ! pg_isready -h localhost -p "$LOCAL_PORT" -q 2>/dev/null; then
    echo "ERROR: Postgres failed to start"
    exit 1
fi

# プロジェクト固有の初期化 SQL があれば適用
if [ -f "scripts/init_local_db.sql" ]; then
    echo "  Applying scripts/init_local_db.sql..."
    psql "$LOCAL_DB_URL" -q -f "scripts/init_local_db.sql"
else
    # デフォルト: Supabase互換の初期設定
    psql "$LOCAL_DB_URL" -q <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DATABASE postgres SET pgrst.db_schemas = 'public';
SQL
fi
echo "  OK"

echo "=== Step 2: Apply migrations ==="
sqlx migrate run --database-url "$MIGRATE_DB_URL"
echo "  OK ($(ls migrations/*.sql | wc -l) migration files)"

# マイグレーション後の GRANT（init_local_db.sql にロールがある場合）
if [ -f "scripts/init_local_db.sql" ]; then
    # init_local_db.sql で作成されたカスタムロールに全テーブルの権限を付与
    CUSTOM_ROLES=$(grep -oP 'CREATE ROLE \K\w+' scripts/init_local_db.sql | grep -v -E '^(anon|authenticated|service_role)$' || true)
    for role in $CUSTOM_ROLES; do
        SCHEMAS=$(grep -oP 'CREATE SCHEMA IF NOT EXISTS \K\w+' scripts/init_local_db.sql || echo "public")
        for schema in $SCHEMAS; do
            psql "$LOCAL_DB_URL" -q -c "GRANT ALL ON ALL TABLES IN SCHEMA $schema TO $role;" 2>/dev/null || true
            psql "$LOCAL_DB_URL" -q -c "GRANT ALL ON ALL SEQUENCES IN SCHEMA $schema TO $role;" 2>/dev/null || true
        done
    done
fi

echo "=== Step 3: Splinter lint ==="
run_splinter "$LOCAL_DB_URL"
echo "  OK"

echo ""
echo "========================================="
echo "  All checks passed"
echo "========================================="
