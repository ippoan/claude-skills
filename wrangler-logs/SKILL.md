---
name: wrangler-logs
description: >
  Cloudflare Workers の **過去のリクエストメトリクス・ログ** を Cloudflare API で取得する skill。
  `wrangler tail` はストリーミング (今後の event のみ) で過去の調査ができないため、その代替。
  GraphQL Analytics API (`workersInvocationsAdaptive`) で datetime / status / requests /
  errors / duration / cpuTimeP50/P99 / wallTimeP50/P99 を取得し、`exceededResources` や
  `scriptThrewException` を強調表示する。Worker repo の cwd で実行すれば
  `wrangler.toml` から account_id、`.env` から `CLOUDFLARE_API_TOKEN` を自動検出する。
  Workers Observability (telemetry/query) で実ログ行を取りたい場合は wlogs-detail.sh、
  権限不足なら GraphQL に自動フォールバック。
  トリガー: 「wrangler ログ」「workers ログ」「CF ログ」「cloudflare ログ」「worker analytics」
  「exceeded resources」「503 worker」「worker が落ちてる」「CPU 超過」「過去のログ」
  「過去のリクエスト」「historical worker logs」「wrangler tail じゃなくて」「Worker メトリクス」等。
  bash ~/.claude/skills/wrangler-logs/scripts/wlogs.sh SCRIPT_NAME [MINUTES] で呼び出し可能。
---

# wrangler-logs — Workers の過去メトリクスを取得

`wrangler tail` は streaming で **過去** が見えないので、Cloudflare API を直叩きする
ラッパースクリプトを提供する。

## いつ使う

- 「30 分前から今まで dtako-admin worker でエラー出た？」
- 「auth-worker の CPU time が limit 超えてる気がする」
- 「Worker が 503 返してたって連絡があったが、tail はもう間に合わない」
- ステージング deploy 直後の挙動を後追い確認したい

`wrangler tail` を起動しても過去 event は出ない。代わりにこの skill。

## 使い方

```bash
# 最低限 (cwd が worker repo なら account_id / token は auto)
bash ~/.claude/skills/wrangler-logs/scripts/wlogs.sh dtako-admin 60

# 別ディレクトリから
bash ~/.claude/skills/wrangler-logs/scripts/wlogs.sh \
  --account-id 24b45709d060d957340180e995f0d373 \
  --token cfut_xxx \
  dtako-admin 30
```

第2引数は分単位 (default 30)。

### オプション

| flag | 効果 |
|---|---|
| `--account-id <id>` | wrangler.toml 自動検出を override |
| `--token <tok>` | env / .env 自動検出を override |
| `--json` | 整形せず生 JSON を出す (jq に pipe したい時) |
| `--raw` | Cloudflare API の生 response (debug 用) |

### 自動検出の優先順

1. **account_id**: `--account-id` → cwd → 親ディレクトリの `wrangler.toml` / `wrangler.jsonc`
   → `$CLOUDFLARE_ACCOUNT_ID` → cwd → 親 `.env`
2. **token**: `--token` → `$CLOUDFLARE_API_TOKEN` → cwd → 親 `.env` の `CLOUDFLARE_API_TOKEN`

worktree (`.claude/worktrees/<name>/`) の中で実行しても、親ディレクトリを遡って
worker repo root の `wrangler.toml` / `.env` を見つける。

## 出力例

```
Worker: dtako-admin  Account: 24b45709d060d957340180e995f0d373
Window: 2026-05-10T09:14:40Z  →  2026-05-10T10:14:40Z  (last 60 min)
Rows:   12
----
   2026-05-10T10:04:11Z status=success              reqs=1 errs=0 dur=3.75ms cpuP99=512ms wallP99=42446ms
!! 2026-05-10T09:49:49Z status=exceededResources    reqs=1 errs=1 dur=32.5ms cpuP99=32500ms wallP99=83779ms
   2026-05-10T09:47:05Z status=success              reqs=1 errs=0 dur=0.12ms cpuP99=12ms wallP99=986ms
----
Total: 17 requests, 1 errors   (exceededResources=1, scriptThrew=0, clientDisc=0)
```

- `!!` (TTY なら赤) = `exceededResources` / `scriptThrewException` (worker が limit 超え or throw)
- `~ ` (TTY なら黄) = `clientDisconnected`
- 無印 (TTY なら dim) = `success`
- 時刻は **microsecond 単位** で API から来る。表示は `ms` に丸めている (cpuP99=32500ms = 32.5s 相当 = CPU limit 超え)。

## status の意味

GraphQL `workersInvocationsAdaptive.dimensions.status` が取りうる値:

| status | 意味 | 対応 |
|---|---|---|
| `success` | 正常終了 | - |
| `clientDisconnected` | クライアント切断 (タイムアウト含む) | 呼び出し側のリトライ |
| `scriptThrewException` | コード内 throw / unhandled rejection | スタックトレース要 → wlogs-detail.sh |
| `exceededResources` | CPU/wall time limit 超過 (= 503) | ロジック軽量化 / batch 化 |
| `unknown` | 上記に当てはまらない | - |

## 詳細ログを見たい (実ログ行)

`scripts/wlogs-detail.sh` が Workers Observability の `telemetry/query` を叩いて
console.log 出力やスタックトレースを取得する:

```bash
bash ~/.claude/skills/wrangler-logs/scripts/wlogs-detail.sh dtako-admin 30
```

ただし `Workers Observability:Read` 権限が **トークンに必要**。
`wrangler login` で取れる `cfut_*` token には付かない。
権限不足なら自動的に `wlogs.sh` にフォールバックするよう案内が出る。

権限付きトークンを作るには Cloudflare Dashboard → My Profile → API Tokens で
`Account → Workers Observability → Read` を許可した custom token を発行し、
`.env` の `CLOUDFLARE_API_TOKEN` を差し替えるか `--token` で渡す。

## 内部仕様 (詳細)

GraphQL の `query` 全文・variable・response shape は
[references/graphql.md](references/graphql.md) を参照。

API がエラーを返した時のデバッグや、出力に新しい dimension を足したい時に読む。

## アンチパターン

- **`wrangler tail` を kick して "10分待つ"** — 過去は見えない。最初から wlogs.sh を使う
- **`timeout 60 wrangler tail` で過去を狙う** — tail は streaming なので無理
- **Cloudflare Dashboard を手動で開く** — script で 1 秒で取れる
- **本スクリプトに `wrangler` コマンドを呼ばせる** — wrangler に historical-log subcommand は存在しないので無意味
