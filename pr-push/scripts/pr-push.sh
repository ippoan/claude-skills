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
