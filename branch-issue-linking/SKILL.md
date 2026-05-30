---
name: branch-issue-linking
description: >
  worktree branch ↔ GitHub issue の紐付け規約。
  形式 <issue-number>-<type>-<short-description> の strict 命名と
  `Refs #N` (auto-close させない) で release 時の目視 close フローを実現する。
  各 repo の CLAUDE.md / PR template / GitHub Actions / CHANGELOG 設定の雛形を提供。
  トリガー: 「branch 命名」「worktree 命名規則」「Refs」「issue 紐付け」「PR template」
  「auto-close 防ぐ」「branch-issue-linking」「release close 確認」等。
---

# Branch ↔ Issue Linking

worktree branch と GitHub issue を機械的に紐付け、PR auto-merge による
意図しない issue auto-close を防ぐ運用規約。

## 規約

### 1. branch / worktree 命名

形式: `<issue-number>-<type>-<short-description>`

- `type`: `feat` | `fix` | `refactor` | `infra`
- `issue-number`: 必須。先に issue を立ててから worktree を作る
- 正規表現: `^[0-9]+-(feat|fix|refactor|infra)-[a-z0-9-]+$`

例:
- `123-fix-onedrive-token`
- `145-feat-line-works-webhook`
- `156-refactor-pdf-generator`

### 2. 連携キーワード

| キーワード                        | 用途                       | auto-close |
| --------------------------------- | -------------------------- | ---------- |
| `Closes` / `Fixes` / `Resolves`   | **禁止**                   | する       |
| `Refs` / `Related to` / `Part of` | 推奨。Development に紐付く | しない     |

PR description / commit message とも上記を厳守。`Closes` 系は PR auto-merge
時点で issue を auto-close するため、release tag タイミングでの目視 close UI
と整合しない。

### 3. PR テンプレート

`.github/pull_request_template.md` で `Refs #` を雛形に入れて強制する。
雛形は [`references/pull-request-template.md`](references/pull-request-template.md)。

### 4. release / close フロー

1. PR merge: `Refs #N` のみで auto-close させない
2. tag 発行: `tag-release.yml` (workflow_dispatch、`/tag-release` skill 経由)
3. ci-dashboard の release 確認画面で tag に含まれる commit から
   `Refs #N` を抽出 → close 候補一覧
4. 目視確認 → ci-dashboard MCP `close_issue` tool で明示 close

## 機械的に守らせる仕組み

### ローカル (Claude Code PreToolUse hook)

`yhonda-ohishi/claude-hooks` の `worktree-naming-guard.sh` が
`git worktree add -b` / `git checkout -b|-B` / `git switch -c|-C` をフックし、
branch 名の正規表現一致と issue 実在 (closed 含む) を検証する。

設定例:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/worktree-naming-guard.sh" }
        ]
      }
    ]
  }
}
```

bypass env: `SKIP_BRANCH_VALIDATION=1` / `CLAUDE_HOOKS_SKIP_ISSUE_CHECK=1` /
`BRANCH_NAME_REGEX=...` / `CLAUDE_HOOKS_BRANCH_TYPES=feat,fix,...`。

### サーバサイド (GitHub Actions)

ローカル hook は bypass 可能なため、各 repo に PR 検証 workflow を併設する。
雛形は [`references/validate-branch-pr.yml`](references/validate-branch-pr.yml)。

## 適用

### 新規 repo

1. [`references/claude-md-template.md`](references/claude-md-template.md) を
   repo の `CLAUDE.md` に貼り付け
2. [`references/pull-request-template.md`](references/pull-request-template.md) を
   `.github/pull_request_template.md` に配置
3. [`references/validate-branch-pr.yml`](references/validate-branch-pr.yml) を
   `.github/workflows/validate-branch-pr.yml` に配置
4. CHANGELOG 生成設定があれば [`references/changelog-config.md`](references/changelog-config.md)
   の git-cliff / release-please 設定例で `Refs` 系キーワードを拾うようにする

### 既存 repo の移行

[`references/migration-guide.md`](references/migration-guide.md) を参照。
走行中の branch (`feat/xxx` 等の旧形式) は rename せず、新規 branch から
本規約を適用する。

## 罠 / Pitfalls

### `Closes` / `Fixes` / `Resolves` の auto-close

GitHub は PR description / commit message でこれらのキーワードに `#N` が
続くと、PR merge 時点で issue を **自動的に close** する。release tag 発行を
非同期 (`workflow_dispatch`) で行う運用では、merge 時 close と release タイミング
が噛み合わない。**`Refs #N` だけを使う**。

### `gh issue view <N> --repo <slug>` の exit code

GraphQL の `projects.classic` deprecation warning で、**存在する issue でも
exit 1** を返す (gh 側の既知バグ)。実在チェックには **`--json number` を必ず付ける**:

```bash
gh issue view "$N" --repo "$REPO" --json number >/dev/null 2>&1
```

これがないと「issue は存在するのに `worktree-naming-guard.sh` が deny する」
事故が起こる (本 hook 実装時に踏んだ罠)。

### ローカル hook の bypass リスク

`SKIP_BRANCH_VALIDATION=1` で全体 bypass できるため、サーバサイド検証
workflow を併設しないと運用が緩む。`references/validate-branch-pr.yml` を
全 repo に配置するのを徹底。

### 走行中 branch の rename

`feat/xxx` 形式の走行中 branch を強制 rename すると open PR が壊れる。
**新規 branch のみ** 本規約を適用し、既存は merge / close まで放置する。

## 関連

- hook 実装: [yhonda-ohishi/claude-hooks](https://github.com/yhonda-ohishi/claude-hooks)
  の `worktree-naming-guard.sh`
- release 時の close 確認 UI (受け皿): ippoan/ci-dashboard#35
- ドッグフード実装: ippoan/ci-dashboard#30 (merged)
- 関連 skill: [[pr-push]], [[wt-quick]], [[check-issue]], [[tag-release]]
