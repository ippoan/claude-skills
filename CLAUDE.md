# CLAUDE.md — ippoan/claude-skills

`ippoan` プロジェクト共有の Claude Code スキル集。各スキルは `SKILL.md` を持つ
ディレクトリ単位。利用者向け full reference は [`README.md`](./README.md)。

## repo-policy

- branch: `claude/<topic>` または `<issue-number>-<type>-<short-desc>`。main 直 push
  禁止、PR 経由。
- PR / commit に `Closes` / `Fixes` / `Resolves #N` を使わない。**`Refs #N`**
  (auto-close させない。release 時に手動 close)。
- 新規スキル追加時は **`README.md` の一覧にも 1 行追記**する (置き場 2 系統どちらも)。

## ビルド / テスト

この repo 自体にビルドステップは無い。skill ロードは `claude-hooks` の
`session-start-install-skills.sh` が行う。

詳細 (スキルの置き場 2 系統・スキルの探し方・まず読む map・Fable/Opus 開発ループ) は
`claude-skills-map` skill を参照。
