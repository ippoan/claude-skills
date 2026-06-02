---
name: ci-dashboard-map
generated-from: ci-dashboard:bc0514d6d54bde959f19cdad0cfd32965a79f0c6
description: ippoan/ci-dashboard (Cloudflare Workers + Hono、CI 状況 SSR ダッシュボード + GitHub MCP server + Release Wave 機構) の構造ナビゲーション。webhook 取込 (CI_HUB DO) / cross-org issue・projects SSR / Release Wave (canary flip / compatibility 突合 / ReleaseWaveHub DO) / MCP tool 群の配置と gotcha を 1 枚にまとめる。トリガー: 「ci-dashboard」「Release Wave」「release wave」「compatibility 突合」「CIDashboardHub」「ReleaseWaveHub」「tag-release」「close 確認」「GitHub MCP」「webhooks/release-wave」「ci-dashboard.ippoan.org」等。
---

# ci-dashboard-map — ippoan/ci-dashboard 構造ナビゲーション

Cloudflare Workers (Hono) ベース。3 役を 1 worker に同居: **(1) CI 状況 SSR
ダッシュボード + WebSocket live 更新、(2) GitHub MCP server (`/mcp`)、(3) Release
Wave (canary release オーケストレータ)**。`src/index.ts` が全 route を登録、
ロジックは `src/*.ts` / `src/release-wave/` / `src/mcp/` に分散。

> 細部 (関数シグネチャ・正確な行) は repo 側が正。ここは「どこを見るか」の索引。
> frontmatter の `generated-from` が現在の tree-sha とズレたら
> session-start-skill-coverage hook が再生成を促す → その時 tree-sha を更新する。

## 区画

| module | 主要ファイル | 役割 |
|---|---|---|
| **entry** | `src/index.ts` | Hono 全 route + `Env` 型 + 2 DO export |
| **CI hub** | `src/hub.ts` (`CIDashboardHub` DO) | webhook で受けた run status を SQLite 保持 + WS broadcast。`/status` `/snapshot` proxy 先 |
| **webhook 取込** | `src/webhook.ts` | GitHub webhook 検証 (X-Hub-Signature-256) → hub 反映 |
| **SSR ページ** | `src/dashboard.ts` `issues-page.ts` `projects-page.ts` `releases-page.ts` `secret-gen-page.ts` `nav-tabs.ts` `pwa.ts` | 各タブの HTML 生成 |
| **release / close** | `src/release-close*.ts` `release-helpers.ts` `release-cache.ts` `release-alert.ts` `tag-release.ts` `tagless-repos.ts` | tag から `Refs #N` 逆引き → 目視 close UI |
| **キャッシュ** | `src/issue-cache.ts` `project-cache.ts` `issue-prs.ts` `recheck.ts` | KV (CI_STATUS) cache |
| **GitHub API** | `src/github-api.ts` | `AUTH_WORKER_ORIGIN` + `getGitHubToken` (auth-worker delegation) |
| **MCP server** | `src/mcp/server.ts` + `src/mcp/tools/*` | `/mcp` (stateless Streamable HTTP)。下表参照 |
| **Release Wave** | `src/release-wave/*` (`do.ts` = `ReleaseWaveHub`) | canary flip / compatibility 突合 / webhook / page / api。下記参照 |

### MCP tools (`src/mcp/tools/*`, 計 ~46 tool)

| file | tools (件数) |
|---|---|
| `actions.ts` (6) / `pulls.ts` (3) / `releases.ts` (3) | workflow run / PR / release 操作 |
| `issues.ts` (11) / `projects.ts` (8) | cross-org issue / Projects v2 (`list_org_issues` 等。check-issue skill が consume) |
| `logs.ts` (2) / `commits.ts` (2) / `repository.ts` (3) | job log / commit / repo |
| `release-wave.ts` (8) | `release_wave_start/stage/flip/approve/rollback/abort/status` 等 |

### Release Wave (`src/release-wave/`)

| ファイル | 役割 |
|---|---|
| `do.ts` (`ReleaseWaveHub`) `state.ts` `types.ts` `revision.ts` | wave 状態機械 (SQLite DO) |
| `webhook.ts` | GitHub Actions step が叩く shared-secret webhook (contract-applied / stage / flip / *-report / pending-release / traffic) |
| `compat.ts` `compat-api.ts` | frontend ↔ backend image の compatibility 突合 (COMPAT_KV) |
| `api.ts` `page.ts` `dispatch.ts` `traffic.ts` `pending-release.ts` `tag-release-action.ts` `repo-*.ts` | admin UI action / dispatch / traffic split |

## entrypoint (`src/index.ts` の route)

- **SSR**: `GET /` `/issues` `/projects` `/releases` `/secret-gen` `/release-wave` `/release-wave/:wave_id`
- **live**: `GET /ws` `/status` `/snapshot` `/release-alerts` (すべて `CIDashboardHub` proxy)
- **webhook**: `POST /webhook` `/webhooks` (GitHub)、`/webhooks/release-wave/*` (Actions step, shared secret)
- **action POST**: `/api/release-close[-batch]` `/api/tag-release` `/api/recheck` `/api/dismiss` `/api/release-wave/:wave_id/{approve,rollback,abort,retest}` 他
- **OAuth**: `GET /oauth/login` `/oauth/callback` (`@ippoan/auth-client-worker` delegation, Refs #118)
- **MCP**: `ALL /mcp` (stateless)
- **PWA**: `/manifest.webmanifest` `/sw.js` `/icons/:file`
- **export**: `CIDashboardHub` (`hub.ts`) / `ReleaseWaveHub` (`release-wave/do.ts`)

## gotcha (CLAUDE.md / wrangler 由来)

- **DO 2 個**: `CIDashboardHub` (CI status hub) / `ReleaseWaveHub` (wave 状態)。migration tag v1/v2。
- **KV エイリアス罠**: `CI_STATUS` と `COMPAT_KV` は **同一 namespace id** (`ffb98...`)。key prefix (`frontend::` / `backend::`) で衝突回避 (Refs #157/#158)。
- **`/webhooks` (複数形) は CF Access bypass prefix**。単数 `/webhook` は Access 配下で GitHub 配信が 302 になり到達不能 → 両方 route 登録。handleWebhook は署名自前検証。
- **GitHub token は auth-worker delegation** (`/oauth/login` browser flow → KV に JWT+refresh 保存)。operator が rotate する secret は無い (#118)。`INTERNAL_SHARED_SECRET` binding は `/mcp/introspect` 用 (secret_name は `JWT_FOR_CI_DASHBOARD`)。
- **Release Wave webhook は MCP と機能等価**だが OAuth 不要の shared secret (`RELEASE_WAVE_WEBHOOK_SECRET`) で Actions から curl 1 行で叩ける。
- **prod/staging dual-env**: top-level + `[env.staging]`。staging が custom domain `ci-dashboard.ippoan.org` を持つ (= staging を実運用扱い)。`TAGLESS_REPOS` var で「tag を切らない repo は PR merge を release 扱い」。
- **close キーワード規約**: PR は `Refs #N` のみ (`Closes/Fixes/Resolves` 禁止)。release tag 後にこの dashboard の close 確認 UI / `close_issue` MCP tool で目視 close。

## CCoW / CI から見た立ち位置

- **org 横断 issue / CI / release のハブ**。`check-issue` skill が `list_org_issues` を、release 系 skill が release-wave tool を consume。
- frontend/backend の各 CI (`frontend-ci.yml` 等) が `/webhooks/release-wave/*` に報告して compatibility 突合・canary flip を駆動。
- GitHub token / OAuth は **auth-worker** に委譲。

## 関連 skill

- `auth-worker-map` — OAuth delegation 先 (`@ippoan/auth-client-worker`)
- `check-issue` — `list_org_issues` tool の consumer
- `tag-release` / `branch-issue-linking` — release / `Refs #N` 規約
- `ippoan-infra-map` / `cross-repo-symbol-index` — 基盤地図 / 鮮度 hook
