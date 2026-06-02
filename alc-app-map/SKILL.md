---
name: alc-app-map
generated-from: alc-app:9c136965ceb6666320ac4f357f9e4f46922b286d
description: yhonda-ohishi-alc/alc-app (業務用アルコールチェッカーシステム / 複合 repo) の構造ナビゲーション。タニタ FC-1200 + NFC + 顔認証による本人確認付きアルコール測定 + 遠隔点呼。web/ (Nuxt 4 PWA on Workers)・cf-alc-signaling/ (WebRTC signaling DO)・fc1200-wasm (秘匿) の区画、WebSerial/WebRTC/顔認証の composable 配置、秘匿ファイル・テストの gotcha を 1 枚にまとめる。トリガー: 「alc-app」「アルコールチェッカー」「FC-1200」「fc1200」「点呼」「遠隔点呼」「顔認証」「NFC bridge」「WebRTC signaling」「cf-alc-signaling」「alc.ippoan.org」等。
---

# alc-app-map — yhonda-ohishi-alc/alc-app 構造ナビゲーション

業務用アルコール検知システム。タニタ FC-1200 (RS232C) + NFC + 顔認証 (@vladmandic/human)
による本人確認付き測定 + 運転者⇔運行管理者の遠隔点呼 (WebRTC)。**複合 repo**: フロント
(Nuxt 4 PWA) と signaling worker と WASM が 1 repo に同居 (public repo)。

> ここは索引。細部 (関数シグネチャ・行) は repo 側が正。
> frontmatter の `generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す → tree-sha を更新する。

## トップレベル区画

| 区画 | 中身 | 役割 |
|---|---|---|
| **`web/`** | Nuxt 4 PWA (`app/` 構成) + `server/` + `wrangler.jsonc` | フロント本体 (Cloudflare Workers `cloudflare_module`)。下表参照 |
| **`cf-alc-signaling/`** | `src/{index,signaling-room,room-registry}.ts` + `wrangler.toml` | WebRTC signaling worker。Durable Objects (Hibernatable WS) で SDP/ICE リレー。worker 名 `alc-signaling` |
| **`fc1200-wasm/`** | (git ignored) Rust → WASM | FC-1200 RS232C プロトコル実装を WASM に compile して**ソース秘匿**。`web` から `fc1200-wasm` import |
| **`docs/`** | mkdocs (`mkdocs.yml`, admin/ operator/) | 運用ドキュメント。`docs/*.pdf` = Tanita Confidential で **.gitignore** |
| **`plan/`** | `implementation-plan.md` `initialplan.md` | 実装計画 |
| **`scripts/`** | `sync-ts-bindings.sh` | rust-alc-api 型同期補助 |
| **`~/rust/rust-nfc-bridge`** `~/rust/rust-alc-api` | **別 repo** (symlink `alc-app` あり) | NFC リーダ→仮想シリアル (Windows) / バックエンド API (Axum + Cloud Run + PG RLS) |

## web/ の区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `web/app/pages/{index,tenko,login,register,device-claim,device-approve,maintenance}.vue` + `pages/auth/` | 測定 / 点呼 / 認証 / デバイス登録承認 |
| **composables (デバイス I/O)** | `useFc1200Serial.ts` (WebSerial) `useNfcWebSocket.ts` `useBleGateway.ts` `useSerialDeviceManager.ts` `useCamera.ts` | FC-1200 シリアル / NFC WS / BLE / シリアル管理 / カメラ |
| **composables (顔認証)** | `useFaceAuth.ts` `useFaceDetection.ts` `useFaceSync.ts` `useFingerprint.ts` | 顔検出 (Web Worker) / 同期 / 指紋 |
| **composables (点呼/通話)** | `useWebRtc.ts` `useTenkoKiosk.ts` `useTenkoAdmin.ts` `useScreenShare.ts` `useVideoRecorder.ts` | WebRTC 通話 / 点呼キオスク / 管理者 / 画面共有 / 録画 |
| **composables (その他)** | `useAuth.ts` `useManagerAuth.ts` `useOfflineSync.ts` `useDemoMode.ts` `useAndroidLandscape.ts` `useNfcBridgeUpdate.ts` | 認証 / オフライン同期 / デモ / Android |
| **components** | `Tenko*.vue` (多数: Kiosk/VideoCall/RemoteAdminView/ScheduleManager 等) `*Dashboard.vue` `FaceAuth.vue` `AlcMeasurement.vue` `Device*.vue` | 点呼 UI / ダッシュボード / 測定 / デバイス管理 |
| **utils** | `web/app/utils/{api,env,face-approval,face-db,fc1200,human-config,license,offline-queue,video-store}.ts` | API client / 顔 DB (IndexedDB) / FC-1200 / human 設定 / オフラインキュー |
| **worker** | `web/app/workers/face-detect.worker.ts` | 顔検出 Web Worker (@vladmandic/human) |
| **server route** | `web/server/api/{tenko-call/*,devices/*,github-checksum.get}.ts` | 点呼コール (drivers/numbers/register) / デバイス (FCM token / version / watchdog / claim) / NFC bridge checksum |
| **型 (生成)** | `web/app/types/generated/*` (91 file) + `web/app/types/index.ts` | rust-alc-api models.rs から **ts-rs 自動生成** (`Backend` namespace)。手動編集禁止。フロント固有型は index.ts に手動定義 |
| **middleware** | `web/app/middleware/auth.global.ts` | 全ルート認証ガード |

## entrypoint

- **web nitro**: `web/nuxt.config.ts` → `nitro.preset = "cloudflare_module"`、`main = .output/server/index.mjs` (`web/wrangler.jsonc`)。`vite-plugin-wasm` + `optimizeDeps.exclude: ['fc1200-wasm']`。
- **web wrangler (jsonc)**: top-level = prod (`alc-app`, alc.ippoan.org)。`env.staging` = `alc-app-staging` (alc-staging.ippoan.org)。`NUXT_PUBLIC_{API_BASE,GOOGLE_CLIENT_ID,AUTH_WORKER_URL,STAGING_TENANT_ID,SIGNALING_URL}` を env で切替。
- **signaling**: `cf-alc-signaling/src/index.ts` (worker entry) → DO `SignalingRoom` (device/admin 2 ピア間リレー) + `RoomRegistry`。`wrangler.toml` に migration v1/v2、`BACKEND_API_URL` var。secret 不要 (STUN P2P のみ、TURN 後日)。
- **接続**: `NUXT_PUBLIC_SIGNALING_URL` に signaling worker URL。Room ID = `tenko_session_id`。

## gotcha

- **public repo + 秘匿ファイル**: repo は public。`docs/*.pdf` (FC-1200 通信仕様 = Tanita Confidential)・`fc1200-wasm/{src,Cargo.toml,Cargo.lock}` は **.gitignore 済み = 絶対コミットしない** (WASM に compile してプロトコル秘匿)。
- **semver patch のみ**: バージョンアップは常に patch (0.2.1→0.2.2)。minor/major は上げない。
- **WebRTC は Hibernatable WebSockets API 必須** (Durable Objects)。
- **テスト (CLAUDE.md に詳細)**: Vitest 4 + `@nuxt/test-utils` (happy-dom)。fc1200-wasm は `tests/mocks/` でモック (CI に wasm-pack 不要)。ブラウザ API (WebSerial/BLE/NFC) は `Object.defineProperty(navigator, ...)` でモック。**`v8 ignore` 禁止** (`withSetup` / テスト追加 / 到達不能コード削除で対処)。モジュールスコープ状態を持つ composable (`useBleGateway` `useFaceDetection` `useFc1200Serial`) は `vi.resetModules()` + dynamic import で分離。
- **mock/live 統一テスト**: `web/tests/utils/api.test.ts` は 1 ファイルで mock と live (実 rust-alc-api コンテナ) 両対応。`API_BASE_URL` 環境変数の有無で切替。fake ID 禁止 (`api-test-data.ts` の実在 UUID を使う)。`docker-compose.test.yml` で GHCR `rust-alc-api:latest` + PG 起動。
- **型同期**: `cd ~/rust/rust-alc-api && bash scripts/sync-types.sh` → `web/app/types/generated/` に生成 (git 管理、CI で差分チェック)。

## CCoW/CI から見た立ち位置

- rust-alc-api を叩く consumer 群の親玉 (carins / nuxt-trouble / nuxt_dtako_logs の兄弟だが最も大きい)。認証は `@ippoan/auth-client` + auth-worker (auth.ippoan.org)。
- CI: `.github/workflows/{test,tag-release,docs}.yml`。test = `web/**` パス変更時 `npm ci` → `vitest run --coverage` → `check_coverage_100.mjs` → Job Summary/artifact。`docs.yml` = mkdocs。`coverage_100.toml` で 100% リグレッション検出。
- **main 直 push 禁止** (branch protection)。`gh pr merge --squash --auto` で CI 通過後 auto-merge (`enforce_admins: false`)。
- `.claude/skills/` に repo 固有 skill (`next-session` `resume-session`) あり。`.githooks/` も。

## 関連 skill

- `auth-worker-map` — `@ippoan/auth-client` の発行元
- `nuxt-pwa-carins-map` / `nuxt-trouble-map` / `nuxt_dtako_logs-map` — 同じ rust-alc-api consumer の兄弟
- `type-safe-pipeline` — ts-rs 型同期パイプライン (generated/ の生成元)
- `nuxt-vitest` / `worker-vitest` — Nuxt 4 / Workers 向け Vitest テスト
- `repo-map` / `cross-repo-symbol-index` — この map の運用方針 (generated-from 鮮度)
