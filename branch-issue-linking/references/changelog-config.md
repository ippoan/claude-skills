# CHANGELOG 生成設定の例

`Refs #N` / `Related to #N` / `Part of #N` を CHANGELOG の link として
拾う設定例。

## git-cliff (`cliff.toml`)

```toml
[git]
# Conventional Commits の prefix で section 分け
commit_parsers = [
  { message = "^feat",     group = "Features" },
  { message = "^fix",      group = "Fixes" },
  { message = "^refactor", group = "Refactor" },
  { message = "^infra",    group = "Infra" },
  { message = "^docs",     group = "Docs" },
  { message = "^chore",    skip = true },
]

# body 中の "Refs #N" / "Related to #N" / "Part of #N" を link 化
# (REPO は cliff 起動時に環境変数 or template で渡す)
link_parsers = [
  { pattern = "Refs #(\\d+)",       href = "https://github.com/$REPO/issues/$1" },
  { pattern = "Related to #(\\d+)", href = "https://github.com/$REPO/issues/$1" },
  { pattern = "Part of #(\\d+)",    href = "https://github.com/$REPO/issues/$1" },
]
```

template 側でも `{{ message }}` の中の `Refs #N` を保持しておけば、
GitHub Release notes に表示される link になる。

## release-please

`release-please` 自体は `Closes` / `Fixes` を強制しない。`Refs #N` は
そのまま CHANGELOG entry に転記されるため、**設定変更なしで運用可能**。

release-please による自動 close を抑止したい場合は、`release-as` PR の
template から auto-close キーワードが入らないようにする:

```yaml
# .release-please-config.json
{
  "pull-request-header": "PR description: Refs #N only. Auto-close keywords (Closes/Fixes/Resolves) are prohibited.",
  ...
}
```

## semantic-release

`@semantic-release/release-notes-generator` のデフォルト preset
(`conventional-changelog-angular`) は `Closes #N` を auto-close リンクとして
扱う。本規約と衝突するため、preset を `conventionalcommits` に切替するか、
`presetConfig.issuePrefixes` で `Refs` を含む別 prefix を追加する。

```json
{
  "plugins": [
    ["@semantic-release/release-notes-generator", {
      "preset": "conventionalcommits",
      "presetConfig": {
        "issuePrefixes": ["Refs ", "Related to ", "Part of "]
      }
    }]
  ]
}
```

注意: semantic-release は通常 commit に `Closes` を自動付加しないが、
コミット messa に書かれた `Closes` は CHANGELOG 中に display する。
auto-close 自体は GitHub 側の処理なので、PR description だけ気を付ければ
release-please / git-cliff と同じ運用ができる。

## tag-release.yml (workflow_dispatch)

本規約と組み合わせて使う想定の release workflow。`/tag-release` skill が
これを呼ぶ:

```yaml
name: tag-release
on:
  workflow_dispatch:
    inputs:
      bump:
        type: choice
        options: [patch, minor, major]
        default: patch
jobs:
  tag:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - name: bump and tag
        run: |
          LATEST=$(git tag --sort=-creatordate | head -1)
          # ... bump logic ...
          git tag -a "$NEW_TAG" -m "release: $NEW_TAG"
          git push origin "$NEW_TAG"
      # CHANGELOG 生成 → GitHub Release
      - uses: orhun/git-cliff-action@v3
        with:
          config: cliff.toml
          args: --latest --strip header
        env:
          REPO: ${{ github.repository }}
```

tag push → ci-dashboard で release 確認画面表示 → `Refs #N` 抽出 → 目視 close。
