# CLAUDE.md — ippoan/claude-skills

`ippoan` プロジェクト共有の Claude Code スキル集。各スキルは `SKILL.md` を持つ
ディレクトリ単位。利用者向け full reference は [`README.md`](./README.md)。ここには
作業前に押さえるべき「どこに何があるか / どう探すか / まず読む map」だけを書く。

## スキルの置き場が 2 系統ある (重要)

スキルディレクトリは 2 箇所に割れている。install 時は **どちらも
`~/.claude/skills/` に symlink** される (`claude-hooks` の
`session-start-install-skills.sh`) ので動作は同じ。**人間が GitHub / `ls` で探す時
だけ注意** — repo トップだけ見ると `.claude/skills/` 配下が見えず「無い」と錯覚する。

| 置き場 | スキル |
|---|---|
| **repo 直下** (大多数) | `auth-worker-map/`, 各 `<repo>-map/`, `repo-map/`, `cross-repo-symbol-index/`, `pr-push/`, `coverage-*`, `egov-*`, `open-multirepo-smoke/` … |
| **`.claude/skills/` 配下** (5 個のみ) | `ippoan-infra-map`, `gh-actions-phantom-permission`, `large-codebase-setup`, `open-multirepo`, `ui-preview` |

この 2 系統への分裂は移行時の歴史的経緯で、**統一方針は未確定**。歴史的に直下が
多数派なので当面は直下に倣うのが無難 (Claude Code 標準パスは `.claude/skills/` の方)。
新規追加時はこの不統一を意識する。

## スキルの探し方

- 一覧: `README.md` の「スキル一覧」、または `ls -d */ .claude/skills/*/`
- キーワード検索: `grep -rl "キーワード" */SKILL.md .claude/skills/*/SKILL.md`
  (各 `SKILL.md` の frontmatter `description:` にトリガー語が入っている)

## まず読む map (infra / coverage 系を触る前に必読)

- **`ippoan-infra-map`** (`.claude/skills/ippoan-infra-map/`) — CCoW 基盤 5 repo
  (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) の
  **「どのロジックがどの repo に居るか」** の SoT。判断軸:
  **動作 (script 実体) = claude-hooks / 配線 (登録・配置・env) = claude-md**。
- **`cross-repo-symbol-index`** — 横断構造把握 + skill 鮮度 hook の設計 SoT。
  `generated-from` 規約 / coverage・鮮度 hook = claude-hooks
  `session-start-skill-coverage.sh` / claude-skills 自身は self-reference なので
  coverage 除外 (`CLAUDE_SKILL_COVERAGE_IGNORE`, claude-md の settings env) /
  空 repo は empty-tree-sha placeholder で被覆。
- **`repo-map`** — 単一 `<repo>-map` を作る / 更新する手順 (ローカル ctags +
  `generated-from: <repo>:<tree-sha>`)。coverage hook が uncovered / stale を
  警告した時に使う。

## repo-policy

- branch: `claude/<topic>` または `<issue-number>-<type>-<short-desc>`。main 直 push
  禁止、PR 経由。
- PR / commit に `Closes` / `Fixes` / `Resolves #N` を使わない。**`Refs #N`**
  (auto-close させない。release 時に手動 close)。
- 新規スキル追加時は **`README.md` の一覧にも 1 行追記**する (置き場 2 系統どちらも)。
