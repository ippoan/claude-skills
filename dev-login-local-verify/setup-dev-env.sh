#!/usr/bin/env bash
# dev-login ローカル検証環境を 1 コマンドで立ち上げる (Windows Git Bash 前提)。
#
# nuxt-dtako-admin の repo ルート (メイン worktree) から実行:
#   bash .claude/skills/dev-login-local-verify/setup-dev-env.sh [name] [options]
#
#   name              worktree 名 (default: wrangler-dev-test)。.claude/worktrees/<name> に作る
#   --hybrid          nuxt dev (HMR) も並走させる。編集→反映が nuxt build 90秒 → 0.1秒になる。
#                     nuxt.config.ts の devProxy に /api/proxy と /__dev の :8787 転送が必要
#   --wrangler-port N wrangler dev の port (default: 8787)。hybrid 時は devProxy が 8787 固定
#                     なので変えないこと
#   --nuxt-port N     nuxt dev の port (default: 3000)
#   --no-build        nuxt build を強制スキップ
#   --build           nuxt build を強制実行
#
# build の既定は「.output/server/index.mjs が無い時だけ実行」。hybrid では UI は
# nuxt dev (:3000) が配信するため、wrangler 側の .output は binding 依存 route
# (/api/proxy, /__dev) を動かすためだけに必要 — UI が古くても問題ない。
# server/ 配下や依存 (auth-client 等) を変えた時だけ --build を付けること。
#
# やること: git fetch → worktree add/更新 (origin/main detached) → node_modules を
# donor から junction (0秒) or npm install (gh auth token) → wrangler.prebuilt.toml 生成
# → port 先住チェック → nuxt build → wrangler dev 起動 (Ready 待ち) → (--hybrid で
# nuxt dev も起動)。最後に issue_dev_login_url に渡す port を表示する。
set -euo pipefail

NAME="wrangler-dev-test"
HYBRID=0
WPORT=8787
NPORT=3000
BUILD=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --hybrid) HYBRID=1 ;;
    --wrangler-port) WPORT=$2; shift ;;
    --nuxt-port) NPORT=$2; shift ;;
    --build) BUILD=1 ;;
    --no-build) BUILD=0 ;;
    -h|--help) grep '^#' "$0" | head -20; exit 0 ;;
    *) NAME=$1 ;;
  esac
  shift
done

ROOT=$(git rev-parse --show-toplevel)
WT="$ROOT/.claude/worktrees/$NAME"

echo "== [1/6] worktree ($WT)"
git -C "$ROOT" fetch origin
if [ -d "$WT" ]; then
  git -C "$WT" checkout --detach origin/main
else
  git -C "$ROOT" worktree add --detach "$WT" origin/main
fi

echo "== [2/6] node_modules"
# 壊れた symlink (donor worktree 削除後の残骸) は作り直す
if [ -L "$WT/node_modules" ] && [ ! -e "$WT/node_modules" ]; then
  rm "$WT/node_modules"
fi
if [ ! -e "$WT/node_modules" ]; then
  DONOR=""
  for c in "$ROOT" "$ROOT"/.claude/worktrees/*; do
    [ "$c" = "$WT" ] && continue
    if [ -d "$c/node_modules" ] && [ ! -L "$c/node_modules" ]; then
      DONOR="$c"
      break
    fi
  done
  if [ -n "$DONOR" ]; then
    cmd //c mklink /J "$(cygpath -w "$WT/node_modules")" "$(cygpath -w "$DONOR/node_modules")" > /dev/null
    echo "   junction -> $DONOR/node_modules"
    if ! diff -q <(git -C "$ROOT" show origin/main:package.json) "$DONOR/package.json" > /dev/null 2>&1; then
      echo "   !! donor の package.json が origin/main と異なる (auth-client bump 等)。"
      echo "   !! 必要なら donor で npm install してから再実行するか、junction を消して"
      echo "   !! このスクリプトを再実行 (npm install パスに落ちる)"
    fi
  else
    echo "   donor なし -> npm install (gh auth token で GH Packages 認証)"
    NPMRC=$(mktemp)
    printf '//npm.pkg.github.com/:_authToken=%s\n' "$(gh auth token)" > "$NPMRC"
    (cd "$WT" && NPM_CONFIG_USERCONFIG="$NPMRC" npm install --no-audit --no-fund)
    rm -f "$NPMRC"
  fi
fi

echo "== [3/6] wrangler.prebuilt.toml ([build] 除去で起動 168s->23s)"
sed '/^\[build\]$/,/^$/d' "$WT/wrangler.toml" > "$WT/wrangler.prebuilt.toml"

echo "== [4/6] port $WPORT 先住チェック"
if netstat -ano 2>/dev/null | grep "LISTENING" | grep -q ":${WPORT}[^0-9]"; then
  echo "   !! port ${WPORT} に先住プロセスあり。旧 workerd が旧バンドルで応答する罠 (SKILL.md 手順0)。"
  echo '   !! PowerShell: Get-NetTCPConnection -LocalPort <port> -State Listen | % { Stop-Process -Id $_.OwningProcess -Force }'
  exit 1
fi

if [ "$BUILD" = auto ]; then
  if [ -f "$WT/.output/server/index.mjs" ]; then
    BUILD=0
    echo "== [5/6] nuxt build スキップ (.output あり。server/ や依存を変えた時は --build)"
  else
    BUILD=1
  fi
fi
if [ "$BUILD" = 1 ]; then
  echo "== [5/6] nuxt build (~90s)"
  (cd "$WT" && npx nuxt build)
elif [ ! -f "$WT/.output/server/index.mjs" ]; then
  echo "!! --no-build 指定だが .output が無い。一度 build が必要"
  exit 1
fi

echo "== [6/6] wrangler dev 起動"
(cd "$WT" && npx wrangler dev -c wrangler.prebuilt.toml --remote --var DEV_LOGIN:true --port "$WPORT" > wrangler-dev.log 2>&1 &)
for _ in $(seq 1 90); do
  grep -q "Ready on" "$WT/wrangler-dev.log" 2>/dev/null && break
  sleep 2
done
if ! grep -q "Ready on" "$WT/wrangler-dev.log" 2>/dev/null; then
  echo "!! wrangler dev が Ready にならない。$WT/wrangler-dev.log を確認"
  exit 1
fi
echo "   wrangler dev Ready :$WPORT"

if [ "$HYBRID" = 1 ]; then
  if ! grep -q "'/api/proxy'" "$WT/nuxt.config.ts"; then
    echo "!! nuxt.config.ts の devProxy に /api/proxy 転送がない (hybrid 未対応の revision)。"
    echo "!! wrangler dev 単体 (:$WPORT) は使える。SKILL.md の hybrid 節を参照"
    exit 1
  fi
  if [ "$WPORT" != 8787 ]; then
    echo "!! hybrid は devProxy が :8787 固定のため --wrangler-port 変更と併用不可"
    exit 1
  fi
  echo "== hybrid: nuxt dev 起動"
  API=$(grep -oP '^NUXT_PUBLIC_API_BASE\s*=\s*"\K[^"]+' "$WT/wrangler.toml")
  AUTH=$(grep -oP '^NUXT_PUBLIC_AUTH_WORKER_URL\s*=\s*"\K[^"]+' "$WT/wrangler.toml")
  ALC=$(grep -oP '^NUXT_ALC_API_URL\s*=\s*"\K[^"]+' "$WT/wrangler.toml")
  (cd "$WT" && NUXT_PUBLIC_API_BASE="$API" NUXT_PUBLIC_AUTH_WORKER_URL="$AUTH" NUXT_ALC_API_URL="$ALC" \
    npx nuxt dev --port "$NPORT" > nuxt-dev.log 2>&1 &)
  for _ in $(seq 1 60); do
    grep -qE "Local:.*$NPORT" "$WT/nuxt-dev.log" 2>/dev/null && break
    sleep 2
  done
  echo "   nuxt dev Ready :$NPORT (HMR)"
  echo ""
  echo "次: issue_dev_login_url({ port: $NPORT }) -> ブラウザで開く (UI編集は即時反映)"
else
  echo ""
  echo "次: issue_dev_login_url({ port: $WPORT }) -> ブラウザで開く"
  echo "    ソース編集後は worktree で npx nuxt build するだけ (wrangler が自動 reload)"
fi
