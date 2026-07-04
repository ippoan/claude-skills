---
name: create-preview
description: >
  Cloudflare Workers 上の front repo (Nuxt/Worker) に「push するだけで更新される
  軽量プレビュー環境」を追加するスキル。wrangler.toml に [env.preview] を追加し、
  ci-workflows の preview-deploy.yml (test/typecheck 無し・deploy のみの軽量
  reusable workflow) を呼ぶ caller workflow を新設、CLAUDE.md に URL 表を追記する。
  backend は staging を再利用 (専用インフラを持たない)。CF Access は既存の
  *-preview.ippoan.org wildcard app が自動でカバーするので追加設定不要。
  トリガー: 「preview環境作って」「create-preview」「プレビュー環境追加」
  「push でプレビュー」「軽量デプロイ環境」等。
  /create-preview で呼び出し可能。
---

# create-preview スキル

ippoan/nuxt-trouble (Refs ippoan/secrets-inventory#85、PR #183/#184) で確立した
パターンを他の front repo に横展開するスキル。

## 設計思想

| 環境 | トリガー | 用途 |
|---|---|---|
| production | `v*` タグ push | 本番 |
| staging | PR (non-draft) への push | DB migration 等を伴う本格検証。既存の `frontend-ci.yml` の `deploy-staging` job がそのまま担う (変更不要) |
| **preview (本 skill が追加)** | 任意 branch (main 以外) への push | UI 変更の見た目確認。test/typecheck 無しの軽量パイプライン |

- **CF API Token・Cloudflare dashboard 手動設定・Workers Builds は一切不要**。
  既存の CI が持つ `CLOUDFLARE_API_TOKEN` を使い回す
- **backend は staging をそのまま再利用**。専用 DB・専用 backend は持たない
  (同時に複数プレビューを見る場合は staging 同様、状態を共有する前提を許容する)

## 前提条件

- 対象 repo が `wrangler.toml`/`wrangler.jsonc` を持つ (Cloudflare Workers project)
- `[env.staging]` が既に存在する (vars/secrets_store_secrets/services のコピー元)
- `.github/workflows/test.yml` 等が `ippoan/ci-workflows` の `frontend-ci.yml` を
  呼んでいる (staging deploy が既存で動いている)

## 実行手順

### 1. `wrangler.toml`/`wrangler.jsonc` に `[env.preview]` を追加

`[env.staging]` の内容をベースに、以下を変えて追記する:

```toml
[env.preview]
name = "<worker-name>-preview"
# custom_domain route を使うため workers.dev URL は明示的に無効化する
# (routes 定義時は自動的に false 推論されるが、明示して確実にする)。
workers_dev = false

[[env.preview.routes]]
pattern = "<short-name>-preview.ippoan.org"
custom_domain = true

[env.preview.vars]
# staging と同じ値をそのままコピー (staging backend を再利用するため)

# named env は top-level/他 env の binding を継承しないので再宣言が必要
[[env.preview.secrets_store_secrets]]
# staging と同じ binding/store_id/secret_name をコピー

[[env.preview.services]]
# staging と同じ binding/service をコピー
```

**`<short-name>-preview.ippoan.org` の命名規則を必ず守ること** — 後述の CF Access
wildcard app (`*-preview.ippoan.org`) が自動でカバーする前提のため、これ以外の
パターン (別ドメイン、別 suffix) にすると保護されない。

### 2. `.github/workflows/preview-deploy.yml` を新設

```yaml
name: Preview Deploy

# push のたびに軽量プレビュー環境を更新する。
# test/typecheck は回さない (UI 変更の見た目確認が主目的)。
# staging は既存どおり PR trigger で更新される (役割分離)。

on:
  push:
    branches-ignore: [main]

permissions:
  contents: read
  packages: read   # @ippoan/* GitHub Packages 依存がある場合は必須
                    # (無いと npm install が 403 になる、nuxt-trouble#183 実例)

jobs:
  preview:
    uses: ippoan/ci-workflows/.github/workflows/preview-deploy.yml@main
    with:
      install_command: 'npm install'
      post_install_script: '...'   # test.yml の post_install_script と揃える
      use_auth_client_dev: true    # @ippoan/auth-client 使用時のみ
      npm_scope: '@ippoan'          # GitHub Packages 使用時は必須
      # project_type: 'worker'      # project_type=worker の場合のみ (nuxt が default)
      # preview_deploy_script: '...' # auto デフォルトで足りない場合のみ override
    secrets: inherit
```

`test.yml` の `ci` job の `with:` を参照して `install_command` /
`post_install_script` / `use_auth_client_dev` / `npm_scope` を揃えること
(preview 用に別ロジックを考案しない)。

### 3. `CLAUDE.md` に URL 表を追記

```markdown
## 環境と URL

| 環境 | URL | 更新タイミング |
|---|---|---|
| production | https://<name>.ippoan.org | `v*` タグ push |
| staging | https://<name>-staging.ippoan.org | PR (non-draft) への push のたび |
| preview | https://<short-name>-preview.ippoan.org | 任意の branch (main 以外) への push のたび (test/typecheck 無し・deploy のみの軽量パイプライン) |

**preview は UI 変更の見た目確認が主目的** (backend は staging を再利用、専用 DB は持たない)。
DB migration 等の本格的な検証が必要な変更は PR を作成して staging で確認する。
```

### 4. CF Access (追加設定は基本不要)

`*-preview.ippoan.org` を保護する CF Access app **`preview-wildcard (allow me)`**
が既に存在する (staging の `staging-wildcard (allow me)` と同じ設計、policy は
共通の `me` reusable policy)。命名規則さえ守れば **repo ごとの CF Access 設定は
不要**。

新しい許可ポリシー (例: 特定の他メンバーにも preview を見せたい) が必要になった
場合のみ、`cf-access-mcp` の `list_access_policies` / `create_access_app` /
`protect_hostname` で調整する (`cf-access-mcp` skill 参照)。

### 5. デプロイ後の確認

```bash
# custom domain → CF Access ログインに 302 されること
curl -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://<short-name>-preview.ippoan.org/"

# workers.dev → 404 (無効化されていること)
curl -sS -o /dev/null -w "%{http_code}\n" "https://<worker-name>-preview.<workers-dev-subdomain>.workers.dev/"
```

## 既知の罠

- **`packages: read` permission 忘れ**: caller workflow の `permissions:` と
  reusable workflow (`ci-workflows/preview-deploy.yml`) の job-level
  `permissions:` の**両方**に必要。片方だけだと `@ippoan/*` 依存の `npm install`
  が 403 で失敗する (reusable workflow の job-level permissions は caller の
  許可と intersection されるため、reusable 側が宣言していないと caller が渡して
  も反映されない)
- **`workers_dev` の暗黙推論に頼らない**: `routes` を追加すると wrangler は
  `workers_dev = false` を自動推論するが、明示的に書いて確実にする
- **custom domain のドメインは `*-preview.ippoan.org` の命名規則から外れない**:
  外れると CF Access wildcard app の対象外になり、認証無しで公開されてしまう
- **branch 名は push トリガーの対象**: `on: push: branches-ignore: [main]` で
  main 以外の任意 branch が対象。PR の有無は問わない (PR を作らず push しただけ
  でも preview は更新される。staging は逆に PR がある時だけ更新される)

## 参考実装

- `ippoan/ci-workflows` の `.github/workflows/preview-deploy.yml`
- `ippoan/nuxt-trouble` の `wrangler.toml` (`[env.preview]`) / `.github/workflows/preview-deploy.yml` / `CLAUDE.md`
- Refs ippoan/secrets-inventory#85
