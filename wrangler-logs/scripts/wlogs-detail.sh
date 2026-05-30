#!/usr/bin/env bash
# wlogs-detail.sh — Workers Observability の telemetry/query で **実際のログ行** を取得
#
# usage:
#   wlogs-detail.sh <script-name> [minutes]
#
# 注意: token に "Workers Observability:Read" 権限が必要。wrangler login の
# default cfut_* token には付かないので、付いていない場合は wlogs.sh (GraphQL) に
# fallback する旨を案内して終了する。
#
# 個別の console.log / Exception スタックトレース等を見たい時用。
set -euo pipefail

ACCOUNT_ID=""
TOKEN=""
SCRIPT=""
MINUTES=30
LIMIT=50
RAW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --token)      TOKEN="$2";      shift 2 ;;
    --limit)      LIMIT="$2";      shift 2 ;;
    --raw)        RAW=1;           shift ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# //; s/^#//'
      exit 0 ;;
    --*) echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$SCRIPT" ]]; then SCRIPT="$1"
      else MINUTES="$1"; fi
      shift ;;
  esac
done

if [[ -z "$SCRIPT" ]]; then
  echo "usage: wlogs-detail.sh <script-name> [minutes] [--limit N]" >&2
  exit 2
fi

# wlogs.sh と同じ自動検出ロジックを使い回す
SDIR="$(cd "$(dirname "$0")" && pwd)"

# --- account_id 検出 ---
if [[ -z "$ACCOUNT_ID" ]]; then
  d="$PWD"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/wrangler.toml" ]]; then
      ACCOUNT_ID=$(grep -m1 -E '^[[:space:]]*account_id[[:space:]]*=' "$d/wrangler.toml" \
                     | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)
      [[ -n "$ACCOUNT_ID" ]] && break
    fi
    if [[ -f "$d/wrangler.jsonc" ]] || [[ -f "$d/wrangler.json" ]]; then
      f="$d/wrangler.jsonc"; [[ -f "$d/wrangler.json" ]] && f="$d/wrangler.json"
      ACCOUNT_ID=$(sed -E 's|//.*$||' "$f" | jq -r '.account_id // empty' 2>/dev/null || true)
      [[ -n "$ACCOUNT_ID" ]] && break
    fi
    d="$(dirname "$d")"
  done
fi
[[ -z "$ACCOUNT_ID" ]] && ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"

# --- token 検出 ---
if [[ -z "$TOKEN" ]]; then TOKEN="${CLOUDFLARE_API_TOKEN:-}"; fi
if [[ -z "$TOKEN" ]]; then
  d="$PWD"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/.env" ]]; then
      v=$(grep -m1 -E '^[[:space:]]*CLOUDFLARE_API_TOKEN=' "$d/.env" 2>/dev/null \
            | sed -E "s/^[[:space:]]*CLOUDFLARE_API_TOKEN=//; s/^['\"]//; s/['\"]$//" || true)
      if [[ -n "$v" ]]; then TOKEN="$v"; break; fi
    fi
    d="$(dirname "$d")"
  done
fi

if [[ -z "$TOKEN" || -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: token or account_id missing" >&2
  exit 3
fi

# 時刻範囲 (ms epoch)
NOW_MS=$(date +%s%3N)
PAST_MS=$(( NOW_MS - MINUTES*60*1000 ))

PAYLOAD=$(jq -n \
  --arg script "$SCRIPT" \
  --argjson from "$PAST_MS" \
  --argjson to "$NOW_MS" \
  --argjson limit "$LIMIT" \
  '{
    queryId: "workers-logs",
    timeframe: { from: $from, to: $to },
    parameters: {
      datasets: ["cloudflare-workers"],
      filters: [{ key: "$metadata.service", operation: "eq", type: "string", value: $script }],
      limit: $limit
    }
  }')

RESP=$(curl -sS -X POST \
  "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/workers/observability/telemetry/query" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d "$PAYLOAD")

if [[ $RAW -eq 1 ]]; then
  echo "$RESP"
  exit 0
fi

# 認証エラー検出
if echo "$RESP" | jq -e '(.success == false) and (.errors[]?.message | test("Authentication"; "i"))' >/dev/null 2>&1; then
  echo "Workers Observability:Read 権限がトークンにありません。"  >&2
  echo "wrangler login の default token (cfut_*) では使えません。" >&2
  echo "代わりに wlogs.sh (GraphQL Analytics) を使ってください:"   >&2
  echo "  bash $SDIR/wlogs.sh $SCRIPT $MINUTES"                     >&2
  exit 5
fi

# 一般エラー
if echo "$RESP" | jq -e '.success == false' >/dev/null 2>&1; then
  echo "API error:" >&2
  echo "$RESP" | jq '.errors // .' >&2
  exit 4
fi

# ログ行を整形
EVENTS=$(echo "$RESP" | jq -c '.result.events // .result.calculations[0].events // []' 2>/dev/null || echo '[]')
COUNT=$(echo "$EVENTS" | jq 'length')

echo "Worker: $SCRIPT  Account: $ACCOUNT_ID"
echo "Window: last ${MINUTES} min  Events: $COUNT"
echo "----"

if [[ $COUNT -eq 0 ]]; then
  echo "(no log events in the window)"
  exit 0
fi

echo "$EVENTS" | jq -r '
  .[] |
  [
    (.timestamp // .["$workers"].timestamp // ""),
    (.["$metadata.level"] // .level // "info"),
    (.message // .body // (. | tostring))
  ] | @tsv
' | while IFS=$'\t' read -r ts level msg; do
  printf '%s [%s] %s\n' "$ts" "$level" "$msg"
done
