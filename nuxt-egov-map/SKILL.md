---
name: nuxt-egov-map
generated-from: nuxt-egov:2ad9dc78dd1c8c3b6b2af45ac97e39c27e100b94
description: ippoan/nuxt-egov (e-Gov 電子申請 検証ツール、Nuxt 4 + Cloudflare Workers) の構造ナビゲーション。OAuth2 認証 / 申請送信 / kousei.xml 構築 / XML 署名 (xmldsig) / e-Gov API プロキシの配置を 1 枚にまとめる。トリガー:「nuxt-egov」「egov-check」「e-Gov 電子申請」「最終確認試験」「kousei.xml」「xmldsig」「egov-shinsei-sdk」「final-test」「個別署名形式」「egov-check.ippoan.org」等。
---

# nuxt-egov-map — ippoan/nuxt-egov 構造ナビゲーション

e-Gov 電子申請 API のチェックツール。Nuxt 4 + Nitro `cloudflare_module`。
`@ippoan/egov-shinsei-sdk` (GitHub Packages) で OAuth2 + 申請を扱い、CORS 回避のため
e-Gov API は `server/api/egov/` プロキシ経由で叩く。e-Gov は **検証環境 (sbx)** を使用。

> 細部は repo 側が正。ここは索引。`generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す。

## 区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `app/pages/{index,final-test,documents,callback}.vue` | 申請一覧(状況確認) / 最終確認試験(送信・記録) / 公文書ビューア / OAuth callback |
| **composables** | `app/composables/{useEgovAuth,useDocumentViewer,useXmlSign}.ts` | OAuth2 認証 (SDK 使用) / 公文書表示 / XML 署名 |
| **utils (XML 署名)** | `app/utils/xmldsig/{c14n,pfx,sign,types}.ts` | C14N 正規化 / PFX(PKCS12) 読込 / xmldsig 署名生成 |
| **utils (手続定義)** | `app/utils/finalTestProcedures.ts` | 最終確認試験の手続リスト・テスト値構築 |
| **server/api (e-Gov proxy)** | `server/api/egov/{[...path],token.post,introspect.post,logout.post}.ts` | e-Gov API 透過プロキシ / token / introspect / logout |
| **server/api (spec/sdk)** | `server/api/{sdk-state.get,spec-test-data.{get,post}}.ts` | SDK 状態 / spec テストデータ |
| **workers/egov** | `workers/egov/src/index.ts` | client_secret を持つ別 Worker (`egov-staging`)。`EGOV_CLIENT_SECRET` binding |

## entrypoint

- nuxt.config: `nitro.preset = cloudflare_module`。
- wrangler.jsonc: top-level=prod (`egov-check`, egov-check.ippoan.org) / `[env.staging]`=staging (egov-check-staging)。`compatibility_flags=["nodejs_compat"]`。
- vars: `NUXT_PUBLIC_EGOV_{CLIENT_ID,REDIRECT_URI,AUTH_BASE,API_BASE}`。secret は `NUXT_EGOV_CLIENT_SECRET` のみ (`wrangler secret`)。
- e-Gov 検証環境: API `api2.sbx.e-gov.go.jp/shinsei/v2`、auth `account2.sbx.e-gov.go.jp/auth`。

## gotcha (CLAUDE.md 由来)

- **kousei.xml**: 全 49 手続で同一構造 (空タグ 30 個)。`kouseiTestValues` で必須を埋める。郵便番号/電話は半角のまま (全角化すると e-Gov マスタチェックで弾かれる)、住所は全角。
- **個別署名形式 (No.23〜49)**: 構成管理 XML に署名値が無いのが標準形式との最大の違い。様式 ID スワップ (WriteAppli 001↔009, SignAttach 009↔001) が必須 — 片方だけだと「不正」エラー。
- No.22 (電子送達) は `/post-apply`、それ以外は `/apply`。必須添付の手続は `dummy.txt` を添付。
- spec は `spec/` (`.gitignore` 対象)、`egov-spec` skill で取得。
- ローカル確認は worktree で build → `wrangler dev` → Cloudflare Tunnel `test-nuxt.ippoan.org`。メイン wt では build しない (hook がソース編集禁止)。CDP debug は `window._egovToken` でトークン取得可。
- README.md は Nuxt の boilerplate (実態は CLAUDE.md が正)。

## CCoW / CI から見た立ち位置

- consumer 側。**`@ippoan/auth-client` は使わない** (認証は e-Gov OAuth2 を SDK 経由で直接扱う)。`.npmrc` で `@ippoan:registry=https://npm.pkg.github.com` 必須。
- CI: ci-workflows reusable workflow。PR で staging 自動デプロイ、tag push で prod。

## 関連 skill

- `egov-api` — e-Gov 電子申請 API の動作確認・デバッグ
- `egov-spec` — e-Gov Developer Portal から仕様書/スキーマ取得
- `nuxt-vitest` `worker-vitest` — Nuxt / workers/egov のテスト
- `cross-repo-symbol-index` `ippoan-infra-map` — 横断 symbol / 基盤地図
