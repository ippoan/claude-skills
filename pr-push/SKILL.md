---
name: pr-push
description: >
  コミット済みの変更を push → PR 作成 → CI バックグラウンド監視まで一括実行するスキル。
  PR state チェック・main 禁止・未コミット検出をスクリプトで強制する。
  CI fail 後の修正 push 時も再実行すること（既存 PR はスキップし push + CI watch だけ行う）。
  gh pr create / gh run watch / gh run list を直接実行せず、常にこのスキル経由で行う。
  トリガー: 「PR」「push」「pr-push」「PRして」「プルリク」「CI確認」
  「push して PR」「変更を出して」「CI watch」「CI 監視」等。コード変更が完了した時に使用。
  /pr-push "タイトル" "本文" で呼び出し可能。
---

# PR Push

コミット済みの変更を push → PR 作成 → CI 監視を一括実行する。

## 実行

```bash
# 通常 (cwd がリポジトリ内)
bash ~/.claude/skills/pr-push/scripts/pr-push.sh "<title>" "<body>"

# worktree 内から実行 (cwd を worktree に移動してから)
cd /path/to/repo/.claude/worktrees/<name>
bash ~/.claude/skills/pr-push/scripts/pr-push.sh "<title>" "<body>"
```

スクリプトが出力する `WATCH_CMD` を `run_in_background: true` で実行し CI 完了を待つ。

## 手順

1. スクリプト実行 (push + PR 作成 + CI run ID 取得)
2. 出力の `WATCH_CMD=gh run watch ...` をバックグラウンドで実行
3. CI 完了通知を待つ。マージには一切触れない (auto-merge が自動処理)
4. CI fail 時はログ確認 → worktree で修正 → **再度このスキルを実行**

## CI fail 後の修正フロー

**重要: CI fail 後に追加コミットを push する時も、必ずこのスキルを再実行すること。**

スクリプトは既存 PR がある場合は PR 作成をスキップし、push + 新しい CI run ID 取得だけ行う。
`gh run watch` や `gh run list` を手動で実行せず、常にスクリプト経由で WATCH_CMD を取得する。

```bash
# worktree で修正 → コミット
cd .claude/worktrees/xxx
git add -A && git commit -m "fix: ..."

# 再度スキル実行 (PR は既にあるので push + CI watch だけ)
bash ~/.claude/skills/pr-push/scripts/pr-push.sh "同じタイトル" "同じ本文"
```

ただし初回実行で worktree が自動削除されるため、CI fail 時は新しい worktree を作る:

```bash
cd /path/to/main-repo
git worktree add .claude/worktrees/xxx origin/fix/xxx  # リモートブランチを checkout
# 修正 → コミット → スキル再実行
```

## Worktree ワークフロー

main に直接 push/merge してはいけない。必ず worktree でブランチを作り PR 経由でマージする。

branch / worktree 名は **`<issue-number>-<type>-<short-description>`** 形式
(規約詳細は [[branch-issue-linking]])。先に issue を立ててから worktree を作る。
claude-hooks の `worktree-naming-guard.sh` が登録されていれば、命名違反や
存在しない issue 番号は PreToolUse で deny される。

### worktree 作成

```bash
# 例: issue #123 (fix) の作業
git fetch origin main
git worktree add -b 123-fix-onedrive-token .claude/worktrees/123-fix-onedrive-token origin/main
```

### 作業 → PR

```bash
cd .claude/worktrees/123-fix-onedrive-token
# ... 編集・コミット ...
bash ~/.claude/skills/pr-push/scripts/pr-push.sh \
  "fix: onedrive token refresh" \
  "$(printf 'Refs #123\n\n%s\n' '<内容>')"
```

PR description / commit message では **`Refs #N` のみ** 使う
(`Closes` / `Fixes` / `Resolves` は禁止)。auto-close されると release 時の
目視 close UI と整合しないため。

### worktree クリーンアップ (PR マージ後)

```bash
# 必ずメインリポジトリに戻ってから削除
cd /path/to/main-repo
git worktree remove .claude/worktrees/123-fix-onedrive-token
git branch -d 123-fix-onedrive-token
```

### default branch が `master` の repo

`pr-push.sh` は `gh repo view --json defaultBranchRef.name` で base branch を
自動検出する。`main` / `master` どちらでも `gh pr create --base $BASE` で
正しく PR が作成される (claude-hooks repo は `master` default で運用)。

## PreToolUse フックによるガード

settings.json に登録された hooks が以下を自動ブロックする:

| フック | ブロック対象 | 理由 |
|---|---|---|
| `branch-switch-guard.sh` | `git checkout main` | worktree を使え |
| `worktree-fetch-guard.sh` | `git worktree add ... main` (ローカル) | `origin/main` を使え |
| `worktree-guard.sh` | cwd が worktree 内で `git worktree remove` | 先に cd でメインリポジトリに戻れ |
| `git-safe-push.sh` | `git commit --amend`, `git push --force` | 新コミット追加 + 通常 push |
| `pr-state-guard.sh` | MERGED/CLOSED ブランチへの push | 新ブランチを作れ |
| `no-local-merge.sh` | `gh pr merge` | auto-merge か Web UI を使え |
| `pr-push-allowlist-guard.sh` | allowlist repo での `pr-push.sh` 起動 | `/wt-direct-push` を使え |

### wt-direct-push allowlist repo は `/pr-push` 不可 (script 内蔵ガード)

`wt-direct-push/config/direct-push-ok.txt` に登録された repo (branch protection
無し / auto-merge 未設定) で `pr-push.sh` を実行すると、**script 自身が** owner/name
を解決して block し `/wt-direct-push` に誘導する (PreToolUse hook より確実な backstop)。

allowlist repo で PR を作ると auto-merge 無しで塩漬けになり、その間に tag-release が
古い main から build → release から changes が漏れる (Refs ippoan/github-mcp-server-rs#28)。
どうしても PR にしたい正当な理由がある場合のみ `PR_PUSH_ALLOW_ANY=1` を付けて再実行する。

## 禁止事項 (スクリプト + フックが自動ガード)

- main ブランチでの実行
- 未コミット変更がある状態での実行
- MERGED/CLOSED の PR ブランチへの push
- `git commit --amend` + `git push --force` (変更漏れの原因)
- ローカルからの `gh pr merge` (CI 未完了でマージされる危険)

## CI 監視と CI fail 後の対応 (運用ルール)

<!-- migrated from memory/feedback_pr_then_move_on.md + feedback_watch_background.md + feedback_no_ci_wait.md (2026-05-11) -->
### push 後は CI を BG で 1 回監視、user に fail 報告させない

push / PR 作成後は `gh run watch` 等を **バックグラウンドで 1 回だけ起動** して次の作業に進む。
ポーリングしない、`gh run watch` を foreground で待たない。CI 失敗を検知したらログを読んで
即修正 → 再 push。user に「fail だよ」と報告させるのは怠慢。

<!-- migrated from memory/feedback_local_test.md (2026-05-11) -->
### CI fail 後は再 push 前にローカルで通せ

カバレッジ / テスト等の CI 失敗後、修正 → push する前に **ローカルで `npx vitest run` /
`cargo test` を必ず通す**。CI 往復待ちは時間の無駄、同じ問題は再発しやすい。
カバレッジ 100% check がある場合は `npx vitest run --coverage` までローカル確認。

<!-- migrated from memory/feedback_auto_merge_required.md (2026-05-11) -->
### auto-merge は全 CI pass 後にのみ有効化

auto-merge は branch protection の **required checks のみ** を見る。required に入っていない
job が fail しても merge される。fail job がある段階で auto-merge を有効化しない、
全ジョブが pass する状態にしてから required に全ジョブを登録すること。
(nuxt-items で Type Check fail なのに auto-merge で merge された事故あり)

<!-- migrated from memory/feedback_pr_push_post_cleanup.md (2026-05-11) -->
### pr-push.sh 実行後は同一シェルで commit しない

`bash ~/.claude/skills/pr-push/scripts/pr-push.sh` 成功時に `CLEANUP: worktree removed` +
`pwd: error retrieving current directory` ログが出る。次の Bash tool 呼び出しは cwd が
**primary working dir** (例: `/home/yhonda/js/nuxt-notify`) にフォールバックする。
そのまま `git add -A && git commit` すると **他の worktree dir 全部を embedded git
submodule (`mode 160000`) として add** してしまい、main にゴミコミットができる。

- pr-push.sh 完了後の追加 commit は **新しい worktree を切る**
- どうしても primary dir で commit する必要があれば `git add -A` 禁止、`git add path/to/file` で個別追加
- `CLEANUP: worktree removed` を見たら次の Bash 最初に `pwd` or `cd /correct/path` を挟む
- `?? .claude/worktrees/...` が `git status` に出ている時点で gitlink 混入の前兆

<!-- migrated from memory/feedback_snapshot_drift_fix.md (2026-05-11) -->
### CI fail = `Snapshot Check / check` だけの時の復旧 (snapshot drift)

ippoan/ippoan-dev-plans の Issue が他 repo の作業で更新されると、本 PR の中身と無関係に
`manifests/production.snapshot.json` の `issues_last_updated_at` がずれて CI fail する。

```bash
npm install                               # 初回のみ
GITHUB_TOKEN=$(gh auth token) npm run snapshot
git add manifests/production.snapshot.json
git commit -m "chore(snapshot): refresh production.snapshot.json (drift fix)"
```

`dev-plans-snapshot: not found` → `npm install` が要る。
`GITHUB_TOKEN or GH_TOKEN env var required` → `gh auth token` で渡す。
`npm run snapshot:check` で `OK: snapshot up-to-date` を確認してから push。
auto-merge の必須 needs なのでこれを直さないと merge できない。
