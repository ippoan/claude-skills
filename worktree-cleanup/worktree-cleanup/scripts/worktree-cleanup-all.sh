#!/bin/bash
# 全リポジトリの worktree を一括確認・削除するスクリプト
# protected-repos.txt に登録されたリポジトリを対象
# マージ済みブランチの worktree を --force 削除、未マージは残す
#
# Usage: bash worktree-cleanup-all.sh [--dry-run]
#   --dry-run: 削除せず確認のみ

set -uo pipefail

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

CONF="$HOME/.claude/protected-repos.txt"
if [ ! -f "$CONF" ]; then
  echo "ERROR: $CONF not found"
  exit 1
fi

# protected-repos.txt からメインリポジトリだけ抽出 (worktree パスを除外)
REPOS=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  # .claude/worktrees/ を含むパスはスキップ
  [[ "$line" == *"/.claude/worktrees/"* ]] && continue
  [ -d "$line/.git" ] || [ -f "$line/.git" ] || continue
  REPOS+=("$line")
done < "$CONF"

TOTAL_REMOVED=0
TOTAL_KEPT=0
TOTAL_FAILED=0

for repo in "${REPOS[@]}"; do
  repo_name=$(basename "$repo")

  # worktree 一覧取得 (メイン以外)
  worktrees=$(git -C "$repo" worktree list --porcelain 2>/dev/null | grep '^worktree ' | grep '/.claude/worktrees/' | sed 's/^worktree //')

  [ -z "$worktrees" ] && continue

  echo "━━━ $repo_name ($repo) ━━━"

  # GitHub remote URL からオーナー/リポ名を取得
  remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null || echo "")
  gh_repo=""
  if [[ "$remote_url" =~ github\.com[:/](.+)\.git$ ]]; then
    gh_repo="${BASH_REMATCH[1]}"
  elif [[ "$remote_url" =~ github\.com[:/](.+)$ ]]; then
    gh_repo="${BASH_REMATCH[1]}"
  fi

  while IFS= read -r wt_path; do
    [ -z "$wt_path" ] && continue
    wt_name=$(basename "$wt_path")

    # ブランチ名取得
    branch=$(git -C "$wt_path" branch --show-current 2>/dev/null || echo "")
    [ -z "$branch" ] && branch="(detached)"

    # マージ済みか確認 (GitHub API)
    merged=false
    if [ -n "$gh_repo" ] && [ "$branch" != "(detached)" ]; then
      pr_state=$(gh pr list --repo "$gh_repo" --state merged --head "$branch" --json number --jq 'length' 2>/dev/null || echo "0")
      [ "$pr_state" -gt 0 ] 2>/dev/null && merged=true
    fi

    if $merged; then
      if $DRY_RUN; then
        echo "  WOULD REMOVE: $wt_name ($branch) — merged"
      else
        if git -C "$repo" worktree remove --force "$wt_path" 2>/dev/null; then
          # ローカルブランチも削除
          git -C "$repo" branch -D "$branch" 2>/dev/null || true
          echo "  REMOVED: $wt_name ($branch)"
          TOTAL_REMOVED=$((TOTAL_REMOVED + 1))
        else
          echo "  FAILED: $wt_name ($branch)"
          TOTAL_FAILED=$((TOTAL_FAILED + 1))
        fi
      fi
    else
      echo "  KEEP: $wt_name ($branch) — not merged"
      TOTAL_KEPT=$((TOTAL_KEPT + 1))
    fi
  done <<< "$worktrees"
  echo ""
done

echo "━━━ 結果 ━━━"
if $DRY_RUN; then
  echo "DRY RUN モード (実際の削除なし)"
fi
echo "削除: $TOTAL_REMOVED / 残存: $TOTAL_KEPT / 失敗: $TOTAL_FAILED"
