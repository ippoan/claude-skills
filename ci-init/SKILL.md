---
name: ci-init
description: >
  ippoan/ci-workflows の reusable workflow を使う CI ワークフロー (test.yml) を生成するスキル。
  プロジェクトタイプに応じたテンプレートを .github/workflows/test.yml に出力する。
  トリガー: 「CI初期設定」「ci-init」「CI セットアップ」「test.yml 作成」
  「ワークフロー生成」「GitHub Actions セットアップ」等。
  /ci-init [worker|nuxt] で呼び出し可能。
---

# CI Init スキル

ippoan/ci-workflows の frontend-ci.yml reusable workflow を使うプロジェクト向けに、
`.github/workflows/test.yml` を生成する。

## 使い方

```
/ci-init worker    # Cloudflare Workers プロジェクト
/ci-init nuxt      # Nuxt プロジェクト
/ci-init           # 引数なし → プロジェクト構成から自動判定
```

## 自動判定ロジック

引数がない場合、以下で判定:
- `wrangler.toml` or `wrangler.jsonc` が存在 → `worker`
- `nuxt.config.ts` が存在 → `nuxt`
- どちらもない → ユーザーに確認

## 生成ルール

### 必須 permissions (startup_failure 防止)

```yaml
permissions:
  contents: write        # auto-merge で必要
  pull-requests: write   # pr-limit, auto-merge で必要
  packages: read         # npm_scope 使用時
```

**これが不足すると CI が `startup_failure` になり、エラーメッセージなしでジョブが起動しない。**

### Worker テンプレート

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

permissions:
  contents: write
  pull-requests: write
  packages: read

jobs:
  ci:
    uses: ippoan/ci-workflows/.github/workflows/frontend-ci.yml@main
    with:
      install_command: 'npm install'
      typecheck_command: 'npx tsc --noEmit'
    secrets: inherit
```

### Nuxt テンプレート

```yaml
name: CI

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:
    branches: [main]

permissions:
  contents: write
  pull-requests: write
  packages: read

jobs:
  ci:
    uses: ippoan/ci-workflows/.github/workflows/frontend-ci.yml@main
    with:
      project_type: 'nuxt'
      working_directory: 'web'
    secrets: inherit
```

### カスタマイズ項目

生成後、プロジェクトに合わせて以下を追加・調整:

| 項目 | 設定例 | いつ追加するか |
|------|--------|--------------|
| `has_integration: true` | 統合テストあり | `docker-compose.test.yml` がある場合 |
| `post_install_script` | `npx wrangler types` | wrangler types や nuxt prepare が必要な場合 |
| `deploy_staging_script` | `npx wrangler deploy --env staging` | staging デプロイが必要な場合 |
| `deploy_release_script` | `npx wrangler deploy` | リリースデプロイが必要な場合 |
| `npm_scope: '@ippoan'` | GitHub Packages | `@ippoan` パッケージを使う場合 |
| `cache_dependency_path` | `web/package-lock.json` | monorepo で working_directory を使う場合 |
| `typecheck_command` | カスタム | 複数 tsconfig がある場合 |

### 既存 test.yml がある場合

上書きせず、差分を提示してユーザーに確認する。
特に `permissions` が不足していないかチェックし、不足があれば修正を提案する。

## 実行手順

1. プロジェクトタイプを判定 (引数 or 自動判定)
2. `.github/workflows/` ディレクトリの存在確認、なければ作成
3. 既存 `test.yml` の有無を確認
4. テンプレートを生成し、プロジェクト固有の設定を検出して追加:
   - `wrangler.toml`/`wrangler.jsonc` → `post_install_script: npx wrangler types`
   - `docker-compose.test.yml` → `has_integration: true`
   - `packages/` ディレクトリ → `npm_scope: '@ippoan'`
   - `web/` ディレクトリ (Nuxt) → `working_directory: 'web'`, `cache_dependency_path: 'web/package-lock.json'`
5. 生成内容をユーザーに確認してから書き込み