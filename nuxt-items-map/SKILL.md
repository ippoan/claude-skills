---
name: nuxt-items-map
generated-from: nuxt-items:5ab0baf4fa100ab0800f3466399adce4fbd00bb6
description: ippoan/nuxt-items (物品管理 PWA、Nuxt 4 + Cloudflare Workers) の構造ナビゲーション。バーコード/NFC スキャン・画像アップロード・WebSocket マルチデバイス同期 (Durable Objects) の配置と PWA/同期設定を 1 枚にまとめる。トリガー:「nuxt-items」「物品管理」「items.ippoan.org」「バーコード」「NFC」「barcode-lookup」「amazon-lookup」「useItemsSync」「sync.mtamaramu.com」「PWA」等。
---

# nuxt-items-map — ippoan/nuxt-items 構造ナビゲーション

組織・個人の物品管理 PWA。Nuxt 4 + Nitro `cloudflare-module`、`@vite-pwa/nuxt` で PWA 化。
バーコード/NFC スキャン + 画像で物品を登録し、WebSocket (別 Worker `sync.mtamaramu.com` の
Durable Objects) でクロスデバイス同期する。**`app/` を使わず repo 直下に `pages/` 等を置く**
旧レイアウト (他 4 repo と違い `app/` ディレクトリ無し)。

> 細部は repo 側が正。ここは索引。`generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す。

## 区画

| 区画 | 主要ファイル | 役割 |
|---|---|---|
| **pages** | `pages/index.vue`, `app.vue` | 単一ページ物品ツリー UI |
| **components/items** | `Item{List,Detail,Form,Breadcrumbs}.vue`, `BarcodeScanner/Search.vue`, `Nfc{Scanner,Writer}.vue`, `ImagePicker/Thumbnail.vue`, `OwnerTypeToggle.vue` | 物品 CRUD / バーコード / NFC / 画像 / org⇔個人切替 |
| **composables** | `useItems.ts`, `useItemsSync.ts`, `useAuth.ts`, `useFileUpload.ts`, `useImageCache.ts`, `useNfc.ts`, `useProductLookup.ts` | 物品状態 / WS 同期 / 認証 / 画像 / NFC / 商品検索 |
| **server/api** | `barcode-lookup.ts`, `amazon-lookup.ts` | 外部商品 DB / Amazon 商品照会プロキシ |
| **server/middleware** | `auth.ts` | JWT gate + LINE WORKS 自動ログイン (`?lw=` / `lw_domain` cookie) |
| **types / utils** | `types/`, `utils/` | 型定義 / ヘルパ |

## entrypoint

- nuxt.config: `nitro.preset = cloudflare-module`、modules `@vite-pwa/nuxt` `@nuxt/ui` `@vueuse/nuxt`、`transpile: ['@ippoan/auth-client']`。`pwa.manifest` (物品管理 PWA、share_target あり)、HMR は wss/clientPort 443。
- wrangler.toml: top-level=prod (`nuxt-items`, items.ippoan.org) / `[env.staging]`=staging。`[observability] enabled=true`、`[build] command="npm run build"`。
- vars: `NUXT_PUBLIC_AUTH_WORKER_URL`、`NUXT_PUBLIC_SYNC_URL` (`wss://sync.mtamaramu.com`)、`NUXT_PUBLIC_API_BASE_URL` (alc-api)。

## gotcha

- **`app/` ディレクトリを使わない旧構成**。`pages/` `components/` `composables/` `server/` が repo 直下。他 nuxt-* repo の `app/...` 感覚でパスを探すと外す。
- **マルチデバイス同期は別 Worker** (`wss://sync.mtamaramu.com/ws/items/{orgId}?token=JWT`)。Durable Objects Hibernation API + BroadcastChannel。同期 Worker 本体はこの repo に**無い** — `useItemsSync.ts` は client のみ。
- **LINE WORKS 自動ログイン**: `server/middleware/auth.ts` が `?lw=<domain>` で auth-worker OAuth に直リダイレクト、`lw_domain` cookie で次回以降も自動。`/api/` パスは gate を素通り。
- CLAUDE.md 無し。テスト方針は `coverage_100.toml` (composables を 100% line coverage で登録)。

## CCoW / CI から見た立ち位置

- consumer 側。`@ippoan/auth-client` で JWT。backend は alc-api、同期は sync.mtamaramu.com (DO Worker)。
- CI: `.github/workflows/test.yml` (ci-workflows reusable) + `tag-release.yml`。`[observability]` 有効なので wrangler-logs skill で実ログ取得可。

## 関連 skill

- `auth-worker-map` — JWT 発行元 (`@ippoan/auth-client` の認証先、LINE WORKS SSO もここ)
- `nuxt-vitest` — composable のテスト (`coverage_100.toml` で 100% 管理)
- `wrangler-logs` — observability 有効なので Worker メトリクス/ログ取得
- `cross-repo-symbol-index` `ippoan-infra-map` — 横断 symbol / 基盤地図
