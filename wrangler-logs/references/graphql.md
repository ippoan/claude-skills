# Cloudflare Workers GraphQL Analytics — wlogs.sh 内部仕様

`wlogs.sh` が叩いている API と response 形式の詳細。新しい dimension / metric を
追加したい時、API がエラーを返した時のデバッグ用。

## エンドポイント

```
POST https://api.cloudflare.com/client/v4/graphql
Authorization: Bearer <CLOUDFLARE_API_TOKEN>
Content-Type: application/json
```

`wrangler login` で発行される `cfut_*` token は最低限の Analytics 権限を持っているので
そのまま使える (Workers Observability 用ではない)。

## Query

```graphql
query($accountTag: String!, $start: Time!, $end: Time!, $scriptName: String!) {
  viewer {
    accounts(filter: {accountTag: $accountTag}) {
      workersInvocationsAdaptive(
        limit: 200,
        filter: {datetime_geq: $start, datetime_leq: $end, scriptName: $scriptName},
        orderBy: [datetime_DESC]
      ) {
        dimensions { datetime status scriptName }
        sum { requests errors duration }
        quantiles { cpuTimeP50 cpuTimeP99 wallTimeP50 wallTimeP99 }
      }
    }
  }
}
```

### Variables

| name | type | meaning |
|---|---|---|
| `accountTag` | String | Cloudflare account ID (32-char hex, `wrangler.toml` の `account_id`) |
| `start` / `end` | Time (ISO8601 UTC) | `2026-05-10T09:14:40Z` のような形式 |
| `scriptName` | String | Worker script name (`wrangler.toml` の `name`、staging suffix も含む) |

### `filter`

GraphQL Analytics は `_geq` / `_leq` / `_gt` / `_lt` / `_in` 等の suffix で範囲指定する。
複数 status で絞りたい場合は `status_in: [scriptThrewException, exceededResources]`。

## Response 形式

```json
{
  "data": {
    "viewer": {
      "accounts": [
        {
          "workersInvocationsAdaptive": [
            {
              "dimensions": {
                "datetime": "2026-05-10T10:04:11Z",
                "status": "success",
                "scriptName": "dtako-admin"
              },
              "sum": {
                "requests": 1,
                "errors": 0,
                "duration": 3.75
              },
              "quantiles": {
                "cpuTimeP50": 512208,
                "cpuTimeP99": 512208,
                "wallTimeP50": 42446000,
                "wallTimeP99": 42446000
              }
            }
          ]
        }
      ]
    }
  },
  "errors": null
}
```

### 単位の罠

| field | 単位 | 例 |
|---|---|---|
| `sum.duration` | **GB-second** (compute cost) | 3.75 = 3.75 GB-s。CPU/wall time とは別の課金指標 |
| `sum.requests` | 整数 | リクエスト数 |
| `sum.errors` | 整数 | error 扱いになった件数 |
| `quantiles.cpuTimeP50/P99` | **microseconds** | 512208 = 512.2 ms |
| `quantiles.wallTimeP50/P99` | **microseconds** | 42446000 = 42.4 s |

`cpuTimeP99` が 30000000 (= 30s) 以上なら大体 `exceededResources` と一致する。
Free plan の CPU limit は 10ms / Paid plan は 30s。

### `dimensions.status` enum

実測で観測している値:

- `success`
- `clientDisconnected` — クライアントが切断 (タイムアウト含む)
- `scriptThrewException` — `throw` / unhandled rejection
- `exceededResources` — CPU/wall limit 超過 (HTTP 503)
- `unknown`

他に Cloudflare doc では `scriptNotFound` 等が出ることがあるが、稀。

## エラー時の response

GraphQL なので status code は 200 のまま `errors` 配列が入る:

```json
{
  "data": null,
  "errors": [
    { "message": "Authentication error", "path": [...], "extensions": {...} }
  ]
}
```

`wlogs.sh` は `.errors` の有無で検出して exit 4 する。

## カスタマイズしたい時

| やりたいこと | 変更箇所 |
|---|---|
| 1分粒度に bucketing | `workersInvocationsAdaptive` を `workersInvocationsAdaptiveGroups` に変えて `dimensions` に `datetimeMinute` を追加 |
| route / hostname 別 | `dimensions` に `clientRequestHTTPHost` を追加 (使えるかは plan 依存) |
| エラーのみ表示 | `filter` に `status_in: [scriptThrewException, exceededResources]` を足す |
| 24h / 7d window | shell の `MINUTES` を `1440` / `10080` に増やす。Free plan は 24h、Paid plan は 7d / 30d 保持 |

## 公式 doc

- GraphQL Analytics overview: https://developers.cloudflare.com/analytics/graphql-api/
- Workers metrics: https://developers.cloudflare.com/analytics/graphql-api/tutorials/querying-workers-metrics/
- Schema explorer: https://developers.cloudflare.com/analytics/graphql-api/getting-started/explore-graphql-schema/
