#!/bin/bash
# browser-eval.sh — 手元ブラウザ (cdp-agent の MCP) で JS 式を評価する汎用ヘルパー。
#
# CCoW から直叩きできない API (CF Access 配下 / SPA 保持 token が要る / egress WAF で弾かれる)
# を、ブラウザの実行コンテキスト (cookie + token + 同一オリジン) で代理 fetch するために使う。
#
# 使い方:
#   browser-eval.sh <MCP_URL> '<js-expression>'
#   browser-eval.sh <MCP_URL> --file expr.js
#
#   <MCP_URL>        : cdp-agent popup の「接続用プロンプトをコピー」で渡される
#                      https://<rnd>.trycloudflare.com/mcp (agent 再起動で URL は変わる)
#                      cdp-relay/cdp-pair 経由なら mcp__cdp-relay__browser_eval を直接呼ぶ方が楽。
#   <js-expression>  : ブラウザで評価する JS。値は小さく返すこと (PNG 等は別途 screenshot)。
#       例: "(async()=>{const r=await fetch('/api/x',{headers:{Authorization:'Bearer '+window._token}});return await r.text();})()"
#
# 出力: 評価結果の文字列 (tools/call result.content[0].text) を stdout に出す。
# 注: 数百KB の base64 を式に埋める場合は --file で渡す (シェル引数長/エスケープ回避)。
set -u
URL="${1:?usage: browser-eval.sh <MCP_URL> <js-expr|--file path>}"; shift
if [ "${1:-}" = "--file" ]; then EXPR="$(cat "${2:?--file needs a path}")"; else EXPR="${1:?usage: browser-eval.sh <MCP_URL> <js-expr|--file path>}"; fi

EXPR="$EXPR" URL="$URL" python3 - <<'PY'
import json, os, subprocess, sys
url, expr = os.environ["URL"], os.environ["EXPR"]
payload = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call",
  "params":{"name":"browser_eval","arguments":{"expression":expr}}})
p = subprocess.run(["curl","-sS","-m","120","-X","POST",url,
  "-H","Content-Type: application/json","--data-binary","@-"],
  input=payload.encode(), capture_output=True)
out = p.stdout.decode()
try:
    print(json.loads(out)["result"]["content"][0]["text"])
except Exception:
    sys.stderr.write("raw: " + out[:600] + "\n" + p.stderr.decode()[:300] + "\n")
    raise SystemExit(1)
PY
