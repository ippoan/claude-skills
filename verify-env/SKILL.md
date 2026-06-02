---
name: verify-env
description: main checkout の .env / wrangler / 本番デプロイ値が整合しているかを検証する skill。Nuxt/Cloudflare Workers プロジェクトで `.env` の誤記 → dev と prod で挙動が違う、の事故を防ぐ。トリガー:「env 確認」「verify env」「ローカル設定合ってる？」「本番と違う」「wrangler 見比べ」等。
---

# verify-env

**目的**: プロジェクトの public 環境変数 (`NUXT_PUBLIC_*` 系) が以下3箇所で整合しているかを機械的に検証する:

1. ローカル `.env` (dev で使用される値)
2. `wrangler.toml` / `wrangler.jsonc` の `[vars]` / `env.staging.vars` (deploy 時に使われる値)
3. **実デプロイの SSR HTML** (本番が本当に使っている値 — ground truth)

不整合があれば警告、無ければ ok を返す。

## 使い方

```bash
bash ~/.claude/skills/verify-env/scripts/verify-env.sh [project-path]
```

- 引数なし → カレントディレクトリ
- `.env` がなければ警告
- wrangler ファイルから production URL を検出し `curl` で SSR HTML を取得 → `apiBase` 等を抽出

## 出力例

```
=== nuxt-trouble ===
.env:
  NUXT_PUBLIC_API_BASE = https://alc.ippoan.org
wrangler.toml [vars]:
  NUXT_PUBLIC_API_BASE = https://alc-api.ippoan.org
production SSR (https://trouble.ippoan.org/):
  apiBase = "https://alc-api.ippoan.org"

⚠ MISMATCH
  .env      : https://alc.ippoan.org
  wrangler  : https://alc-api.ippoan.org
  prod live : https://alc-api.ippoan.org
  → .env を "https://alc-api.ippoan.org" に更新推奨
```

## 検出できない物

- サーバー側 env (Cloud Run / Secret Manager の値)
- `NUXT_*` (non-public) は SSR HTML に出ないので比較不可
- ビルド時定数 (`process.env.NODE_ENV`)

これらは別途確認が必要。

## 典型的トラブルパターン

1. **`.env` を作った時点で wrangler と違う URL を入れた** — 今回の発端
2. **wrangler 更新したが `.env` 追随し忘れ** — 逆パターン
3. **production が正しいが staging が古い** — minor mismatch、要 diff 表示
4. **deploy 済と wrangler の current が乖離** — 最後のタグからデプロイされていない

## 関連

- dev-proxy 経由の dev アクセスは `NUXT_PUBLIC_API_BASE` に依存 → この skill で先に確認しておく
- PR を出す前にも `/verify-env` で整合性チェックすると、.env うっかりコミットも検出
