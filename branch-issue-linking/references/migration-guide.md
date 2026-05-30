# 既存 repo の移行手順

`feat-/fix-/refactor-/infra-` 系の旧命名規則から `<N>-<type>-<desc>` への切替。

## 原則

**走行中の branch を強制 rename しない**。新規 branch から本規約を適用し、
旧 branch は merge / close まで放置する。rename すると open PR が壊れる。

## 手順

### 1. CLAUDE.md 更新

repo の `CLAUDE.md` に [`claude-md-template.md`](claude-md-template.md) の
セクションを追記する。既存の `## Worktree / branch 命名規則` セクションが
あれば置き換える。

```bash
cd /path/to/repo
$EDITOR CLAUDE.md
# - Worktree / branch 命名規則
# - PR description / commit message のキーワード
# - release / close フロー
# を貼り付ける
```

### 2. PR テンプレート配置

```bash
mkdir -p .github
cp ~/.claude/skills/branch-issue-linking/references/pull-request-template.md \
  .github/pull_request_template.md
# 必要に応じて `npm test` 等を repo の実コマンドに置き換える
```

PR テンプレートは新規作成 PR の description 初期値に入る。既存 PR には
反映されない。

### 3. サーバサイド検証 workflow 配置 (推奨)

```bash
mkdir -p .github/workflows
cp ~/.claude/skills/branch-issue-linking/references/validate-branch-pr.yml \
  .github/workflows/validate-branch-pr.yml
```

branch protection で `Validate Branch & PR / validate` を required check に
追加すると、規約違反 PR が auto-merge できなくなる。

### 4. CHANGELOG 設定 (該当 repo のみ)

git-cliff / release-please を使っている repo は `Refs #N` を拾うように
設定を更新する。詳細は [`changelog-config.md`](changelog-config.md)。

### 5. ローカル hook 登録 (個人環境)

`~/.claude/settings.json` に `worktree-naming-guard.sh` を登録:

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

## 通知

repo 内で複数人が作業している場合、移行 PR の description に「以降の新規
branch は `<N>-<type>-<desc>` 形式を使うこと」「`Closes`/`Fixes` 系は使わず
`Refs` を使うこと」を明記する。

## チェックリスト

- [ ] `CLAUDE.md` に 3 セクション追記
- [ ] `.github/pull_request_template.md` 配置
- [ ] `.github/workflows/validate-branch-pr.yml` 配置 (推奨)
- [ ] branch protection で `validate` を required check に追加 (推奨)
- [ ] CHANGELOG 設定の `Refs` 対応 (該当時)
- [ ] チームへの移行通知
