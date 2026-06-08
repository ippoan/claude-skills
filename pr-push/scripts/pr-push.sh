#!/bin/bash
# pr-push: push → PR作成 → CI run ID 出力
set -euo pipefail

TITLE="${1:?Usage: pr-push.sh <title> [body]}"
BODY="${2:-🤖 Generated with [Claude Code](https://claude.com/claude-code)}"
BRANCH=$(git branch --show-current)

# Default branch (main / master 等を repo から検出)
BASE=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo main)

# Guards
[[ "$BRANCH" =~ ^(main|master)$ ]] && { echo "ERROR: $BRANCH では実行不可" >&2; exit 1; }
[[ -n "$(git status --porcelain)" ]] && { echo "ERROR: 未コミットの変更あり" >&2; exit 1; }

PR_STATE=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null || echo "NONE")
[[ "$PR_STATE" =~ ^(MERGED|CLOSED)$ ]] && { echo "ERROR: PR は $PR_STATE。新ブランチを作成" >&2; exit 1; }

# wt-direct-push allowlist guard (PreToolUse hook の robust な backstop)
#   allowlist repo は branch protection 無し / auto-merge 未設定。そこで PR を
#   作っても塩漬けになり、その間に tag-release が古い main から build → release
#   から changes が漏れる (Refs ippoan/github-mcp-server-rs#28; archived,
#   monorepo: ippoan/mcp-relay-rs)。PreToolUse hook (pr-push-allowlist-guard.sh)
#   は command 文字列から cwd を推定するため脆い。本 script は正確な cwd で
#   owner/name を解決して確実に弾く。正当な理由で PR したい時は
#   PR_PUSH_ALLOW_ANY=1 で bypass。
if [[ "${PR_PUSH_ALLOW_ANY:-0}" != "1" ]]; then
  ALLOWLIST=""
  for _cand in \
    "$HOME/.claude/skills/wt-direct-push/config/direct-push-ok.txt" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/wt-direct-push/config/direct-push-ok.txt"; do
    [[ -f "$_cand" ]] && { ALLOWLIST="$_cand"; break; }
  done
  if [[ -n "$ALLOWLIST" ]]; then
    # owner/name は gh が最優先 (proxy remote でも正確)。失敗時のみ URL を parse
    # (github.com 系 + CCoW proxy の .../git/owner/name 形式の末尾 2 segment)。
    ALLOWLIST_REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || echo "")
    if [[ -z "$ALLOWLIST_REPO" ]]; then
      ALLOWLIST_REPO=$(git remote get-url origin 2>/dev/null \
        | sed -E 's#\.git$##; s#/$##' \
        | grep -oE '[^/:]+/[^/]+$' || echo "")
    fi
    if [[ -n "$ALLOWLIST_REPO" ]] \
       && grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | grep -qxF "$ALLOWLIST_REPO"; then
      echo "ERROR: $ALLOWLIST_REPO は wt-direct-push allowlist に登録済 (branch protection 無し / auto-merge 未設定)。" >&2
      echo "       /pr-push ではなく /wt-direct-push でコミット済み変更を直 push してください:" >&2
      echo "         bash ~/.claude/skills/wt-direct-push/scripts/wt-direct-push.sh" >&2
      echo "       背景: PR を作っても auto-merge 無しで塩漬けになり、その間に tag-release が" >&2
      echo "       古い main から build → release から changes が漏れます (ippoan/github-mcp-server-rs#28)。" >&2
      echo "       どうしても PR にしたい正当な理由がある場合は PR_PUSH_ALLOW_ANY=1 を付けて再実行。" >&2
      exit 1
    fi
  fi
fi

# Push
echo ">>> push $BRANCH"
git push -u origin "$BRANCH" 2>&1

# PR (なければ作成)
if [ "$PR_STATE" = "NONE" ]; then
  echo ">>> pr create (base=$BASE)"
  PR_URL=$(gh pr create --base "$BASE" --head "$BRANCH" --title "$TITLE" --body "$BODY")
  echo "PR: $PR_URL"
else
  PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url')
  echo "PR: $PR_URL (existing)"
fi

# Mergeable check (GitHub の計算に数秒かかるためリトライ)
echo ">>> checking mergeable status"
MERGEABLE=""
for i in 1 2 3; do
  sleep 3
  MERGEABLE=$(gh pr view "$BRANCH" --json mergeable --jq '.mergeable' 2>/dev/null || echo "")
  [ -n "$MERGEABLE" ] && [ "$MERGEABLE" != "UNKNOWN" ] && break
done
if [ "$MERGEABLE" = "CONFLICTING" ]; then
  echo "ERROR: PR has merge conflicts with origin/$BASE!" >&2
  # コンフリクトファイル一覧を git merge-tree で取得 (index/worktree に触れない)
  git fetch origin "$BASE" --quiet 2>/dev/null || true
  CONFLICT_FILES=$(git merge-tree --write-tree --no-messages "origin/$BASE" "$BRANCH" 2>&1 | tail -n +2) || true
  if [ -n "$CONFLICT_FILES" ]; then
    echo "Conflicting files:" >&2
    echo "$CONFLICT_FILES" >&2
  fi
  echo "Rebase or merge $BASE into this branch to resolve." >&2
  exit 1
fi

# Worktree detection + MAIN_ROOT (WATCH_CMD で使うため先に計算)
SCRIPT_CWD=$(pwd)
MAIN_ROOT=$(git rev-parse --path-format=absolute --git-common-dir | sed 's|/\.git$||')

# CI run ID (PR イベントトリガーは遅延があるためリトライ)
REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
RUN_ID=""
for i in 1 2 3; do
  sleep 5
  RUN_ID=$(gh run list -R "$REPO" --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || echo "")
  [ -n "$RUN_ID" ] && break
  echo "CI run not found yet, retry $i/3..."
done
if [ -n "$RUN_ID" ]; then
  echo "CI: $RUN_ID"
  echo "WATCH_CMD=gh run watch $RUN_ID -R $REPO --exit-status && git -C $MAIN_ROOT fetch origin $BASE || echo '⚠️ CI FAILED: gh run view $RUN_ID -R $REPO でログを確認し、worktree で修正してください'"
else
  echo "WARNING: CI run not found (CI workflow が無い repo は正常)"
fi

# Worktree auto-remove (コードはリモートにある)
if [[ "$SCRIPT_CWD" == */.claude/worktrees/* ]]; then
  WT_ROOT=$(echo "$SCRIPT_CWD" | sed 's|\(.*\.claude/worktrees/[^/]*\).*|\1|')
  cd "$MAIN_ROOT" 2>/dev/null && git worktree remove "$WT_ROOT" --force 2>/dev/null
  [ -n "$BRANCH" ] && git branch -d "$BRANCH" 2>/dev/null
  echo "CLEANUP: worktree removed ($WT_ROOT)"
fi
