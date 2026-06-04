---
name: nuxt-trouble-map
generated-from: nuxt-trouble:3def7ad6c810759022fa60f3809d840e1d0171ea
description: ippoan/nuxt-trouble (トラブル/状況管理 Nuxt 4 アプリ / Cloudflare Workers) の構造ナビゲーション。rust-alc-api `/api/troubles` を叩くチケット・タスク・ワークフロー管理 SPA。pages/composables/utils と ts-rs 生成型の配置、2 対応者フィールドの罠を 1 枚にまとめる。トリガー:「nuxt-trouble」「トラブル管理」「状況管理」「チケット」「trouble_tasks」「assigned_to」「next_action_by」「ワークフロー」「ガントチャート」「trouble.ippoan.org」等。
---

# nuxt-trouble-map — ippoan/nuxt-trouble 構造ナビゲーション

トラブル (状況) 管理アプリ。Nuxt 4 (`app/` ディレクトリ構成) + Cloudflare Workers。
rust-alc-api の `/api/troubles` 系を叩く SPA。server route は無く (proxy せず) フロントが
`app/utils/api.ts` から直接 rust-alc-api を fetch する。

> ここは索引。細部 (関数シグネチャ・行) は repo 側が正。
> frontmatter の `generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す → tree-sha を更新する。

## 区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `app/pages/index.vue` `tickets/{index,[id],new,situations,waiting}.vue` `tasks.vue` `settings.vue` `login.vue` `auth/callback.vue` | チケット一覧/詳細/新規/状況/待ち、タスク、設定、認証 |
| **composables** | `useTicketList.ts` `useTicketDetail.ts` `useTicketNew.ts` `useTaskStatuses.ts` `useCarInspections.ts` `useAppInit.ts` `useAuth.ts` | チケット・タスク・車検証・初期化・認証 |
| **components** | `Ticket*.vue` (FormFields / TaskList / TaskCard / StatusHistory / StatusTransition / GanttChart / CategoryBadge / CompactOverview / Files) `WorkflowManager.vue` `MasterDataManager.vue` `BulkImportModal.vue` `Ymd(t)Input.vue` | チケット UI / ワークフロー / マスタ / 一括取込 / 日付入力 |
| **utils** | `app/utils/api.ts` (API client) `datetime.ts` `normalize.ts` `excel-import.ts` `carInspection.ts` | API 呼び出し本体 / 日付 / 正規化 / Excel 取込 |
| **型 (生成)** | `app/types/generated/*` (Trouble* 系: Ticket/Task/Category/Office/ProgressStatus/Workflow* 等) + `app/types/index.ts` | rust-alc-api models.rs から **ts-rs 自動生成**。手動編集しない |
| **middleware / layout** | `app/middleware/auth.global.ts` `app/layouts/{default,auth}.vue` | 全ルート認証ガード / レイアウト |

## entrypoint

- **nitro**: `nuxt.config.ts` → `nitro.preset = "cloudflare_module"`、`main = .output/server/index.mjs` (wrangler.toml)。server/api 無し = pure SPA + API は外部 rust-alc-api。
- **API base**: `runtimeConfig.public.apiBase` (= `NUXT_PUBLIC_API_BASE`)。prod = `https://alc-api.ippoan.org`、staging = `rust-alc-api-staging-...run.app`。`app/utils/api.ts` がここを基点に fetch。
- **wrangler**: top-level = prod (`nuxt-trouble`, trouble.ippoan.org)。`[env.staging]` = `nuxt-trouble-staging` (trouble-staging.ippoan.org)。

## gotcha

- **`trouble_tasks` の対応者は 2 フィールド**: Row1 = タスク対応者 (`assigned_to`)、Row2 = 次のアクション対応者 (`next_action_by`)。**両 row に対応者欄が必要**。テーブルレイアウト変更時に片方を消さない (user が複数回指摘した経緯、CLAUDE.md `feedback_two_assignees`)。
- **`@ippoan/auth-client` は Vite で exclude** (`nuxt.config.ts` の `optimizeDeps.exclude`)。.ts ソース公開のため dep pre-bundle で `#imports` 解決がバグり invalid JS になる → SSR/ESM 経路に委ねる。carins/dtako の `build.transpile` とは別の回避策。
- `app/types/generated/` は ts-rs 生成物 (rust-alc-api 側 `sync-types.sh`)。手動編集禁止、差分は backend 型変更で生じる。
- `typescript.tsConfig.compilerOptions.skipLibCheck = true` 設定済み (依存型の lib check を回避)。
- `@nuxt/ui` は **4.x** (Nuxt 4 世代)。`frappe-gantt` でガントチャート (`TicketGanttChart.vue`)。

## CCoW/CI から見た立ち位置

- rust-alc-api consumer (alc-app / carins / dtako の兄弟)。認証は `@ippoan/auth-client` + auth-worker。
- CI: `.github/workflows/` (frontend-ci 系)。`coverage_100.toml` + `docker-compose.test.yml` (rust-alc-api コンテナで live テスト可能)。`.ippoan-dev.yaml` で dev 設定。

## 関連 skill

- `auth-worker-map` — `@ippoan/auth-client` の発行元
- `nuxt-pwa-carins-map` / `nuxt_dtako_logs-map` / `alc-app-map` — 同じ rust-alc-api consumer の兄弟
- `type-safe-pipeline` — ts-rs 型同期パイプライン (generated/ の生成元)
- `nuxt-vitest` — Nuxt 4 + Vitest テスト作成
- `repo-map` / `cross-repo-symbol-index` — この map の運用方針
