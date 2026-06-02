#!/usr/bin/env bash
# inject-secret.sh — secret を GCP(SoT)/CF Secrets Store/GitHub Actions org secret に
# no-leak で投入する。値は shell の中だけを通り、LLM context / tool-call JSON /
# log には一切載らない (shell var → curl body → worker → Secret Manager)。
#
# 経路 (install.sh の OAT bootstrap と secrets-inventory MUST_READ から再構成):
#   1. CCoW container の Anthropic OAT (/home/claude/.claude/remote/.oauth_token)
#   2. auth-worker /mcp/pair/grant-via-oat で mcp.write scope の binding_jwt を mint
#      (aud=github-mcp-server-rs。secrets worker の binding-jwt middleware が introspect で受理)
#   3. security-inventory /mcp/secret-upload/:name に値を --data-binary で直送
#
# 値は **必ず stdin から** 受ける (argv に置かない = process list にも残さない)。
#   ランダム生成:  openssl rand -hex 32 | inject-secret.sh NAME
#   ファイルから:  inject-secret.sh NAME < /tmp/value && shred -u /tmp/value
#
# Usage:
#   <値を stdin に> inject-secret.sh <NAME> [--rotate] [--targets gcp,cf,github] [--allow-existing]
#
# env override:
#   SECRET_AUTH_ORIGIN     grant-via-oat の auth-worker (default https://auth.ippoan.org)
#   SECRET_UPLOAD_ORIGIN   secret-upload の worker     (default https://security-inventory.ippoan.org)
#   SECRET_OAT_FILE        OAT path (default /home/claude/.claude/remote/.oauth_token)
#
# 出力は HTTP code と response metadata のみ (値は echo しない)。
set -uo pipefail

NAME="${1:-}"
[ -n "$NAME" ] || { echo "usage: <value-on-stdin> inject-secret.sh <NAME> [--rotate] [--targets ...] [--allow-existing]" >&2; exit 2; }
shift || true

MODE="create"
TARGETS="gcp,cf,github"
FAIL_IF_EXISTS="true"
while [ $# -gt 0 ]; do
  case "$1" in
    --rotate)         MODE="rotate" ;;
    --targets)        TARGETS="${2:-}"; shift ;;
    --allow-existing) FAIL_IF_EXISTS="false" ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# default は staging。この org の MCP スタックは staging を実運用として扱い
# (cc-relay → mcp-staging、ci-dashboard staging-only)、prod auth.ippoan.org は
# 現状 `MCP_OAUTH_KV not bound` で grant が 503。prod security-inventory は
# staging-minted JWT を introspect 受理するので staging mint で投入は成立する。
# prod auth が復旧したら SECRET_AUTH_ORIGIN=https://auth.ippoan.org で上書き可。
AUTH_ORIGIN="${SECRET_AUTH_ORIGIN:-https://auth-staging.ippoan.org}"
UPLOAD_ORIGIN="${SECRET_UPLOAD_ORIGIN:-https://security-inventory.ippoan.org}"
OAT_FILE="${SECRET_OAT_FILE:-/home/claude/.claude/remote/.oauth_token}"

[ -r "$OAT_FILE" ] || { echo "OAT not readable: $OAT_FILE" >&2; exit 1; }
oat=$(tr -d '[:space:]' < "$OAT_FILE")
[ -n "$oat" ] || { echo "OAT empty" >&2; exit 1; }

# 値を一時 file に退避 (stdin は 1 回しか読めない & curl retry のため)。0600。
# 末尾の改行/空白は除去する (openssl/echo の trailing newline 対策。worker は
# trailing whitespace を default で reject する)。意図的に残すなら SECRET_KEEP_TRAILING=1。
val_file=$(mktemp); chmod 600 "$val_file"
if [ "${SECRET_KEEP_TRAILING:-0}" = "1" ]; then
  cat > "$val_file"
else
  # command substitution は末尾の改行を全て落とす。printf で改行なし書き出し。
  secret_raw=$(cat); printf '%s' "$secret_raw" > "$val_file"; unset secret_raw
fi
[ -s "$val_file" ] || { echo "no value on stdin" >&2; rm -f "$val_file"; exit 2; }
trap 'rm -f "$val_file" "${resp:-}" "${up:-}" 2>/dev/null' EXIT

# 5xx/000 は transient (prod auth-worker は時々 503)。指数 backoff で retry。
retry() {  # retry <max> <cmd...>
  local max="$1"; shift; local i=1 code
  while :; do
    code=$("$@") && [ "$code" != "000" ] && [ "${code:0:1}" != "5" ] && { echo "$code"; return 0; }
    [ "$i" -ge "$max" ] && { echo "$code"; return 1; }
    sleep $((2 ** (i - 1))); i=$((i + 1))
  done
}

# 1. mint binding_jwt (mcp.write)
resp=$(mktemp); chmod 600 "$resp"
do_grant() {
  curl -sS -o "$resp" -w "%{http_code}" --max-time 15 \
    -X POST "${AUTH_ORIGIN}/mcp/pair/grant-via-oat" \
    -H "Authorization: Bearer $oat" -H "Content-Type: application/json" \
    -d '{"aud":"github-mcp-server-rs","scope":"mcp.read mcp.write"}' 2>/dev/null || echo "000"
}
gh=$(retry 4 do_grant)
echo "grant-via-oat: $gh"
[ "$gh" = "200" ] || { echo "grant failed (status $gh)" >&2; exit 1; }
jwt=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("binding_jwt",""))' "$resp" 2>/dev/null || echo "")
[ -n "$jwt" ] || { echo "binding_jwt missing in grant response" >&2; exit 1; }

# 2. value を --data-binary で直送 (argv に値を置かない)
up=$(mktemp); chmod 600 "$up"
do_upload() {
  curl -sS -o "$up" -w "%{http_code}" --max-time 25 \
    -X PUT "${UPLOAD_ORIGIN}/mcp/secret-upload/${NAME}?targets=${TARGETS}&mode=${MODE}&fail_if_exists=${FAIL_IF_EXISTS}" \
    -H "Authorization: Bearer $jwt" -H "Content-Type: application/octet-stream" \
    --data-binary @"$val_file" 2>/dev/null || echo "000"
}
uc=$(retry 4 do_upload)
unset jwt
echo "secret-upload: $uc"
echo "response: $(cat "$up")"
[ "$uc" = "200" ] || [ "$uc" = "201" ] || { echo "upload failed (status $uc)" >&2; exit 1; }
echo "OK: ${NAME} → ${TARGETS} (${MODE})"
