---
name: auth-client-consume
description: >
  @ippoan/auth-client (auth-worker packages/) を Nuxt app で consume する時の
  API 地図と packaging の罠 (2026-06-11 #257 consumer 移行 6 repo で確定)。
  initAuthSession / createAuthFetch / AuthCallback / server subpath の使い分け、
  「Nitro は node_modules の .ts を transpile しない → server は .mjs+.d.mts」
  「root import は #imports を連鎖 → 素 vitest は ./jwt subpath」「publish は
  auth-worker の v* tag gate → consumer の version bump PR は publish まで
  ETARGET で red」を 1 枚にまとめる。トリガー:「auth-client 移行」
  「initAuthSession」「createAuthFetch」「AuthCallback」「@ippoan/auth-client/server」
  「RollupError PARSE_ERROR node_modules」「Failed to resolve import #imports」
  「ETARGET auth-client」「No matching version」「use_auth_client_dev」等。
---

# @ippoan/auth-client consumer ガイド

## subpath の使い分け (最重要)

| import 元 | 使う場所 | 引き込むもの | 使ってはいけない場所 |
|---|---|---|---|
| `@ippoan/auth-client` (root) | Vue/Nuxt client (pages / components / plugins / composables) | .ts + .vue + `#imports` | **Nitro server route** (RollupError)、**素の vitest** (#imports 解決不能) |
| `@ippoan/auth-client/server` | Nitro server route / middleware | .mjs (+h3) | client bundle (h3 が混入) |
| `@ippoan/auth-client/jwt` | 素 vitest で test される client composable / 共有 util | .mjs (framework-free) | — (どこでも安全) |

理由 (実測): **Nitro (rollup) は node_modules の .ts を transpile しない**。
server route から .ts が import されると `RollupError: PARSE_ERROR (Expected ','
got 'ident')` で nuxt build が落ちる (client の vite build は通るので PR の
typecheck/test だけでは気付けず Deploy Staging で初めて発覚する)。
→ lib の server 系は .mjs + 手書き index.d.mts で ship されている
(auth-worker#261、no-build-step 維持)。

## 主要 API (v0.2.57+)

- `initAuthSession(opts?)` — plugins/auth.client.ts の共通フロー一式
  (?lw= 保存 / fragment・storage・cookie 復元 / 未認証 redirect / 組織一覧 /
  期限切れタイマー)。opts: `lineWorksParam` / `fetchOrganizations` / `expiryTimer`
  (default 全 true)。WOFF や backend ガード等の app 固有前段は呼び出し側 plugin に残す
- `createAuthFetch({ baseUrl, tokenGetter, tenantIdGetter?, tokenRefresher?, onUnauthorized?, errorLabel? })`
  — Authorization/X-Tenant-ID 付与 + 401→refresh→retry (single-flight)。
  `errorLabel: 'API エラー'` で日本語文言維持。終端 401 も
  `${errorLabel} (401): body` を throw (v0.2.57+)。**JSON 専用** — blob/SSE は
  raw fetch を残す (alc-app / nuxt-dtako-admin の api.ts 参照)
- `AuthCallback.vue` — `/auth/callback` ページ本体 (`redirect-to` / `login-path` props)
- `/server`: `resolveAuthAction` / `checkTenantId` / `createApiProxyHandler` /
  `buildProxyHeaders` 等 (`backendUrl` は `event => useRuntimeConfig(event)...` で
  consumer が解決して渡す)
- `/jwt`: `decodeJwtPayloadFromToken` / `decodeJwtClaims` / `extractTenantIdFromAuth`
  (マルチバイト安全。atob 直叩きを書かない)

## publish / version の罠

- **publish は auth-worker の `v*` tag gate** (main merge では Publish Release skip)。
  lib 変更を consumer が使うには tag → GitHub Packages publish が先
- consumer PR で `^0.2.X` に bump → publish 前は CI が **ETARGET (No matching
  version)** で red。publish 後に re-run でよい
- `use_auth_client_dev: true` は **pull_request event のみ** @dev を上書き install。
  main push の deploy では効かないので、merge 前に正規 publish が必要なことは変わらない
- package-lock が旧版を pin している repo: `install_command: 'npm install'` なら
  manifest bump に追従して解決する (npm ci は lock 不整合で fail → install_command
  を明示する。org caller template 標準)

## consumer 実装例 (移行済み repo)

- plugin: nuxt-items / nuxt_dtako_logs / nuxt-pwa-carins (WOFF 前段残し) /
  nuxt-ichibanboshi (backend ガード残し)
- proxy + auth-logic shim: nuxt-pwa-carins / nuxt_dtako_logs / nuxt-ichibanboshi
- callback: nuxt-trouble / nuxt-dtako-admin
- createAuthFetch: alc-app#40 / nuxt-dtako-admin#46 の api.ts
