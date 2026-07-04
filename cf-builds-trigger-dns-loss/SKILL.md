---
name: cf-builds-trigger-dns-loss
description: production custom domain (例 trouble.ippoan.org) の DNS/証明書が突然消える事象の調査手順と、Workers Builds (GitHub 連携) の trigger 付け外し操作との相関パターン。cf-access-mcp の `list_audit_logs` tool で Cloudflare Audit Log (v2 API, `/logs/audit`) を引く実機手順と、その罠 (旧 `/audit_logs` は 404 相当で使えない、v1→v2 でクエリパラメータ名が変わる `actor.email`→`actor_email` 等、`since`/`before` が実は必須で公式ドキュメントの「全 optional」記載と食い違う) をまとめる。ippoan/nuxt-trouble#185 と 2026-07-04 の再現事例から、「dashboard で Workers Builds の repos.connections / trigger を作成→削除する操作」の後続で「同一 zone の別 worker (preview 等) への deploy」が走ると、無関係なはずの本番 custom domain の AAAA レコード・証明書が system actor により巻き込まれて削除される、というパターンを記録する。トリガー:「custom domain 消えた」「DNS消えた」「trouble.ippoan.org 見れない」「証明書 消えた」「builds 連携 外した」「Workers Builds trigger」「repos.connections」「list_audit_logs」「Audit Log 400」「Account Settings Read scope」「CF Audit Log v2」「10000 Authentication error」等。
---

# Custom domain の DNS/証明書消失を Audit Log で調査する

production custom domain (例 `trouble.ippoan.org`) が突然「見れなくなった」時、
**Cloudflare の Audit Log を `list_audit_logs` (cf-access-mcp MCP tool) で
直接調査できる** (dashboard の Audit Log 画面を手で見に行かなくて済む)。

## 1. まず `list_audit_logs` を正しく呼ぶ (実機の罠 3 点)

`GET /accounts/{account_id}/logs/audit` (v2) には以下の罠がある。知らずに
叩くと「permission 不足」だと誤診断しやすい (実際は path/parameter 誤り):

| 症状 | 原因 | 対処 |
|---|---|---|
| `CF API error: 10000: Authentication error` | 旧 v1 path `/audit_logs` を叩いている (v2 は別 path) | `/logs/audit` を叩く (tool 側は既に修正済み、tool 自体を疑う前に token scope を先に疑わない) |
| `HTTP 400` (token は有効、他の read tool は動く) | v1 のクエリパラメータ名 (`actor.email` / `resource.product` / `per_page` / `page`) のまま叩いている | v2 は `actor_email` / `resource_product` / `limit` / `cursor` (cursor ベースページング) |
| `HTTP 400 "query parameter 'since'/'before' is required"` | **CF 公式ドキュメントは全パラメータ optional と書いているが、実機では since/before 両方必須** | 呼ぶ時は必ず `since` と `before` (ISO8601) を指定する |

```jsonc
// 正しい呼び方 (since/before 必須)
list_audit_logs({
  since: "2026-07-04T08:00:00Z",
  before: "2026-07-04T12:00:00Z",
  resource_product: "dns", // dns / workers / certificates / builds / access 等で絞り込み
})
```

CF API token には **`Account Settings: Read`** scope が必要。トークン発行 UI で
"Audit Logs" と検索して出てくる `Access: Audit Logs Read` は **Zero Trust
Access の認証ログ専用 permission で無関係** — これを付与しても 403/10000 の
まま動かない (2026-07-04 実機で確認、詳細は `ippoan/mcp-cf-workers` の
`examples/cf-access-mcp/README.md` 参照)。

`limit` のような number 型引数は、tool schema がセッション内でキャッシュされ
古いままだと string としてシリアライズされ `invalid_type` エラーになることが
ある (Claude Code が `list_changed` 通知を消費しない既知の制限)。再現したら
`limit`/`cursor` を省略して `since`/`before` だけで呼ぶ。

## 2. custom domain 消失の診断手順

```jsonc
// 1. 対象時間帯を dns product で絞って見る (JST→UTC 変換に注意、+9h)
list_audit_logs({ since: "<事象前 1h>", before: "<事象後 1h>", resource_product: "dns" })
```

結果から `resource.value.name` (レコード FQDN) で対象ドメインを検索し、
`delete`→`create` の対 (= 消えて戻った) を見つける。`actor.type: "system"`
なら人間の直接操作ではなく Cloudflare 内部プロセスによる自動削除/再作成。

```jsonc
// 2. 同時刻の workers / certificates / builds product も見る (resource_product 省略で全体)
list_audit_logs({ since: "<delete の 1h 前>", before: "<delete 時刻>" })
```

`resource.product: "workers"` の `Post Worker subdomain` / `Create Deployment`
(= custom domain routing を持つ別 worker への deploy) が DNS delete の直前に
無いか確認する。`resource.product: "builds"` の `Delete trigger` /
`Create or update repository connection` (= dashboard での Workers Builds
GitHub 連携操作) が、その **30〜60 分前** に無いか遡って確認する。

## 3. 観測されたパターン: Workers Builds trigger 付け外し → 後続 deploy で無関係な custom domain が消える

`ippoan/nuxt-trouble#185` (初回) と 2026-07-04 (再現) の 2 事例で同じ形の
タイムラインが確認された:

```
[dashboard] Workers Builds の repos.connections 再構成
  → trigger を create → (数分後) delete  ← GitHub 連携を外す操作 (product: builds)
        │
        │ (30〜60分後)
        ▼
[CI] 同一 zone 内の別 worker (preview 環境等) への deploy
  → Post Worker subdomain (custom domain routing 更新)
        │
        ▼
[system] 本番 custom domain (別 worker の) の AAAA レコード + 証明書パックが
         削除される (actor.type: "system"、人間の操作ではない)
        │
        │ (30〜60分後、自動)
        ▼
[system] AAAA レコードが再作成される (証明書は再発行が必要な場合もある)
```

**再現条件の仮説**: 同一 zone (例 `ippoan.org`) に **preview と本番の custom
domain を同居**させている場合、Workers Builds の GitHub 連携を切り替える操作
(特に trigger の作成→削除) が zone 内の custom domain ルーティング状態に
副作用を残し、その後の**別 worker への deploy** が、無関係なはずの他 worker
の custom domain 設定を巻き込んで削除してしまう。監査ログ上は
`system` actor による削除としか見えず、直接の API 呼び出し元 (どの deploy が
引き金か) は特定できないが、時間的な相関は 2 回とも一貫している。

### 対処 / 予防

- Workers Builds の GitHub 連携 (`repos.connections` / trigger) を dashboard
  で触った後は、**同一 zone の他 worker の custom domain が無事か**を数十分
  以内に確認する
- 消失を検知したら `list_audit_logs` で `resource_product: "certificates"` も
  確認する (証明書パックが `deleted` 状態になっていないか、再発行が必要かの
  判断に使う)
- 本番と preview の custom domain を **別 zone に分離**できるならその方が
  安全 (根本対策、要検討・未実施)

## 参照

- `ippoan/mcp-cf-workers#51` — `list_audit_logs` tool 追加 issue、v1/v2 罠の詳細
- `ippoan/mcp-cf-workers` PR #53/#54/#55 — path/パラメータ/since-before 必須化の実装修正
- `ippoan/nuxt-trouble#185` — 初回の custom domain 消失事象 (builds/triggers delete が引き金と特定)
