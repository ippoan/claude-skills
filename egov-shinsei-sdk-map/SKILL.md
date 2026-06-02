---
name: egov-shinsei-sdk-map
generated-from: egov-shinsei-sdk:66028a2c49e4983b4d4a5f7b823577d357f07230
description: ippoan/egov-shinsei-sdk (TypeScript npm ライブラリ @ippoan/egov-shinsei-sdk、e-Gov 電子申請API v2 SDK) の構造ナビゲーション。EgovClient (全33エンドポイント)・OAuth2 PKCE・XML署名 (xmldsig:C14N/PFX/署名ブロック)・型定義・msw unit test / 手動 integration test の配置と CI 方針を 1 枚にまとめる。トリガー:「egov-shinsei-sdk」「電子申請API」「EgovClient」「e-Gov SDK」「PKCE」「XML署名」「xmldsig」「signKousei」「申請 submitApplication」「@ippoan/egov-shinsei-sdk」等。
---

# egov-shinsei-sdk-map — ippoan/egov-shinsei-sdk 構造ナビゲーション

**npm ライブラリ** (`@ippoan/egov-shinsei-sdk`, v0.1.0, ESM, tsup ビルド)。
e-Gov 電子申請API v2 の TypeScript SDK。Worker ではなく、`EgovClient` クラス +
OAuth2 PKCE + XML署名 (xmldsig) を提供する。

> 細部 (型・正確な行) は repo 側が正。ここは「どこを見るか」の索引。
> frontmatter の `generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す → その時 tree-sha を更新する。

## 区画 (src/)

| ファイル | 役割 |
|---|---|
| `src/index.ts` | public export (`EgovClient` / types / `EgovApiError` / `generatePKCE` / `buildAuthorizationUrl`) |
| `src/client.ts` | `EgovClient` クラス。**全 33 エンドポイント** (下記カテゴリ) |
| `src/types.ts` | 全型定義 (openapi.json 準拠、自作) |
| `src/errors.ts` | `EgovApiError` + `EgovReportItem` |
| `src/auth/pkce.ts` | `generatePKCE` (PKCE code_verifier/challenge) |
| `src/auth/oauth.ts` | `buildAuthorizationUrl` (`AuthorizationUrlParams`) |
| `src/xmldsig/c14n.ts` | `canonicalize` / `canonicalizeById` (C14N, XHTML 対応) |
| `src/xmldsig/pfx.ts` | `parsePfx` (PFX/PKCS#12 → key/cert) |
| `src/xmldsig/sign.ts` | `createSignatureBlock` / `insertSignatureIntoKousei` / `signKousei` / `signConfig` |
| `src/xmldsig/types.ts` | 署名オプション型 |

### `EgovClient` のエンドポイント分類 (`src/client.ts`)

| カテゴリ | メソッド |
|---|---|
| 認証 | `exchangeCode` `refreshToken` `introspectToken` `logout` `setAccessToken` |
| 申請 | `getProcedure` `getPreprint` `submitApplication` `bulkSubmitApplication` `amendApplication` `withdrawApplication` `checkFormat` |
| 状況照会 | `listApplications` `getApplication` `getErrorReport` |
| メッセージ/通知 | `listMessages` `getMessage` `listNotices` `getNotice` |
| 公文書 | `getOfficialDocument` `completeOfficialDocument` `verifyOfficialDocument` |
| 納付 | `listPaymentBanks` `getPaymentInfo` `displayPaymentSite` |
| 送付/郵送 | `applyPostDelivery` `getPostApplyStatus` `listPostDeliveries` `getPostDelivery` `completePostDelivery` |
| 情報共有設定 | `listShareSettings` `createShareSetting` `updateShareSetting` `deleteShareSetting` `confirmShareSetting` |

## entrypoint (`src/index.ts`)

`export { EgovClient }` + `export * from './types'` + `EgovApiError` +
`generatePKCE` + `buildAuthorizationUrl`。`package.json` の `main`/`types`/`module`
は `src/index.ts` (tsup で dist 生成)。

## gotcha (CLAUDE.md 由来)

- **spec は repo に含めない**: `spec/` 配下 (openapi.json / 申請データ XML 構造 / 構成情報タグ / FAQ / 試験手続ID) が実装の一次参照だが**公開リポジトリには含めない**。詳細索引は `spec/CLAUDE.md`。
- **CI は unit test (msw mock) のみ**。実 e-Gov API 直叩きの **integration test (33 件) は `workflow_dispatch` 手動起動のみ** (実 API 依存 + token rotation で CI が flakey になるため)。
- workflow: `test.yml` (push/PR → lib-ci.yml: typecheck + vitest+msw) / `publish.yml` (`v*` tag → lib-publish.yml: GitHub Packages publish) / `integration-test.yml` (手動) / `tag-release.yml` (手動 semver)。
- 統合テスト状況: 33 pass / 0 fail / 10 skip (32-36 情報共有は検証用 GビズID 必須、09-21 は到達番号収集待ち)。
- vitest config は 2 本: `vitest.config.ts` (unit) / `vitest.config.integration.ts`。`coverage_100.toml` あり。

## CCoW / CI から見た立ち位置

- **npm ライブラリ** (consumer 向け SDK)。GitHub Packages の `@ippoan` scope で publish。
- spec 取得は `egov-spec` skill、API 動作確認/デバッグは `egov-api` skill が担当。仕様書原本は ref-files (`egov-shinsei-sdk-spec` folder) 経由で取得 (`ref-files-bulk`)。

## 関連 skill

- `egov-api` — e-Gov API の動作確認 / OAuth フロー / 申請状況確認
- `egov-spec` — Developer Portal から仕様書/スキーマ取得
- `ref-files-bulk` — `egov-shinsei-sdk-spec` folder の一括取得
- `cross-repo-symbol-index` — per-repo map の運用方針 (鮮度 hook)
