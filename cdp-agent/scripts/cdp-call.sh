#!/bin/bash
# cdp-call.sh — cdp-agent の /mcp を curl で叩いて手元 Chrome を操作する。
#
#   cdp-call.sh <MCP_URL> screenshot              … 画面を /tmp/cdp-shot.png に保存
#   cdp-call.sh <MCP_URL> navigate <url>          … 手元タブを url に遷移
#
# MCP_URL は拡張の「接続用プロンプトをコピー」で渡される
# https://<rnd>.trycloudflare.com/mcp。screenshot 後は Read tool で /tmp/cdp-shot.png を開く。
set -u

MCP="${1:-}"
METHOD="${2:-}"
if [ -z "$MCP" ] || [ -z "$METHOD" ]; then
  echo "usage: cdp-call.sh <MCP_URL> {screenshot | navigate <url>}" >&2
  exit 2
fi

post() {
  # $1 = JSON body
  curl -sS -m 40 -X POST "$MCP" -H 'Content-Type: application/json' -d "$1"
}

case "$METHOD" in
  screenshot)
    OUT="${CDP_SHOT_OUT:-/tmp/cdp-shot.png}"
    resp=$(post '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"browser_screenshot","arguments":{}}}')
    OUT="$OUT" printf '%s' "$resp" | python3 -c '
import sys, json, base64, os
d = json.load(sys.stdin)
if "error" in d:
    print("ERROR:", d["error"]); sys.exit(1)
try:
    data = d["result"]["content"][0]["data"]
except Exception:
    print("unexpected response:", json.dumps(d)[:300]); sys.exit(1)
out = os.environ.get("OUT", "/tmp/cdp-shot.png")
open(out, "wb").write(base64.b64decode(data))
print(f"saved {out} ({len(data)} b64 chars) — Read tool で開いて画面を確認")
'
    ;;
  navigate)
    URL="${3:-}"
    if [ -z "$URL" ]; then echo "navigate には URL が必要" >&2; exit 2; fi
    # URL を JSON に安全に埋め込む (python で escape)。
    body=$(URL="$URL" python3 -c '
import json, os
print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":"browser_navigate","arguments":{"url":os.environ["URL"]}}}))
')
    post "$body"; echo
    ;;
  *)
    echo "unknown method: $METHOD (screenshot | navigate)" >&2
    exit 2
    ;;
esac
