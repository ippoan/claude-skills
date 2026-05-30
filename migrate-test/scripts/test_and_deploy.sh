#!/bin/bash
set -euo pipefail

# 汎用テスト → デプロイ 統合スクリプト
# プロジェクトルートの .test-config から設定を読み込む
#
# Usage:
#   test_and_deploy.sh                         # テストのみ
#   test_and_deploy.sh --deploy                # テスト通過後にデプロイ
#   test_and_deploy.sh --skip-integration      # インテグレーションテストをスキップ
#   test_and_deploy.sh --skip-frontend         # フロントエンドテストをスキップ
#   test_and_deploy.sh --skip-extra            # プロジェクト固有テストをスキップ

DEPLOY=false
SKIP_INTEGRATION=false
SKIP_FRONTEND=false
SKIP_EXTRA=false

for arg in "$@"; do
    case $arg in
        --deploy) DEPLOY=true ;;
        --skip-integration) SKIP_INTEGRATION=true ;;
        --skip-frontend) SKIP_FRONTEND=true ;;
        --skip-extra) SKIP_EXTRA=true ;;
        --help|-h)
            echo "Usage: $0 [--deploy] [--skip-integration] [--skip-frontend] [--skip-extra]"
            echo ""
            echo "  --deploy             テスト通過後にデプロイを実行"
            echo "  --skip-integration   インテグレーションテストをスキップ"
            echo "  --skip-frontend      フロントエンドテストをスキップ"
            echo "  --skip-extra         プロジェクト固有テストをスキップ"
            echo ""
            echo "設定: .test-config (プロジェクトルート)"
            exit 0
            ;;
    esac
done

# === .test-config 読み込み ===
# デフォルト値
TEST_DB_PORT="${TEST_DB_PORT:-54322}"
TEST_DB_OPTIONS="${TEST_DB_OPTIONS:-}"
FRONTEND_DIR="${FRONTEND_DIR:-}"
FRONTEND_TEST_CMD="${FRONTEND_TEST_CMD:-npm test -- --run}"
FRONTEND_DEPLOY_CMD="${FRONTEND_DEPLOY_CMD:-npm run deploy}"
CLOUD_RUN_SERVICE="${CLOUD_RUN_SERVICE:-}"
CLOUD_RUN_REGION="${CLOUD_RUN_REGION:-asia-northeast1}"
EXTRA_TEST_CMD="${EXTRA_TEST_CMD:-}"
UNIT_TEST_FILTER="${UNIT_TEST_FILTER:-}"

if [ -f ".test-config" ]; then
    # shellcheck source=/dev/null
    source .test-config
fi

# TEST_DATABASE_URL を組み立て
TEST_DB_URL="postgresql://postgres:test@localhost:${TEST_DB_PORT}/postgres"
if [ -n "$TEST_DB_OPTIONS" ]; then
    TEST_DB_URL="${TEST_DB_URL}?${TEST_DB_OPTIONS}"
fi

STEP=1

echo "=== Step $STEP: cargo fmt --check ==="
cargo fmt --check
echo "  OK"
STEP=$((STEP+1))

echo ""
echo "=== Step $STEP: cargo clippy ==="
cargo clippy 2>&1 | tail -5
echo "  OK"
STEP=$((STEP+1))

echo ""
echo "=== Step $STEP: cargo test --lib (ユニットテスト) ==="
if [ -n "$UNIT_TEST_FILTER" ]; then
    cargo test --lib "$UNIT_TEST_FILTER" 2>&1 | tail -10
else
    cargo test --lib 2>&1 | tail -10
fi
echo "  OK"
STEP=$((STEP+1))

echo ""
echo "=== Step $STEP: マイグレーション検証 (ローカルDB + splinter lint) ==="
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/migrate_test.sh"
echo "  OK"
STEP=$((STEP+1))

if [ "$SKIP_INTEGRATION" = false ] && [ -d "tests" ] && ls tests/*_test.rs >/dev/null 2>&1; then
    echo ""
    echo "=== Step $STEP: インテグレーションテスト ==="

    docker compose up -d test-db
    echo "  Waiting for test DB..."
    for i in $(seq 1 30); do
        if pg_isready -h localhost -p "$TEST_DB_PORT" -q 2>/dev/null; then break; fi
        sleep 1
    done
    if ! pg_isready -h localhost -p "$TEST_DB_PORT" -q 2>/dev/null; then
        echo "  ERROR: Test DB failed to start"
        docker compose down
        exit 1
    fi

    TEST_DATABASE_URL="$TEST_DB_URL" cargo test --test '*' -- --test-threads=1 2>&1 | tail -20
    RESULT=$?
    docker compose down
    if [ $RESULT -ne 0 ]; then
        echo "  FAIL: インテグレーションテスト失敗"
        exit 1
    fi
    echo "  OK"
else
    echo ""
    echo "=== Step $STEP: インテグレーションテスト — スキップ ==="
fi
STEP=$((STEP+1))

# プロジェクト固有テスト (daiun-salary の CSV 比較など)
if [ "$SKIP_EXTRA" = false ] && [ -n "$EXTRA_TEST_CMD" ]; then
    echo ""
    echo "=== Step $STEP: プロジェクト固有テスト ==="
    eval "$EXTRA_TEST_CMD"
    echo "  OK"
else
    if [ -n "$EXTRA_TEST_CMD" ]; then
        echo ""
        echo "=== Step $STEP: プロジェクト固有テスト — スキップ ==="
    fi
fi
STEP=$((STEP+1))

if [ "$SKIP_FRONTEND" = false ] && [ -n "$FRONTEND_DIR" ] && [ -d "$FRONTEND_DIR" ]; then
    echo ""
    echo "=== Step $STEP: フロントエンドテスト ($FRONTEND_DIR) ==="
    (cd "$FRONTEND_DIR" && eval "$FRONTEND_TEST_CMD" 2>&1 | tail -15)
    echo "  OK"
else
    echo ""
    echo "=== Step $STEP: フロントエンドテスト — スキップ ==="
fi
STEP=$((STEP+1))

echo ""
echo "========================================="
echo "  全チェック通過"
echo "========================================="

if [ "$DEPLOY" = true ]; then
    echo ""
    echo "=== バックエンドデプロイ ==="
    ./deploy.sh

    # ヘルスチェック
    if [ -n "$CLOUD_RUN_SERVICE" ]; then
        echo ""
        echo "=== ヘルスチェック ==="
        SERVICE_URL=$(gcloud run services describe "$CLOUD_RUN_SERVICE" \
            --region "$CLOUD_RUN_REGION" --format 'value(status.url)')
        for i in $(seq 1 12); do
            if curl -sf "${SERVICE_URL}/api/health" > /dev/null 2>&1; then
                echo "  OK: ${SERVICE_URL}/api/health"
                break
            fi
            [ "$i" = "12" ] && echo "  WARN: ヘルスチェック応答なし (60秒タイムアウト)"
            sleep 5
        done
    fi

    # フロントエンドデプロイ
    if [ -n "$FRONTEND_DIR" ] && [ -d "$FRONTEND_DIR" ]; then
        echo ""
        echo "=== フロントエンドデプロイ ($FRONTEND_DIR) ==="
        (cd "$FRONTEND_DIR" && eval "$FRONTEND_DEPLOY_CMD" 2>&1 | tail -5)
        echo "  OK"
    fi
else
    echo ""
    echo "(--deploy を指定するとデプロイを実行します)"
fi
