---
name: nuxt-pwa-carins-map
generated-from: nuxt-pwa-carins:b5814f401a26f140bf1bc90e106702636964ac5b
description: ippoan/nuxt-pwa-carins (車検証送信 Nuxt 3 PWA / Cloudflare Workers) の構造ナビゲーション。NFC で車検証 2D コードを読み取り rust-alc-api へ送る PWA。proxy/recieve server route・auth middleware・NFC composable の配置と wrangler prod/staging・既知の drift を 1 枚にまとめる。トリガー: 「nuxt-pwa-carins」「車検証」「carins」「NFC 車検証」「share_target」「useNfcTag」「carins.ippoan.org」等。
---

# nuxt-pwa-carins-map — ippoan/nuxt-pwa-carins 構造ナビゲーション

車検証 (2D コード) を NFC/カメラで読み取り rust-alc-api に送信する Nuxt 3 PWA。
Cloudflare Workers (`cloudflare-module` nitro preset) にデプロイ。トップレベル直下が
Nuxt root (app/ ディレクトリは無く `pages/` `components/` `server/` が直置き)。

> ここは索引。細部 (関数シグネチャ・行) は repo 側が正。
> frontmatter の `generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す → tree-sha を更新する。

## 区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `pages/index.vue` `pages/nfc.vue` | メイン / NFC 読み取り画面 |
| **components (車検証)** | `components/carIns/*` (CarName / Firstregistdate / Publishdate / TwodimensionCodeInfoValidPeriodExpirdate 等) | 車検証 2D コードのフィールド表示 |
| **components (機能)** | `NfcCarInspection.vue` `CarInspectionHistory.vue` `scan.vue` `list.vue` `login.vue` `button/download.vue` | NFC スキャン / 履歴 / ダウンロード / ログイン |
| **composables** | `useCarInspectionData.ts` `useFilesData.ts` `useFileUpload.ts` `useFileDownload.ts` `useNfcTag.ts` `useApiBackend.ts` `useAuth.ts` | データ取得 / ファイル / NFC / API backend 選択 / 認証 |
| **server route** | `server/api/proxy/[...path].ts` `server/api/recieve/index.ts` | rust-alc-api REST proxy / PWA share_target 受信 |
| **server 認証** | `server/middleware/auth.ts` + `server/utils/auth-logic.ts` `server/utils/proxy-logic.ts` | cookie 未認証なら auth-worker へ 302。LINE WORKS 自動ログイン (`?lw=`) |
| **types** | `types/alc-api.ts` `types/woff.d.ts` | rust-alc-api 型 / LINE WORKS WOFF 型 |
| **plugin** | `plugins/auth.client.ts` | client 側認証初期化 |

## entrypoint

- **nitro**: `nuxt.config.ts` → `nitro.preset = "cloudflare-module"`、`main = ./.output/server/index.mjs` (wrangler.toml)。
- **REST proxy**: `/api/proxy/*` → `${alcApiUrl}/api/*`。JWT を Authorization で転送し、payload の `tenant_id`/`org` を `X-Tenant-ID` にフォールバック設定。
- **share_target**: PWA manifest の `share_target.action = /api/recieve` (csv/json/pdf を POST 受信)。`file_handlers` で json/csv/pdf を直接開ける。
- **wrangler**: top-level = prod (`nuxt-pwa-carins`, carins.ippoan.org)。`[env.staging]` = `nuxt-pwa-carins-staging` (carins-staging.ippoan.org)。`[env.preview]` あり。`NUXT_ALC_API_URL` / `NUXT_PUBLIC_AUTH_WORKER_URL` を env ごとに切替。

## gotcha

- **README.md / CLAUDE.md は古い (drift)**: 「Connect RPC / gRPC / Cloud Run / logi-proto」と書いてあるが、**実コードは rust-alc-api への REST proxy** (`server/api/proxy/[...path].ts`、`runtimeConfig.alcApiUrl`、`apiBackend: 'rust-alc-api'`)。gRPC client / cloudrun-auth 等のファイルは現存しない。コードを正とする。
- `build.transpile: ['@ippoan/auth-client']` 必須 (auth-client は .vue/.ts をそのまま ship、ESM 解決のため transpile)。
- `@nuxt/ui` は **2.20.0 固定** (Nuxt 3 系)。Nuxt 4 系の trouble/alc-app とは別世代。
- HMR は `vite:extendConfig` hook で `wss` + `path: hmr/` + `clientPort: 443` を強制 (tunnel dev 用)。
- `nuxt-api-party` の `jsonPlaceholder` endpoint は CF Access ヘッダー付き (旧 hono-logi 名残の可能性)。

## CCoW/CI から見た立ち位置

- rust-alc-api を叩く consumer 群の 1 つ (alc-app / nuxt-trouble / nuxt_dtako_logs と同じ立ち位置)。認証は `@ippoan/auth-client` + auth-worker (auth.ippoan.org)。
- CI: `.github/workflows/` (frontend-ci 系)。test = `vitest run`、`tests/` に server/composables テストあり。

## 関連 skill

- `auth-worker-map` — `@ippoan/auth-client` / logi_auth_token cookie の発行元
- `nuxt-trouble-map` / `nuxt_dtako_logs-map` / `alc-app-map` — 同じ rust-alc-api consumer の兄弟 repo
- `repo-map` / `cross-repo-symbol-index` — この map の運用方針 (generated-from 鮮度)
