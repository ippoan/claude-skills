#!/usr/bin/env bash
# verify-env.sh — .env / wrangler / 本番 SSR の環境変数整合性チェック
set -uo pipefail

PROJECT_DIR="${1:-$(pwd)}"
PROJECT_DIR=$(cd "$PROJECT_DIR" && pwd)
NAME=$(basename "$PROJECT_DIR")

cd "$PROJECT_DIR" || exit 1

RED=$'\e[31m'
GREEN=$'\e[32m'
YELLOW=$'\e[33m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
RESET=$'\e[0m'

echo "${BOLD}=== $NAME ===${RESET}"
echo "${DIM}project: $PROJECT_DIR${RESET}"
echo ""

# ---------- 1. parse .env ----------
declare -A ENV_VARS
if [ -f .env ]; then
  echo "${BOLD}.env:${RESET}"
  while IFS='=' read -r key val; do
    [ -z "$key" ] || [ "${key:0:1}" = "#" ] && continue
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    ENV_VARS["$key"]="$val"
    echo "  $key = $val"
  done < <(grep -E '^[A-Z_][A-Z0-9_]*=' .env 2>/dev/null)
else
  echo "${YELLOW}.env: (none)${RESET}"
fi
echo ""

# ---------- 2. parse wrangler ----------
WRANGLER_FILE=""
if [ -f wrangler.toml ]; then WRANGLER_FILE="wrangler.toml"
elif [ -f wrangler.jsonc ]; then WRANGLER_FILE="wrangler.jsonc"
elif [ -f wrangler.json ]; then WRANGLER_FILE="wrangler.json"
fi

declare -A WRANGLER_VARS
PROD_URL=""
if [ -n "$WRANGLER_FILE" ]; then
  echo "${BOLD}$WRANGLER_FILE [vars]:${RESET}"
  # TOML [vars] block (simple parser)
  if [[ "$WRANGLER_FILE" == *.toml ]]; then
    # find [vars] block (prod, not env.*)
    awk '
      /^\[vars\]/ { in_vars=1; next }
      /^\[/       { in_vars=0; next }
      in_vars && /=/ { print }
    ' "$WRANGLER_FILE" | while IFS='=' read -r key val; do
      key=$(echo "$key" | xargs)
      val=$(echo "$val" | xargs)
      val="${val%\"}"; val="${val#\"}"
      echo "  $key = $val"
    done
    # re-parse into assoc array
    while IFS='=' read -r key val; do
      key=$(echo "$key" | xargs)
      val=$(echo "$val" | xargs)
      val="${val%\"}"; val="${val#\"}"
      [ -n "$key" ] && WRANGLER_VARS["$key"]="$val"
    done < <(awk '/^\[vars\]/{f=1;next} /^\[/{f=0} f && /=/' "$WRANGLER_FILE")
    # find prod route (top-level [[routes]] — exclude env.* sections)
    PROD_URL=$(awk '
      /^\[\[routes\]\]/ { in_routes=1; next }
      /^\[\[env\./     { in_routes=0; next }
      /^\[/ && !/^\[\[routes\]\]/ { in_routes=0 }
      in_routes && /pattern/ { print; exit }
    ' "$WRANGLER_FILE" | grep -oE '"[^"]+"' | head -1 | tr -d '"')
  else
    # JSONC: strip comments and parse (fallback to jq if available)
    if command -v jq >/dev/null 2>&1; then
      local_json=$(sed 's|//.*$||g' "$WRANGLER_FILE" | jq -r '.vars // {} | to_entries[] | "\(.key)=\(.value)"' 2>/dev/null)
      echo "$local_json" | while IFS='=' read -r key val; do
        [ -n "$key" ] && echo "  $key = $val"
      done
      while IFS='=' read -r key val; do
        [ -n "$key" ] && WRANGLER_VARS["$key"]="$val"
      done <<< "$local_json"
      PROD_URL=$(sed 's|//.*$||g' "$WRANGLER_FILE" | jq -r '.routes // [] | .[0].pattern // ""' 2>/dev/null)
    fi
  fi
else
  echo "${YELLOW}wrangler.toml/jsonc: (none)${RESET}"
fi
echo ""

# ---------- 3. fetch production SSR ----------
declare -A PROD_VARS
if [ -n "$PROD_URL" ]; then
  PROD_FULL="https://$PROD_URL/"
  echo "${BOLD}production SSR ($PROD_FULL):${RESET}"
  HTML=$(curl -sf --max-time 10 "$PROD_FULL" 2>/dev/null || echo "")
  if [ -z "$HTML" ]; then
    echo "  ${YELLOW}(fetch failed — DNS/network error)${RESET}"
  else
    # Extract public config via Nuxt payload pattern: "apiBase":"..."
    # Nuxt 4 payload-revive-json / runtimeConfig.public serializes as JSON
    # dedupe across env + wrangler
    declare -A SEEN_KEYS=()
    for var in "${!ENV_VARS[@]}" "${!WRANGLER_VARS[@]}"; do
      [ -n "${SEEN_KEYS[$var]:-}" ] && continue
      SEEN_KEYS["$var"]=1
      # Convert NUXT_PUBLIC_API_BASE → apiBase (camelCase from NUXT_PUBLIC_ prefix)
      [[ "$var" != NUXT_PUBLIC_* ]] && continue
      snake="${var#NUXT_PUBLIC_}"  # e.g. API_BASE
      # snake_case → camelCase
      camel=$(echo "$snake" | awk -F_ '{
        out = tolower($1)
        for (i=2; i<=NF; i++) {
          s = tolower($i)
          out = out toupper(substr(s,1,1)) substr(s,2)
        }
        print out
      }')
      # Find in HTML: "camel":"..." OR camel:"..." (Nuxt 4 payload uses unquoted keys)
      val=$(echo "$HTML" | python3 -c "
import sys, re
h = sys.stdin.read()
m = re.search(r'\"?$camel\"?:\"([^\"]*)\"', h)
print(m.group(1) if m else '', end='')
" 2>/dev/null)
      if [ -n "$val" ]; then
        echo "  $var ($camel) = $val"
        PROD_VARS["$var"]="$val"
      fi
    done
  fi
else
  echo "${YELLOW}production URL: (not found in wrangler routes)${RESET}"
fi
echo ""

# ---------- 4. diff ----------
echo "${BOLD}=== diff ===${RESET}"
MISMATCH=0
ALL_KEYS=$(printf '%s\n' "${!ENV_VARS[@]}" "${!WRANGLER_VARS[@]}" "${!PROD_VARS[@]}" | sort -u | grep -v '^$')

for key in $ALL_KEYS; do
  env_v="${ENV_VARS[$key]:-}"
  wr_v="${WRANGLER_VARS[$key]:-}"
  prod_v="${PROD_VARS[$key]:-}"

  # Only compare if we have at least 2 values
  vals=()
  labels=()
  [ -n "$env_v" ]  && { vals+=("$env_v");  labels+=(".env"); }
  [ -n "$wr_v" ]   && { vals+=("$wr_v");   labels+=("wrangler"); }
  [ -n "$prod_v" ] && { vals+=("$prod_v"); labels+=("prod-live"); }

  [ "${#vals[@]}" -lt 2 ] && continue

  # uniq count
  uniq=$(printf '%s\n' "${vals[@]}" | sort -u | wc -l)
  if [ "$uniq" -gt 1 ]; then
    MISMATCH=$((MISMATCH+1))
    echo "${RED}⚠ MISMATCH: $key${RESET}"
    for i in "${!vals[@]}"; do
      printf "  %-10s: %s\n" "${labels[$i]}" "${vals[$i]}"
    done
    # suggest: prod-live が正解の可能性が高い
    if [ -n "$prod_v" ] && [ "$env_v" != "$prod_v" ] && [ -n "$env_v" ]; then
      echo "  ${YELLOW}→ .env を \"$prod_v\" に合わせる ?${RESET}"
    fi
  else
    echo "${GREEN}✓${RESET} $key = ${vals[0]}"
  fi
done

echo ""
if [ "$MISMATCH" -eq 0 ]; then
  echo "${GREEN}${BOLD}OK${RESET} — all consistent"
  exit 0
else
  echo "${RED}${BOLD}$MISMATCH mismatch(es) detected${RESET}"
  exit 1
fi
