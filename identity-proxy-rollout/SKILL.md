---
name: identity-proxy-rollout
description: >
  ippoan の Nuxt/Workers consumer を rust-alc-api#434 の「dumb backend +
  proxy が identity 注入」モデルへ移行する playbook。@ippoan/auth-client/server の
  createIdentityProxyHandler を server route に置き、introspect 検証 →
  X-Tenant-ID + X-User-ID/Email/Role を注入して rust-alc-api に転送する。
  最重要 gotcha は「createIdentityProxyHandler が dev dist-tag にしか無い」+
  「committed lockfile があると package.json の "dev" tag を npm が再評価せず
  古い版が入る (npm/cli#7562) → typecheck が @ippoan/auth-client/server 無いで
  fail」で、test.yml の use_auth_client_dev:true で PR 時に dev を overlay install
  するのが正規ルート。2026-06 に carins#38 / nuxt_dtako_logs#27 / alc-app#51 で
  検証済み。トリガー:「createIdentityProxyHandler」「use_auth_client_dev」
  「@ippoan/auth-client/server が無い」「Cannot find module @ippoan/auth-client/server」
  「initAuthSession has no exported member」「dev で通らない」「通る 通らない auth-client」
  「npm dist-tag 再評価されない」「npm/cli 7562」「rust-alc-api#434 consumer 横展開」
  「X-User-* 注入」「X-Tenant-ID proxy」「AuthUser 必須 handler 500」「dumb backend proxy」等。
---

# identity-proxy-rollout — rust-alc-api#434 consumer 移行 playbook

rust-alc-api は #441 で **JWT を検証しない dumb backend** になった。tenant/admin 経路は
前段 proxy (CF Worker = 各 Nuxt consumer) が auth-worker `/auth/introspect` で検証して
注入する `X-Tenant-ID` / `X-User-ID/Email/Role` ヘッダーを信頼する (`require_tenant_header`)。
よって各 consumer は **rust-alc-api を直叩きせず、自身の Worker の server proxy 経由**にし、
その proxy で identity を注入する必要がある。これを `@ippoan/auth-client/server` の
**`createIdentityProxyHandler`** に集約する。

> 外部直叩き遮断 (step 3 = Cloud Run IAM lockdown) の前提が「全 consumer が proxy 経由」。
> X-User-* を載せないと AuthUser 必須 handler (約 37 個) が 500 になる (旧 createApiProxyHandler は
> X-Tenant-ID しか載せない)。

## ⚠️ 最重要 gotcha: 「通る/通らない」の正体 (npm/cli#7562)

`createIdentityProxyHandler` は `@ippoan/auth-client` の **`dev` dist-tag にしか無い**
(stable v* 未リリース)。だが:

- **committed `package-lock.json` があると、package.json を `"dev"` に変えても npm は
  dist-tag を再評価せず、lockfile 記録済みの古い版を入れ続ける** ([npm/cli#7562](https://github.com/npm/cli/issues/7562))。
  → 古い auth-client が入り `typecheck` が **`Cannot find module '@ippoan/auth-client/server'`**
  / **`'@ippoan/auth-client' has no exported member 'initAuthSession'`** で fail する。
- `actions/setup-node@v4` の `cache: npm` は **lockfile 必須**なので、lockfile 削除は不可
  (「Dependencies lock file is not found」で install 前に落ちる)。

**正規ルート = frontend-ci の `use_auth_client_dev: true`**。これは PR event で
`npm install @ippoan/auth-client@dev` を **lockfile の後に overlay install** する
(`ippoan/auth-worker/.github/actions/use-auth-client-dev`、`if: github.event_name == 'pull_request'`)。

実証 (2026-06):
- **alc-app#51** は test.yml に `use_auth_client_dev:true` が既にあった → **通った**
- **nuxt_dtako_logs#27** は無かった → **通らなかった** → 足したら Type Check green

> `push`(main) event では overlay が走らないので、stable v* リリース前は **main の typecheck が
> 赤になり得る**。これは dev チャネル運用の既知トレードオフ (step 4 で stable 化して解消)。

## 消費側パターン (4 点セット + frontend 移行)

reference 実装: `ippoan/nuxt-pwa-carins` (pilot #38) / `ohishi-exp/nuxt_dtako_logs` (#27)。

### 1. server proxy route (`server/api/proxy/[...path].ts`)

carins/dtako_logs の中身をコピー。要点:

```ts
import { createIdentityProxyHandler } from '@ippoan/auth-client/server'
// cfEnv(event) で event.context.cloudflare.env、resolveSecret() で
// Secrets Store binding (.get()) / 文字列 両対応。INTERNAL_SHARED_SECRET 未設定は 503。
export default defineEventHandler(async (event) => {
  const env = cfEnv(event)
  const sharedSecret = await resolveSecret(env.INTERNAL_SHARED_SECRET) // 無ければ 503
  const authWorker = env.AUTH_WORKER as { fetch: typeof fetch } | undefined
  const proxy = createIdentityProxyHandler({
    backendUrl: (e) => useRuntimeConfig(e).alcApiUrl,        // rust-alc-api
    authWorkerUrl: env.NUXT_PUBLIC_AUTH_WORKER_URL || 'https://auth.ippoan.org',
    sharedSecret,
    introspectFetch: authWorker ? () => authWorker.fetch.bind(authWorker) : undefined, // service binding
  })
  return proxy(event)
})
```

### 2. wrangler (全 env に宣言)

- `AUTH_WORKER` **service binding** → `auth-worker` (introspect を worker-to-worker で叩く)
- `INTERNAL_SHARED_SECRET` **secrets_store binding** (`store_id=bd7bc91a3e5f4111add4acf6cb4b8733`,
  `secret_name=INTERNAL_SHARED_SECRET`)
- `NUXT_PUBLIC_AUTH_WORKER_URL` (prod=`https://auth.ippoan.org` / staging=`https://auth-staging.ippoan.org`)
- `NUXT_ALC_API_URL` (rust-alc-api URL)
- **named env は top-level binding を継承しない** → `[env.staging]` 等に**再宣言**。
- toml は `[[services]]` / `[[secrets_store_secrets]]`、jsonc は `services:[]` / `secrets_store_secrets:[]`
  (jsonc 例は `alc-app/web/wrangler.jsonc`)。

### 3. nuxt.config / package.json

- `runtimeConfig.alcApiUrl = process.env.NUXT_ALC_API_URL`、`runtimeConfig.public.authWorkerUrl`
- `build.transpile` に `'@ippoan/auth-client'`
- `package.json`: `"@ippoan/auth-client": "dev"`

### 4. test.yml に `use_auth_client_dev: true` ← これが核心

```yaml
jobs:
  ci:
    uses: ippoan/ci-workflows/.github/workflows/frontend-ci.yml@main
    with:
      use_auth_client_dev: true   # PR 時に @ippoan/auth-client@dev を overlay install
```

### 5. coverage_100.toml / テスト

- 新 proxy route は **coverage_100.toml に登録しない** (thin wrapper、挙動本体は auth-worker 側で
  テスト済み。carins と同方針)。既に登録済みなら **de-register**。
- 旧 `createApiProxyHandler` + `requireAuth` を mock していた `tests/server/proxy.test.ts` は
  **新 route 用に書き換える** (createIdentityProxyHandler を mock、INTERNAL_SHARED_SECRET resolve /
  503 / fallback を wiring テスト)。dtako_logs#27 の proxy.test.ts が雛形。

### 6. frontend 移行

rust-alc-api を直叩き (`${apiBase}` / `NUXT_PUBLIC_API_BASE` + 手動 `X-Tenant-ID`) している
呼び出しを **`/api/proxy/*` (相対・same-origin) 経由**に変え、client 側の X-Tenant-ID/JWT 手動
付与を削除 (proxy が introspect 済み cookie から注入)。中央 `apiBase` / fetch wrapper があれば
`apiBase` を `/api/proxy` に向けるのが低リスク。**login/cookie 経路・device JWT 経路・staging
auth バイパス・viewer の認証 bypass は壊さない**。迷う大きな移行は PR に「要追加検討」と明記して
無理にやらない (別 PR)。

### 7. <repo>-map SKILL.md

`paths` に `server/` 等が含まれるなら proxy 記述を更新 + `generated-from` を code commit sha に
bump (skills-check map-check)。

## 注意

- `secret/値` を会話・log・tool param に出さない (binding の resolve のみ)。
- PR は `Refs #N` (Closes/Fixes 禁止)。auto-merge は user 明示時のみ。
- 既存 device-token / introspect 経路を持つ repo (alc-app kiosk / carins device-upload) は
  その経路を温存しつつ proxy だけ createIdentityProxyHandler に統一する。

## 関連 skill

- `auth-client-consume` — @ippoan/auth-client の subpath 使い分け / packaging の罠 (#257)
- `auth-worker-map` — `/auth/introspect` / use-auth-client-dev action / dev publish の発行元
- `rust-alc-api-map` — `require_tenant_header` / dumb backend / #441
