---
name: ippoan-lib-catalog
description: ippoan/ohishi-exp org の「この機能の canonical 実装はどこか」の capability 粒度カタログ。util / helper / 横断ロジック (JWT 検証、timing-safe 比較、base64url、fetch wrapper、認証 UI、CSV パース、Cloud Run proxy skeleton、coverage script、CI pipeline 等) を新規実装する前に必ず参照し、既存 lib があれば consume する (lib-first、CLAUDE.md.template の policy)。トリガー:「再実装」「util 作る」「helper 書く」「どの lib」「lib ある?」「canonical どこ」「共通化」「lib-first」「車輪の再発明」「JWT 検証 worker」「timing-safe」「createAuthFetch」「coverage script」「lib catalog」等。
---

# ippoan-lib-catalog — capability → canonical の対応表

**使い方**: util / helper / 横断ロジックを書きたくなったら、まずこの表で canonical を
探す → 無ければ org 横断検索 (`grep -rn "<機能語>" /home/user/*/src`、または その場
ctags) → それでも無ければ新規実装して良いが、**2 repo 目で必要になった時点で lib
切り出しを user に提案する** (rule of two)。

> この表は **capability 粒度** で書く。関数粒度で書くと必ず stale 化する。
> 行の追加・変更は「lib の新設 / 機能の lib への移管」の時だけ。
> 背景・監査記録: ippoan/claude-md#76 (lib→client 集約 epic)。

## TypeScript / Cloudflare Workers

| capability | canonical | 備考 |
|---|---|---|
| MCP worker 配線 (stateless `/mcp` factory、durable DO+WS transport) | `@ippoan/mcp-cf-workers` | consumer 例: ui-preview, cdp-relay, secrets-inventory |
| worker 認証部品 (HS256 JWT verify, timing-safe 比較, base64url, binding-jwt middleware, resolveSecret) | `@ippoan/mcp-cf-workers` の auth surface | 拡張中 (ippoan/mcp-cf-workers#46)。**自前 Web Crypto 実装を新たに書かない** |
| OAuth クライアント側部品 (PKCE, introspect client, github token cache) | `@ippoan/auth-client-worker` (auth-worker/packages) | |
| Nuxt 認証 UI / composable (useAuth, AuthToolbar, StagingFooter, VersionBadge, decodeJwtClaims, createAuthFetch, auth plugin / proxy 配管) | `@ippoan/auth-client` (auth-worker/packages) | 拡張中 (ippoan/auth-worker#257)。Nuxt app に auth 配管をコピーしない |
| coverage 100% gate script (`check_coverage_100.mjs`) | `@ippoan/test-utils` (auth-worker/packages) | bin 公開予定 (同 #257)。新 repo に script をコピーしない |
| e-Gov 電子申請 (API client, OAuth PKCE, XML 署名 xmldsig/c14n/pfx) | `@ippoan/egov-shinsei-sdk` | nuxt-egov は SDK 消費に戻す (ippoan/nuxt-egov#93) |
| 静的 UI プレビュー配信 | ippoan/ui-preview (DO) + `ui-preview` skill | |

## Rust

| capability | canonical | 備考 |
|---|---|---|
| dtako/拘束時間 CSV パース (KUDGIVT/KUDGURI/work_segments) | rust-alc-api `crates/alc-csv-parser` | daiun-salary は移行予定 (ohishi-exp/daiun-salary#10) |
| 拘束時間 比較エンジン | rust-alc-api `crates/alc-compare` | 同上 |
| HS256 app JWT (claims/issue/verify), Google ID token verify, axum auth middleware, constant-time 比較 | rust-alc-api `crates/alc-core` | satellite repo はコピーでなく依存 (ohishi-exp/rust-ichibanboshi#4) |
| R2 / GCS storage backend (trait + presign) | rust-alc-api `crates/alc-storage` | |
| 外部 API client の作法 (with_endpoints 注入 + wiremock) | rust-alc-api CLAUDE.md「外部 API 連携の開発フロー」 | パターンの SoT (crate ではない) |

## Go

| capability | canonical | 備考 |
|---|---|---|
| Cloud Run proxy skeleton (MustEnv, RequireAPIKey constant-time, WriteJSON/Error 固定文言 502, gRPC status→HTTP) | ippoan/go-cloudrun-proxy | 実装中 (ippoan/go-cloudrun-proxy#1)。consumer: release-wave-gcp, secrets-inventory-gcp |

## インフラ / 運用

| capability | canonical | 備考 |
|---|---|---|
| CI pipeline (frontend/go/lib/rust-ci, auto-merge, cloud-run-deploy, release-wave-handler, tag-release, secret-verify) | ippoan/ci-workflows reusable workflows | caller に CI ロジックを手書きしない |
| CLAUDE.md 共通 template / CCoW bootstrap (install.sh, settings template) | ippoan/claude-md | 配線の SoT |
| hook script 実体 (guard / SessionStart 系) | ippoan/claude-hooks | 動作の SoT (`ippoan-infra-map` 参照) |
| 共有 skill | ippoan/claude-skills (この repo) | |
| secret 投入 / rotation | `secret-inject` skill + secrets-inventory MCP | 値を context に出さない |

## 関連ルール

- **lib に不足があれば lib 側に足して publish → consumer で使う** (手元に fork しない)。
  npm 系は `npm_publish_propagate_repos` (frontend-ci) で consumer 自動更新が効く
- **やむを得ない copy** (ts-rs 生成型の配布先等) はファイル先頭 5 行以内に
  `SOURCE-MIRROR: <repo>:<path>` を宣言 → `session-start-source-mirror-check.sh` が
  canonical との乖離を監視する
- **「同実装を手動 sync で維持」コメントを書かない** — それは lib 化シグナル
- 関連 skill: `cross-repo-symbol-index` (その場 ctags の作法) / `repo-map` (構造 map) /
  `ippoan-infra-map` (基盤 5 repo の役割分担)
