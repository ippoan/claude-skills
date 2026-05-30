#!/usr/bin/env bash
# wlogs.sh — Cloudflare Workers の過去のリクエストメトリクスを取得 (GraphQL Analytics)
#
# usage:
#   wlogs.sh <script-name> [minutes]
#   wlogs.sh dtako-admin 60
#   wlogs.sh --account-id <id> --token <tok> dtako-admin 30
#
# wrangler tail はストリーミング (今後の event のみ) なので、
# 「30分前から今まで」のような過去のログ・メトリクスを見たい時にこれを使う。
#
# Account ID は wrangler.toml から、token は .env / 環境変数から自動検出する。
# worker repo のサブディレクトリ (worktree も含む) で実行すれば override 不要。
set -euo pipefail

ACCOUNT_ID=""
TOKEN=""
SCRIPT=""
MINUTES=30
JSON_OUT=0
RAW=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --token)      TOKEN="$2";      shift 2 ;;
    --json)       JSON_OUT=1;      shift ;;
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
  echo "usage: wlogs.sh <script-name> [minutes] [--account-id ID] [--token TOK] [--json] [--raw]" >&2
  exit 2
fi

# --- Account ID 自動検出 ---
find_wrangler_toml() {
  local d="$PWD"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/wrangler.toml" ]]; then echo "$d/wrangler.toml"; return 0; fi
    if [[ -f "$d/wrangler.jsonc" ]]; then echo "$d/wrangler.jsonc"; return 0; fi
    if [[ -f "$d/wrangler.json"  ]]; then echo "$d/wrangler.json";  return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

if [[ -z "$ACCOUNT_ID" ]]; then
  if WT=$(find_wrangler_toml); then
    case "$WT" in
      *.toml)
        ACCOUNT_ID=$(grep -m1 -E '^[[:space:]]*account_id[[:space:]]*=' "$WT" \
                       | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true) ;;
      *.json|*.jsonc)
        # jsonc から // コメント剥がして jq に渡す
        ACCOUNT_ID=$(sed -E 's|//.*$||' "$WT" | jq -r '.account_id // empty' 2>/dev/null || true) ;;
    esac
  fi
fi

# --- Token 自動検出 ---
load_env_var() {
  # cwd から親方向に .env を探して KEY を読む
  local key="$1" d="$PWD"
  while [[ "$d" != "/" ]]; do
    if [[ -f "$d/.env" ]]; then
      local v
      v=$(grep -m1 -E "^[[:space:]]*${key}=" "$d/.env" 2>/dev/null \
            | sed -E "s/^[[:space:]]*${key}=//; s/^['\"]//; s/['\"]$//" || true)
      if [[ -n "$v" ]]; then echo "$v"; return 0; fi
    fi
    d="$(dirname "$d")"
  done
  return 1
}

if [[ -z "$TOKEN" ]]; then
  TOKEN="${CLOUDFLARE_API_TOKEN:-}"
fi
if [[ -z "$TOKEN" ]]; then
  TOKEN=$(load_env_var CLOUDFLARE_API_TOKEN || true)
fi
if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
fi
if [[ -z "$ACCOUNT_ID" ]]; then
  ACCOUNT_ID=$(load_env_var CLOUDFLARE_ACCOUNT_ID || true)
fi

if [[ -z "$TOKEN" ]]; then
  echo "ERROR: CLOUDFLARE_API_TOKEN not found (env / .env / --token)" >&2
  exit 3
fi
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "ERROR: account_id not found (wrangler.toml / env / --account-id)" >&2
  exit 3
fi

# --- 時刻範囲 ---
START=$(date -u -d "${MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)
END=$(date -u +%Y-%m-%dT%H:%M:%SZ)

QUERY='query($accountTag: String!, $start: Time!, $end: Time!, $scriptName: String!) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      workersInvocationsAdaptive(
        limit: 200,
        filter: {datetime_geq: $start, datetime_leq: $end, scriptName: $scriptName},
        orderBy: [datetime_DESC]
      ) {
        dimensions { datetime status scriptName }
        sum { requests errors duration }
        quantiles { cpuTimeP50 cpuTimeP99 wallTimeP50 wallTimeP99 }
      }
    }
  }
}'

PAYLOAD=$(jq -n --arg q "$QUERY" --arg a "$ACCOUNT_ID" --arg s "$START" --arg e "$END" --arg n "$SCRIPT" \
  '{query:$q, variables:{accountTag:$a,start:$s,end:$e,scriptName:$n}}')

RESP=$(curl -sS -X POST 'https://api.cloudflare.com/client/v4/graphql' \
  -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' \
  -d "$PAYLOAD")

if [[ $RAW -eq 1 ]]; then
  echo "$RESP"
  exit 0
fi

# GraphQL エラー検査
if echo "$RESP" | jq -e '.errors // empty' >/dev/null 2>&1; then
  echo "GraphQL error:" >&2
  echo "$RESP" | jq '.errors' >&2
  exit 4
fi

ROWS=$(echo "$RESP" | jq -c '.data.viewer.accounts[0].workersInvocationsAdaptive // []')
COUNT=$(echo "$ROWS" | jq 'length')

if [[ $JSON_OUT -eq 1 ]]; then
  echo "$ROWS" | jq .
  exit 0
fi

# --- pretty print ---
echo "Worker: $SCRIPT  Account: $ACCOUNT_ID"
echo "Window: $START  →  $END  (last ${MINUTES} min)"
echo "Rows:   $COUNT"
echo "----"

if [[ $COUNT -eq 0 ]]; then
  echo "(no invocations in the window)"
  exit 0
fi

# 色 (TTY なら付ける)
if [[ -t 1 ]]; then
  RED=$'\e[31m'; YEL=$'\e[33m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  RED=""; YEL=""; DIM=""; RST=""
fi

echo "$ROWS" | jq -r '
  .[] |
  [ .dimensions.datetime,
    .dimensions.status,
    (.sum.requests|tostring),
    (.sum.errors|tostring),
    (.sum.duration|tostring),
    ((.quantiles.cpuTimeP99  // 0)|tostring),
    ((.quantiles.wallTimeP99 // 0)|tostring)
  ] | @tsv' | \
while IFS=$'\t' read -r dt status reqs errs dur cpu99 wall99; do
  cpu_ms=$(awk -v u="$cpu99"   'BEGIN{printf "%.0f", u/1000}')
  wall_ms=$(awk -v u="$wall99" 'BEGIN{printf "%.0f", u/1000}')
  marker="  "
  color=""
  case "$status" in
    exceededResources)   marker="!!"; color="$RED" ;;
    scriptThrewException) marker="!!"; color="$RED" ;;
    clientDisconnected)  marker="~ "; color="$YEL" ;;
    success)             marker="  "; color="$DIM" ;;
    *)                   marker="? "; color="$YEL" ;;
  esac
  printf '%s%s %s status=%-20s reqs=%s errs=%s dur=%sms cpuP99=%sms wallP99=%sms%s\n' \
    "$color" "$marker" "$dt" "$status" "$reqs" "$errs" "$dur" "$cpu_ms" "$wall_ms" "$RST"
done

# --- summary ---
SUM=$(echo "$ROWS" | jq '{
  reqs: ([.[].sum.requests]|add // 0),
  errs: ([.[].sum.errors]  |add // 0),
  exceeded: ([.[]|select(.dimensions.status=="exceededResources")]|length),
  thrown:   ([.[]|select(.dimensions.status=="scriptThrewException")]|length),
  disc:     ([.[]|select(.dimensions.status=="clientDisconnected")]|length)
}')
echo "----"
echo "Total: $(echo "$SUM" | jq -r '.reqs') requests, $(echo "$SUM" | jq -r '.errs') errors  " \
     "(exceededResources=$(echo "$SUM" | jq -r '.exceeded')," \
     " scriptThrew=$(echo "$SUM" | jq -r '.thrown')," \
     " clientDisc=$(echo "$SUM" | jq -r '.disc'))"
