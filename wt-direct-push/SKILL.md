---
name: wt-direct-push
description: >
  worktree でコミットした変更を default branch (main/master) に
  fast-forward 直 push して worktree を自動削除するスキル。
  branch-protection / auto-merge 未設定の repo (ippoan/ci-workflows, yhonda-ohishi/claude-hooks 等) 専用。
  許可 repo は wt-direct-push/config/direct-push-ok.txt にホワイトリスト登録、未登録 repo は /pr-push に誘導される。
  push 後は CI run watch を WATCH_CMD として返す。
  トリガー: 「直push」「direct push」「master 直接push」「main 直接push」「PR 抜きで push」
  「wt-direct-push」「worktree から直 push」「branch protection 無し」「auto-merge 無し repo」等。
  /wt-direct-push "コミットメッセージ" で呼び出し可能。
---

# wt-direct-push

worktree → default branch fast-forward 直 push 一括実行。`/pr-push` と mutually exclusive。

## 実行

```bash
# 既にコミット済みの場合 (引数なしで OK)
cd /path/to/repo/.claude/worktrees/<wt-name>
bash ~/.claude/skills/wt-direct-push/scripts/wt-direct-push.sh

# 未コミットを auto-commit してから push する場合
bash ~/.claude/skills/wt-direct-push/scripts/wt-direct-push.sh "feat: short title" "optional body"
```

スクリプトが出力する `WATCH_CMD=gh run watch ...` を `run_in_background: true` で実行し CI 完了を待つ。

## 手順

1. allowlist (`config/direct-push-ok.txt`) で repo を検証 — 無ければ `/pr-push` を案内
2. default branch (`gh repo view`) を取得
3. dirty 検出: 引数があれば auto-commit、無ければエラー
4. fast-forward 可能か確認 (`ahead>0` かつ `behind==0`)
5. `git push origin HEAD:<default-branch>`
6. CI run ID 取得 → WATCH_CMD 出力
7. worktree + branch を auto-cleanup

## allowlist の追加

```
# wt-direct-push/config/direct-push-ok.txt
ippoan/ci-workflows
yhonda-ohishi/claude-hooks
```

新 repo を直 push 許可リストに加えたい場合:
1. その repo に branch protection が無いことを確認
2. 上記ファイルに `owner/name` を 1 行追加
3. claude-skills の PR で merge

## 禁止事項 (スクリプトが自動ガード)

- default branch 上での実行 (worktree で作業せよ)
- allowlist 未登録 repo
- fast-forward 不可 (behind > 0) — rebase してから再実行
- 何もコミットされていない状態 (ahead == 0)

## /pr-push との使い分け

| ケース | 使うスキル |
|---|---|
| branch protection 有り / auto-merge 設定済 | `/pr-push` |
| branch protection 無し / auto-merge 未設定 (allowlist 登録済) | `/wt-direct-push` |
| 認証フロー / OAuth callback 等の Sensitive 変更 | 常に `/pr-push` (staging 確認したい) |

判断に迷ったら `/pr-push` (PR review を経る方が安全)。

## CI fail 後の対応

直 push 後の CI fail は **default branch (master/main) で fail** している状態。即対応が必要:

1. **revert**: `git revert <bad-sha>` して再度 `/wt-direct-push`
2. **fix-forward**: 新 worktree を切って fix commit → `/wt-direct-push`

WATCH_CMD は fail 時に "revert or fix-forward を判断" メッセージを出力する。

## 関連

- `/pr-push` — 通常 repo 用 (PR + auto-merge)
- 既存 direct-push-OK repo の根拠: global CLAUDE.md `feedback_ci_workflows_direct_push` 等
