---
name: tag-release
description: >
  Git タグでセマンティックバージョニングのリリースを実行するスキル。
  最新タグから patch/minor/major をインクリメントしてタグ作成・push する。
  トリガー: 「リリース」「release」「tag」「タグ」「バージョン」「version」
  「patch」「minor」「major」「デプロイ」「ver up」「バージョンアップ」等。
  /tag-release [patch|minor|major] で呼び出し可能。
---

# Tag Release

## 実行

```bash
bash ~/.claude/skills/tag-release/scripts/tag-release.sh [patch|minor|major] [message] [options]
```

**必ずプリフライトの `repo slug` を目視確認してから先に進むこと。** Bash tool 経由 (非 TTY) では `--yes` を渡さない限り exit 3 で停止する仕組み。

### オプション

- `--yes` / `-y` : 対話プロンプトをスキップ（非 TTY 環境では必須）
- `--dry-run` / `-n` : 何もせずプレビューだけ表示
- `--repo <owner/name>` : `git remote origin` の owner/name と一致しなければ exit 2 で中止。**別リポに誤タグを防ぐため、Claude 経由で実行する時は必須で付けること**
- デフォルト bump: `patch`
- タグなしなら `v0.0.0` から開始
- タグは常に `origin/main` に打つ（ローカル main が古くても安全）

### Claude 経由の推奨フロー

**cwd 漏れでの誤タグ事故があったため**、以下の 2 段階を厳守:

1. まず `--dry-run --repo <期待値>` でプリフライトだけ見る
   ```bash
   cd /path/to/repo && bash ~/.claude/skills/tag-release/scripts/tag-release.sh patch --dry-run --repo expected-owner/repo
   ```
2. プリフライトの `repo slug` がユーザーの意図したリポジトリと一致していることを確認してから `--yes --repo <同じ値>` で本実行
   ```bash
   cd /path/to/repo && bash ~/.claude/skills/tag-release/scripts/tag-release.sh patch --yes --repo expected-owner/repo
   ```

`--repo` 不一致なら exit 2、非 TTY で `--yes` 無しなら exit 3 で安全に止まる。

push 後に `gh run list` で CI を表示する。

## 罠 / Hard rules

<!-- migrated from memory/feedback_no_autonomous_tag_release.md (2026-05-11) -->
### tag-release は user prompt 必須 (Claude 自発実行は hook で機械ブロック)

`/tag-release` は **ユーザーが直接プロンプトに入力した時のみ実行可**。Claude 側からの:
- `Skill(skill="tag-release", ...)` 禁止
- `bash ~/.claude/skills/tag-release/scripts/tag-release.sh ...` 禁止
- `git tag -a v* + git push origin v*` 直接組み立て禁止

本番リリースしたい局面では「`/tag-release patch` を実行してください」と user に依頼する。

**hook (PreToolUse): `~/.claude/hooks/tag-release-userprompt-guard.sh`** が機械的にブロック。
直近 5 件の user 型 transcript に `/tag-release` または `<command-name>tag-release</command-name>`
が含まれる時のみ通す。settings.json の Bash + Skill 両 matcher に登録済 (2026-05-08)。

**Why:** タグは本番 deploy トリガー。Claude 自発判断で打つと不可逆なインフラ変更
(Cloud Run 新 revision、Worker 新バージョン) が発生する。2026-05-08 Phase 3 デプロイ中に
独断で `/tag-release patch` を 2 リポ連続実行 → 本番 deploy 即時発生の事故あり。

<!-- migrated from memory/feedback_wait_ci_before_tag.md (2026-05-11) -->
### タグを打つ前に main CI 通過を待つ

タグ push がデプロイトリガーなので、CI 未通過のままタグを打つと壊れたコードが本番にデプロイされる。
merge 後に `gh pr checks` / `gh run list` で main の全 pass を確認してからタグを打つ。
(`/tag-release` は user prompt 経由でしか動かないので、user 側の運用ルール)

## release 後の issue close フロー

tag 発行は **issue を auto-close しない** 運用 ([[branch-issue-linking]])。

1. `/tag-release patch` で tag push
2. ci-dashboard の release 確認画面で、tag に含まれる commit から `Refs #N` を
   抽出 → close 候補一覧表示
3. 目視確認後、ci-dashboard MCP server の `close_issue` tool で明示 close

PR description に `Closes #N` / `Fixes #N` / `Resolves #N` を書くと PR auto-merge
時点で issue が自動 close され、release タイミングの目視 UI と整合しない。
**`Refs #N` のみを使う**。詳細は [[branch-issue-linking]]。
