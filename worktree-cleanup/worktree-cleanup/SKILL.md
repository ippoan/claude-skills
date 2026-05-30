---
name: worktree-cleanup
description: |
  全リポジトリの .claude/worktrees/ を一括確認・削除するスキル。
  protected-repos.txt に登録された全リポジトリを走査し、GitHub PR のマージ状態を
  確認してマージ済み worktree を自動削除する。未マージは残す。
  トリガー: 「worktree 掃除」「worktree cleanup」「worktree 削除」
  「古い worktree」「stale worktree」「ワークツリー整理」等。
  /worktree-cleanup で呼び出し可能。
---

# Worktree Cleanup

`~/.claude/protected-repos.txt` に登録された全リポジトリの worktree を一括確認・削除する。

## Workflow

1. `--dry-run` で確認結果を表示
2. ユーザーに削除実行するか確認 (AskUserQuestion)
3. 承認後に `--dry-run` なしで実行

```bash
# 確認のみ
bash ~/.claude/skills/worktree-cleanup/worktree-cleanup/scripts/worktree-cleanup-all.sh --dry-run

# 実行
bash ~/.claude/skills/worktree-cleanup/worktree-cleanup/scripts/worktree-cleanup-all.sh
```
