#!/bin/bash
# wt-direct-push: worktree でコミット → master/main に fast-forward 直 push → worktree 削除。
#
# 対象 repo は config/direct-push-ok.txt にホワイトリスト登録された branch-protection 無し / auto-merge 未設定 の repo のみ。
# その他の repo では /pr-push を案内してエラー終了する。
set -euo pipefail

SKILL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ALLOWLIST="$SKILL_DIR/config/direct-push-ok.txt"

TITLE="${1:-}"
BODY="${2:-}"  # optional, used only when amending a commit message. Normally caller commits first.

# --- 1. cwd / branch / repo 検出 ---
SCRIPT_CWD=$(pwd)
BRANCH=$(git branch --show-current 2>/dev/null || echo "")
[[ -z "$BRANCH" ]] && { echo "ERROR: detached HEAD or not in a git repo" >&2; exit 1; }
[[ "$BRANCH" =~ ^(main|master)$ ]] && { echo "ERROR: 既に default branch ($BRANCH) にいます。worktree で作業してから直 push して下さい" >&2; exit 1; }

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
REPO=$(echo "$REMOTE_URL" | sed -E 's#^(git@github\.com:|https://github\.com/)([^/]+/[^/.]+)(\.git)?/?$#\2#')
[[ -z "$REPO" || "$REPO" == "$REMOTE_URL" ]] && { echo "ERROR: origin remote 解決失敗: $REMOTE_URL" >&2; exit 1; }

# --- 2. allowlist チェック ---
if ! grep -vE '^[[:space:]]*(#|$)' "$ALLOWLIST" | grep -qxF "$REPO"; then
  echo "ERROR: $REPO は direct-push-OK ホワイトリストにありません" >&2
  echo "       通常 repo は /pr-push を使ってください。" >&2
  echo "       direct-push を許可する場合は $ALLOWLIST に '$REPO' を追加してから再実行。" >&2
  exit 1
fi

# --- 3. default branch 取得 ---
DEFAULT_BRANCH=$(gh repo view "$REPO" --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null)
[[ -z "$DEFAULT_BRANCH" ]] && { echo "ERROR: default branch 取得失敗 ($REPO)" >&2; exit 1; }

# --- 4. dirty / 未コミット handling ---
if [[ -n "$(git status --porcelain)" ]]; then
  if [[ -n "$TITLE" ]]; then
    echo ">>> auto-commit (title=$TITLE)"
    git add -A
    if [[ -n "$BODY" ]]; then
      git commit -m "$TITLE" -m "$BODY"
    else
      git commit -m "$TITLE"
    fi
  else
    echo "ERROR: 未コミットの変更あり。先に commit するか、引数で title を渡して下さい:" >&2
    echo "       /wt-direct-push \"<commit message>\"" >&2
    git status -sb >&2
    exit 1
  fi
fi

# --- 5. push 対象 commit 有無 ---
git fetch origin "$DEFAULT_BRANCH" --quiet
AHEAD=$(git rev-list --count "origin/$DEFAULT_BRANCH..HEAD" 2>/dev/null || echo "0")
BEHIND=$(git rev-list --count "HEAD..origin/$DEFAULT_BRANCH" 2>/dev/null || echo "0")

if [[ "$AHEAD" == "0" ]]; then
  echo "ERROR: HEAD has no commits ahead of origin/$DEFAULT_BRANCH — nothing to push" >&2
  exit 1
fi
if [[ "$BEHIND" != "0" ]]; then
  echo "ERROR: branch is $BEHIND commit(s) behind origin/$DEFAULT_BRANCH — fast-forward impossible" >&2
  echo "       rebase してから再実行:  git rebase origin/$DEFAULT_BRANCH" >&2
  exit 1
fi

echo ">>> fast-forward push: $BRANCH ($AHEAD commit) → $REPO/$DEFAULT_BRANCH"
git push origin "HEAD:$DEFAULT_BRANCH"

# --- 6. CI run ID 取得 (push trigger は数秒遅延) ---
sleep 3
RUN_ID=""
for i in 1 2 3 4; do
  RUN_ID=$(gh run list -R "$REPO" --branch "$DEFAULT_BRANCH" --limit 1 --json databaseId,headSha -q ".[0] | select(.headSha==\"$(git rev-parse HEAD)\") | .databaseId" 2>/dev/null || echo "")
  [[ -n "$RUN_ID" ]] && break
  echo "CI run not visible yet, retry $i/4..."
  sleep 4
done

MAIN_ROOT=$(git rev-parse --path-format=absolute --git-common-dir | sed 's|/\.git$||')

if [[ -n "$RUN_ID" ]]; then
  echo "CI: https://github.com/$REPO/actions/runs/$RUN_ID"
  echo "WATCH_CMD=gh run watch $RUN_ID -R $REPO --exit-status || echo '⚠️ CI FAILED on $DEFAULT_BRANCH ($REPO): gh run view $RUN_ID -R $REPO でログ確認 → revert or fix-forward を判断'"
else
  echo "WARNING: CI run not found (workflow が無い repo か、まだ表示されていない)"
fi

# --- 7. worktree auto-cleanup ---
if [[ "$SCRIPT_CWD" == */.claude/worktrees/* ]]; then
  WT_ROOT=$(echo "$SCRIPT_CWD" | sed 's|\(.*\.claude/worktrees/[^/]*\).*|\1|')
  cd "$MAIN_ROOT" 2>/dev/null || true
  git worktree remove "$WT_ROOT" --force 2>/dev/null && echo "CLEANUP: worktree removed ($WT_ROOT)"
  [[ -n "$BRANCH" ]] && git branch -D "$BRANCH" 2>/dev/null && echo "CLEANUP: branch deleted ($BRANCH)"
fi

echo "DONE: $REPO@$DEFAULT_BRANCH fast-forwarded $AHEAD commit(s)"
