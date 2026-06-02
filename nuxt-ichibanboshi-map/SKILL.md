---
name: nuxt-ichibanboshi-map
generated-from: nuxt-ichibanboshi:7683c71ee007df8e54e02586cb7291b1bc6259c3
description: ippoan/nuxt-ichibanboshi (一番星 売上分析ダッシュボード、Nuxt 4 SPA + Cloudflare Workers) の構造ナビゲーション。ECharts の売上チャート群 / sales API プロキシ / CF Access Service Token + auth-worker tenant gate の配置を 1 枚にまとめる。トリガー:「ichibanboshi」「一番星」「売上分析」「ECharts」「sales API」「CF Access Service Token」「by-customer」「yoy」「ichibanboshi.ippoan.org」等。
---

# nuxt-ichibanboshi-map — ippoan/nuxt-ichibanboshi 構造ナビゲーション

一番星 売上分析ダッシュボード。Nuxt 4 (`ssr: false` SPA) + Nitro `cloudflare_module`。
ECharts で売上を可視化。backend (`rust-ichiban`) を `server/api/sales/` プロキシ経由で叩き、
プロキシは CF Access Service Token を付与する。

> 細部は repo 側が正。ここは索引。`generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す。

## 区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `app/pages/{index,customers}.vue` `customer/[code].vue` `month/[ym].vue` | サマリ / 顧客一覧 / 顧客別詳細 / 月別詳細 |
| **components (chart)** | `app/components/{Daily,Monthly,Department,Yoy}SalesChart.vue` `Customer{SalesChart,BarRace,BumpChart,StackedArea,ThemeRiver,YoyRanking}.vue` | ECharts 各種売上チャート |
| **composables** | `app/composables/{useAuth,useSalesData,useChartYMaxLock,useYoyDisplayMode}.ts` | 認証 / 売上データ取得 / Y軸固定 / 前年比表示モード |
| **server/api (sales)** | `server/api/sales/{daily,monthly,yoy,by-customer,by-department,customer-detail,customer-trend,customer-yoy,customer-yoy-by-dept,departments}.get.ts` | backend への売上集計プロキシ |
| **server (auth)** | `server/middleware/auth.ts` `server/utils/{auth-logic,salesApi}.ts` | JWT gate / 認証ロジック / sales backend クライアント (CF Access token 付与) |
| **utils** | `app/utils/format.ts` | 数値/通貨 整形 |

## entrypoint

- nuxt.config: `ssr: false` (SPA)、`nitro.preset = cloudflare_module`、modules `@nuxtjs/tailwindcss`、`transpile: ['echarts','vue-echarts','@ippoan/auth-client',...]`。
- wrangler.toml: top-level=prod (`nuxt-ichibanboshi`, ichibanboshi.ippoan.org) / `[env.staging]`=staging。
- vars: `NUXT_SALES_API_BASE` (rust-ichiban)、`NUXT_PUBLIC_ALC_API_BASE`、`NUXT_PUBLIC_AUTH_WORKER_URL`、`NUXT_CF_ACCESS_CLIENT_ID`。secret `NUXT_CF_ACCESS_CLIENT_SECRET` は `wrangler secret`。

## gotcha (wrangler.toml 由来)

- **sales backend は CF Access で保護**。`server/utils/salesApi.ts` が `CF-Access-Client-Id/Secret` を付与して叩く。prod (`44252f05...access`) と staging (`2a71ff20...access`) は **独立した Service Token**。両方を CF Access Application allowlist に登録済。
- **tenant gate は auth-worker 側に集約済** (`APP_TENANT_ACL` + `bypass_emails`)。staging では `NUXT_ALLOWED_TENANT_ID` secret は削除済 — フロント側に tenant 制御を足し直さない。
- staging の `NUXT_PUBLIC_ALC_API_BASE` は rust-alc-api-staging Cloud Run を直に指す (prod は alc-api.ippoan.org)。
- CLAUDE.md 無し (運用ルールは wrangler.toml のコメントが主)。

## CCoW / CI から見た立ち位置

- consumer 側。`@ippoan/auth-client` (^0.2.28) で JWT。backend は別 (rust-ichiban / rust-alc-api) を CF Access + JWT で叩く。

## 関連 skill

- `auth-worker-map` — JWT 発行元 + tenant gate (`APP_TENANT_ACL`) の集約先
- `nuxt-vitest` — composable/utils のテスト
- `cross-repo-symbol-index` `ippoan-infra-map` — 横断 symbol / 基盤地図
