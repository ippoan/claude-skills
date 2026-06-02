---
name: nuxt-notify-map
generated-from: nuxt-notify:1911f1a480b41f3669ceedec9588d791bcf35ef8
description: ippoan/nuxt-notify (文書配信・メール受信・墨消し通知 PWA、Nuxt 4 + Cloudflare Workers) の構造ナビゲーション。frontend pages / 2 つの補助 Worker (email-receiver / realtime-bus DO) / 墨消し WebSocket 通知の配置と prod/staging 構成・gotcha を 1 枚にまとめる。トリガー:「nuxt-notify」「notify.ippoan.org」「メール受信」「email-receiver」「realtime-bus」「RedactBus」「墨消し」「redaction」「LINE WORKS 配信」「公文書配信」「v/[token]」等。
---

# nuxt-notify-map — ippoan/nuxt-notify 構造ナビゲーション

文書配信・メール受信・墨消し通知ツール。Nuxt 4 (`cloudflare_module`) frontend +
**2 つの補助 Worker** (workers/)。frontend は backend rust-alc-api を叩き、墨消し完了は
realtime-bus Worker の WebSocket で push される。

> 細部は repo 側が正。ここは索引。`generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す。

## 区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `app/pages/index.vue`, `recipients.vue`, `settings.vue`, `lineworks-groups.vue`, `test-distribute.vue` | 文書一覧 / 宛先 / 設定 / LINE WORKS グループ / 配信テスト |
| **pages (詳細)** | `documents/[id].vue`, `emails/{index,[id]}.vue`, `v/[token].vue` | 文書詳細 / メール一覧・詳細 / トークン公開ビュー |
| **components** | `DistributeModal.vue`, `FolderWatcher.vue`, `UploadButton.vue` | 配信モーダル / フォルダ監視 / アップロード |
| **composables** | `useApi.ts`, `useFilePicker.ts`, `useFolderWatcher.ts`, `useRedactionWatch.ts` | API / ファイル選択 / フォルダ監視 / 墨消し WS 購読 |
| **utils** | `app/utils/{folderWatchDb,preview-fetch}.ts` | フォルダ監視 IndexedDB / プレビュー取得 |
| **Worker: email-receiver** | `workers/email-receiver/src/index.ts` | Cloudflare Email Routing 受信 → host で prod/staging 振り分け → backend ingest に POST (PostalMime で parse) |
| **Worker: realtime-bus** | `workers/realtime-bus/src/{index,redact-bus,jwt}.ts` | 墨消し完了の DO fan-out。`POST /broadcast` (backend push) / `GET /subscribe` (browser WS)。`RedactBus` DO は hibernation 対応 |

## entrypoint

- nuxt.config: `nitro.preset = cloudflare_module`、`@nuxtjs/tailwindcss`、`@ippoan/auth-client` を vite optimizeDeps exclude、`allowedHosts: ['.trycloudflare.com']`。
- wrangler.jsonc (frontend): prod (`nuxt-notify`, notify.ippoan.org) / `[env.staging]`。vars: `NUXT_PUBLIC_{API_BASE,AUTH_WORKER_URL,REALTIME_BUS_URL}` (realtime は `wss://realtime.notify(-staging).ippoan.org`)。
- email-receiver: Email Routing trigger。env `INGEST_ENDPOINT(_STAGING)`, `NOTIFY_WORKER_SECRET(_STAGING)`, `PROD_HOST`/`STAGING_HOST`。`pickRoute(host, env)` で 1 Worker が prod/staging 両方を振り分け。
- realtime-bus: env `REDACT_BUS` (DO namespace), `JWT_SECRET`, `NOTIFY_REDACT_BROADCAST_SECRET`。

## gotcha

- **3 つの独立 deploy 単位**。frontend (`tag-release.yml`) / email-receiver (`email-worker-deploy.yml`) / realtime-bus (`realtime-bus-deploy.yml`) は別々の wrangler/CI。1 つ直して全部出る訳ではない。
- **frontend は runtime secret を持たない** が、ci-workflows の secret-verify gate を pass させるため wrangler.jsonc に `"secrets": {"required": []}` を**明示 declare** (Refs ippoan/ci-workflows#50)。空でも消さない。
- **email-receiver は 1 Worker で prod/staging 両受け**。host (notify.ippoan.org / notify-staging…) で `pickRoute` がエンドポイント+secret を選ぶ。`MAX_TOTAL_BYTES=25MB` / `MAX_ATTACHMENTS=20`。
- **realtime-bus は no-op 許容**。frontend の `realtimeBusUrl` 未設定なら `useRedactionWatch` は no-op (既存 polling が UI 更新を担う)。WS subprotocol は `"bearer,<jwt>"`、broadcast は `X-Broadcast-Secret` で検証。
- README.md は Nuxt boilerplate。

## CCoW / CI から見た立ち位置

- consumer 側。`@ippoan/auth-client` で JWT。backend rust-alc-api が email ingest / 墨消し broadcast の相手。
- テスト: `coverage_100.toml` + `vitest.config.ts` (frontend) と各 worker 配下の `vitest.config.ts`。`docker-compose.test.yml` あり。

## 関連 skill

- `auth-worker-map` — JWT 発行元 (`@ippoan/auth-client` / realtime-bus の JWT 検証元)
- `nuxt-vitest` `worker-vitest` — frontend composable / 2 worker のテスト
- `wrangler-logs` — 各 Worker の過去ログ/メトリクス
- `cross-repo-symbol-index` `ippoan-infra-map` — 横断 symbol / 基盤地図
