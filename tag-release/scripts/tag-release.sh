#!/usr/bin/env bash
# tag-release.sh — セマンティックバージョニングでタグ作成・push
# Usage:
#   tag-release.sh [patch|minor|major] [message]            対話プロンプトあり
#   tag-release.sh [patch|minor|major] [message] --yes      プロンプトスキップ
#   tag-release.sh [patch|minor|major] --repo <owner/name>  remote と一致確認
#   tag-release.sh --dry-run [patch|minor|major]            何もせずプレビューだけ
set -euo pipefail

# --- 引数パース ---
BUMP="patch"
MESSAGE=""
YES=0
DRY_RUN=0
EXPECT_REPO=""

while [ $# -gt 0 ]; do
  case "$1" in
    patch|minor|major) BUMP="$1" ;;
    --yes|-y) YES=1 ;;
    --dry-run|-n) DRY_RUN=1 ;;
    --repo) shift; EXPECT_REPO="${1:-}" ;;
    -h|--help)
      sed -n '2,8p' "$0" | sed 's/^# //'
      exit 0
      ;;
    *)
      if [ -z "$MESSAGE" ]; then MESSAGE="$1"; else MESSAGE="$MESSAGE $1"; fi
      ;;
  esac
  shift
done

# --- コンテキスト収集 ---
if ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: not inside a git repository (cwd: $(pwd))" >&2
  exit 1
fi

REPO_ROOT=$(git rev-parse --show-toplevel)
REMOTE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
REPO_SLUG=$(echo "$REMOTE_URL" | sed -E 's#(git@[^:]+:|https?://[^/]+/)##; s#\.git$##')

git fetch --tags --quiet
git fetch origin main --quiet 2>/dev/null || true

LATEST=$(git tag -l 'v*' --sort=-v:refname | head -1)
if [ -z "$LATEST" ]; then
  MAJOR=0; MINOR=0; PATCH=0
else
  VERSION="${LATEST#v}"
  IFS='.' read -r MAJOR MINOR PATCH <<< "$VERSION"
fi

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  *) echo "Usage: $0 [patch|minor|major] [message] [--yes] [--dry-run] [--repo owner/name]"; exit 1 ;;
esac
NEW_TAG="v${MAJOR}.${MINOR}.${PATCH}"
[ -z "$MESSAGE" ] && MESSAGE="Release ${NEW_TAG}"

BRANCH=$(git branch --show-current)
ORIGIN_HEAD_SHA=$(git rev-parse --short origin/main 2>/dev/null || echo "?")
ORIGIN_HEAD_SUBJECT=$(git log -1 --pretty=format:'%s' origin/main 2>/dev/null || echo "?")

# --- プリフライト表示 ---
cat <<EOF
============================================================
  Tag release preflight
============================================================
  cwd          : $(pwd)
  repo root    : ${REPO_ROOT}
  remote (URL) : ${REMOTE_URL:-<none>}
  repo slug    : ${REPO_SLUG:-<unknown>}
  branch       : ${BRANCH}
  latest tag   : ${LATEST:-<none>}
  new tag      : ${NEW_TAG}  (bump: ${BUMP})
  message      : ${MESSAGE}
  target       : origin/main @ ${ORIGIN_HEAD_SHA} "${ORIGIN_HEAD_SUBJECT}"
============================================================
EOF

# --- リポジトリ一致チェック ---
if [ -n "$EXPECT_REPO" ] && [ "$REPO_SLUG" != "$EXPECT_REPO" ]; then
  echo "ERROR: --repo mismatch: expected '$EXPECT_REPO', got '$REPO_SLUG'" >&2
  echo "Aborting to prevent tagging the wrong repository." >&2
  exit 2
fi

# --- main ブランチ警告 ---
if [ "$BRANCH" != "main" ]; then
  echo "WARNING: current branch is '$BRANCH', not 'main' (tag は origin/main に打たれます)"
fi

# --- dry-run ---
if [ "$DRY_RUN" -eq 1 ]; then
  echo "[dry-run] would: git tag -a $NEW_TAG -m \"$MESSAGE\" origin/main && git push origin $NEW_TAG"
  exit 0
fi

# --- 確認 ---
if [ "$YES" -ne 1 ]; then
  if [ -t 0 ]; then
    read -p "Push tag ${NEW_TAG} to ${REPO_SLUG}? [y/N] " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }
  else
    echo "ERROR: stdin is not a TTY — pass --yes (or --dry-run) to proceed non-interactively." >&2
    echo "Hint: verify 'repo slug' above matches the intended repository before re-running with --yes." >&2
    exit 3
  fi
fi

# --- 実行 ---
git tag -a "$NEW_TAG" -m "$MESSAGE" origin/main
git push origin "$NEW_TAG"
echo "Pushed ${NEW_TAG} to ${REPO_SLUG}"

# --- CI 確認 ---
if command -v gh &>/dev/null; then
  echo "CI: gh run list --limit 1"
  gh run list --limit 1 || true
fi
