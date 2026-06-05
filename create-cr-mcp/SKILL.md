---
name: create-cr-mcp
description: >
  Cloudflare Workers 上に新しい MCP server (Cloudflare Run MCP = "cr-mcp") を
  @ippoan/mcp-cf-workers factory を consume して scaffold する手順。stateless
  /mcp (createWorkerMcp) + binding_jwt 認証 (auth-worker introspect) + wrangler +
  CI/deploy + vitest を一式そろえ、**claude.ai connector で実際に繋がる**ために
  必須の OAuth discovery 配線 (origin に /.well-known/oauth-authorization-server
  + /register + protected-resource を auth-staging へ proxy) まで含める。
  examples/cf-access-mcp が雛形。
  トリガー: 「create-cr-mcp」「新しい MCP server つくる」「cf-workers MCP consumer」
  「mcp-cf-workers factory で worker」「MCP server scaffold」「claude.ai connector
  が繋がらない MCP」「stateless worker MCP」「binding_jwt MCP worker」等。
---

# create-cr-mcp — Cloudflare Workers MCP server を新規構築する

`@ippoan/mcp-cf-workers` の `createWorkerMcp` (stateless `/mcp`) を consume する
薄い Worker を新規に立て、**claude.ai connector から繋がる**状態まで持っていく
手順。雛形は `ippoan/mcp-cf-workers` の `examples/cf-access-mcp/`。

> このスキルは ippoan/mcp-cf-workers#26 (cf-access-mcp の connector 接続を
> 2026-06-05 に解決した知見) を codify したもの。**特に §4 の OAuth discovery
> 配線が肝** — ここを抜くと「ツールは curl で動くのに claude.ai connector で
> 『サインインサービスへの登録ができませんでした』になる」事故になる。

## 0. 前提と判断

- **transport は stateless `/mcp` (`createWorkerMcp`) を既定にする。** tool セットが
  固定なら `listChanged` 不要なので durable (DO+WS) は要らない (mcp-cf-workers#6/#12)。
  deploy 時に live session の `tools/list` が旧 schema で固まる #70 実害を気にする
  場合だけ durable `/mcp-do` を併設する。
- **認証は binding_jwt (auth-worker の `/mcp/introspect` 委譲)。** worker は shared
  bearer を持たない。`secrets-inventory` / `cf-access-mcp` と同方式。
- **値 (API token 等) は CF Secrets Store binding から runtime `.get()`。** worker code
  / wrangler vars / 会話 / log に焼かない。投入は `secret-inject` skill。
- 置き場: 単独 repo にするか `mcp-cf-workers/examples/<name>/` にするかは規模次第。
  PoC/例なら examples、本番運用なら単独 repo (ref-files-worker パターン)。

## 1. scaffold (examples/cf-access-mcp を雛形にコピー)

最小構成:

```
<name>/
  package.json          # @ippoan/mcp-cf-workers を file:../.. or GitHub Packages で
  wrangler.jsonc        # vars: AUTH_WORKER_ORIGIN / 定数, secrets_store_secrets binding
  tsconfig.json
  vitest.config.ts
  .npmrc                # @ippoan scope (GitHub Packages) or file: link メモ
  src/
    index.ts            # Hono エントリ。/mcp 認証 + discovery 配線 + 遅延 import
    env.ts              # Env binding 型
    discovery.ts        # ★ OAuth discovery proxy (§4、claude.ai connector 必須)
    middleware/binding-jwt.ts   # introspect 委譲 (cf-access-mcp からコピー)
    mcp/
      server.ts         # createWorkerMcp 配線 (/mcp 到達時のみ遅延 import)
      registry.ts       # tool 登録 (single source)
      tools.ts          # 純粋ロジック
      scope.ts          # requiresScope gating (write tool 用)
    lib/...             # 外部 API client 等
  test/                 # vitest (binding-jwt / tools / discovery / scope)
```

`package.json` の `@ippoan/mcp-cf-workers` は GitHub Packages 公開。CI は
`npm_scope:'@ippoan'` + `permissions.packages:read` で引く。ローカルで read token が
無ければ `npm install ../mcp-cf-workers` (file: link)。

## 2. binding_jwt 認証 middleware

`cf-access-mcp/src/middleware/binding-jwt.ts` をコピーして `RESOURCE_METADATA_SLUG`
を新 hostname の先頭 label に変える (例 `<name>.ippoan.org` → `"<name>"`)。

- `/mcp` と `/mcp/*` の両方に mount (Hono の `/mcp/*` は `/mcp/foo` 以下しか当たらない)。
- 401 の `WWW-Authenticate` は **稼働サーバー (ref-files) と byte 一致**にする:
  `Bearer realm="MCP", resource_metadata="<auth-staging>/.well-known/oauth-protected-resource/<slug>", error="invalid_request"`
  (Bearer 不在 = `invalid_request`、token あるが無効 = `invalid_token`)。
  **`error` 属性を omit しない** (mcp-cf-workers#26 PR #41 の轍。RFC 6750 §3.1 を
  厳格に読んで omit すると claude.ai 挙動が変わるリスク。動く参照に合わせる)。
- write tool は `requiresScope: "mcp.write"` で gate。binding_jwt の `scope` と突合。

## 3. wrangler / secret / allowlist

- `wrangler.jsonc` の `vars` に `AUTH_WORKER_ORIGIN = "https://auth-staging.ippoan.org"`
  と定数 (account_id 等)。**secret 値は vars に書かない。**
- `secrets_store_secrets` binding で API token を受け、runtime `.get()`。投入は
  `openssl rand ... | secret-inject ... --targets gcp,cf` (no-leak)。
- **auth-worker の `MCP_RESOURCE_ORIGINS_ALLOWLIST` に `https://<name>.ippoan.org` を
  追加** (auth-worker repo の PR、Refs auth-worker#195/#250)。これが無いと
  `/.well-known/oauth-protected-resource/<slug>` が 200 を返さない。

## 4. ★ OAuth discovery 配線 (claude.ai connector を動かす肝)

**curl で /mcp が 401+WWW-Authenticate を返すだけでは claude.ai connector は繋がらない。**

mcp-cf-workers#26 のライブ log で確定した claude.ai の挙動:
**新規 connector 登録時、claude.ai は WWW-Authenticate の `resource_metadata`
(RFC 9728 → auth-staging) を辿らず、MCP server origin 自身を authorization server
とみなして RFC 8414 origin discovery を叩く:**

```
GET  https://<name>.ippoan.org/.well-known/oauth-authorization-server   → これが要る
POST https://<name>.ippoan.org/register                                  → これが要る (DCR default endpoint)
GET  https://<name>.ippoan.org/.well-known/oauth-protected-resource      → これも来る
```

これらを 404 にすると **DCR が失敗し「サインインサービスへの登録ができませんでした」**。
→ 全部 **auth-staging に proxy** する (`src/discovery.ts`)。`cf-access-mcp/src/discovery.ts`
をコピーして slug を変えるだけ:

| origin endpoint | proxy 先 (auth-staging) |
|---|---|
| `GET /.well-known/oauth-authorization-server` | `GET /.well-known/oauth-authorization-server` (透過) |
| `GET /.well-known/oauth-protected-resource[/...]` | `GET /.well-known/oauth-protected-resource/<slug>` |
| `POST /register` | `POST /mcp/register` |

- AS metadata の `issuer` は **auth-staging のまま透過**する (= auth-staging が mint
  する token の `iss` と整合)。RFC 8414 §3.3 の「issuer == fetch 元 origin」は
  claude.ai が厳格 enforce しない (実証済)。
- discovery route は **認証なし** (binding_jwt middleware の前/外)。`/.well-known/*` と
  `/register` は `/mcp` 配下ではないので middleware に当たらない。
- CORS header は付けない (稼働サーバーと parity)。
- 未知 path は JSON `{"error":"not_found"}` で返す (`app.notFound`)。

> **「動く他 MCP に parity だから OK」を log で確認せず信じない。** ref-files が
> connector で動くのは **OAuth client が claude.ai 側に登録済 (cache) で fresh
> discovery を走らせていない**ため (log に OAuth traffic 0)。ref-files の
> `/.well-known/*` 404 は claude.ai から呼ばれないので無害だっただけで、新規
> connector の参照にはならない。新規 worker は §4 の proxy が必須。

## 5. CI / deploy

- CI は `ippoan/ci-workflows` の `frontend-ci.yml` (project_type: worker) か、
  examples なら専用 workflow。`npm_scope:'@ippoan'` + `permissions.packages:read`。
- deploy は echo-do-ws / cf-access-mcp と同じ「自前 wrangler deploy」パターン
  (`deploy-example-<name>.yml` が main push で `npx wrangler deploy`)。custom domain
  `<name>.ippoan.org` は wrangler が DNS+route 自動生成。
- PR / commit は **`Refs #N`** (auto-close 防止)。

## 6. テスト (vitest, DB/SDK 非依存)

`cf-access-mcp/test/` をコピー:
- `binding-jwt.test.ts` — header 欠落/不正 = `invalid_request`、active:false = `invalid_token`、
  503 fail-closed、middleware が WWW-Authenticate に `error="invalid_request"` を載せる。
- `discovery.test.ts` — 各 discovery を fake fetch で auth-staging に proxy、status/
  content-type 透過、対象外 path は null、CORS 無し。
- `tools.test.ts` / `tools-write.test.ts` / `scope.test.ts` — tool ロジック + scope gating。

SDK (`@modelcontextprotocol/sdk`) は重いので server.ts は `/mcp` 到達時に遅延 import。
テストは local src を直接 import するので SDK ロード不要。

## 7. 接続検証 (deploy 後、cf_logging で log loop)

1. `curl -i https://<name>.ippoan.org/.well-known/oauth-authorization-server` → 200
   (auth-staging AS metadata)、`POST /register` → 201 (client_id) を確認。
2. claude.ai で connector 追加。**URL は必ず `/mcp` 付き** (`https://<name>.ippoan.org/mcp`)。
   ルートだと `POST /` → 404 で OAuth が起動しない (mcp-cf-workers#26 で踏んだ罠)。
3. `cf_logging` (`query_worker_observability`) で `<name>` と `auth-worker-staging`
   両方の log を読み、OAuth chain を追う:
   `GET /mcp 401` → discovery 200 → `POST /mcp/register 201` → `GET /mcp/authorize 302`
   → GitHub → `/mcp/auth_callback` → `POST /mcp/token` → 認証付き `POST /mcp 200`。
   止まった段で原因が一意に分かる (deploy→再試行→log の高速ループ)。
4. 繋がらない時の切り分け順:
   - origin discovery が 404 → §4 未配線 (最頻)
   - connector URL に `/mcp` 無し → `POST /` 404 (log で判別)
   - allowlist 未追加 → protected-resource が 200 にならない (§3)
   - 既存失敗 connector の cache → claude.ai で connector 完全削除 → 新規追加

## 8. CCoW (Claude Code) から自分で叩きたい場合

claude.ai **web connector** と CCoW の **MCP user-scope** は別物。CCoW から
`mcp__<name>__*` を使うには `claude-hooks` の `session-start-write-mcp-user-scope.sh`
の MCP server 一覧に追加 (恒久) するか、auth-worker の `grant-via-oat` で binding_jwt を
mint して `claude mcp add --transport http <name> https://<name>.ippoan.org/mcp` (単発)。
write tool を使うなら `mcp.write` scope 入りの binding_jwt。詳細は `mcp-user-setup` skill。

## 参照

- 雛形: `ippoan/mcp-cf-workers` `examples/cf-access-mcp/`
- 設計根拠 / 接続解決の全記録: ippoan/mcp-cf-workers#26、epic #6、PoC #12
- factory: `@ippoan/mcp-cf-workers` `createWorkerMcp` (`src/factory.ts`)
- 関連 skill: `mcp-user-setup` (CCoW attach)、`secret-inject` (secret 投入)、
  `ippoan-infra-map` (基盤 5 repo の役割)、`auth-worker-map` (MCP OAuth Provider)
