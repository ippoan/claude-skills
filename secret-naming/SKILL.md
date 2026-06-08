---
name: secret-naming
description: >
  CF Secrets Store ↔ GCP Secret Manager の secret 命名規約 (SoT)。
  Cloudflare Secrets Store binding `secret_name` は kebab-case、
  GCP Secret Manager の secret 名は SCREAMING_SNAKE_CASE。同一 value を持つ
  secret は「pair」として GCP 側を先に rotate → CF/GH へ片方向 propagate する
  (alias drift 防止)。違反は claude-hooks の `secret-naming-guard.sh` が
  Write/Edit 時に非ブロッキングで警告する。
  トリガー:「secret 命名」「secret_name」「kebab か SCREAMING_SNAKE か」
  「wrangler secret 名」「GCP secret 名」「--update-secrets」「secret rotate 規約」
  「secret-verify name mismatch」「secrets-inventory#23」等。
---

# Secret 命名規約 (CF Secrets Store ↔ GCP Secret Manager)

ippoan の secret は **CF Secrets Store** と **GCP Secret Manager** の 2 箇所に
同一 value で登録されることがある (例: `secrets-inventory` Worker が verify する
shared API key)。両者で命名規則が違うため、規約を機械化して drift を防ぐ。

決定の経緯と却下案 (alias / rename / workflow name_map) は
[ippoan/secrets-inventory#23](https://github.com/ippoan/secrets-inventory/issues/23)。
結論は「**名前は揃えず規約として固定 → hook で違反を警告 → 随時修正**」。

## 規約 (これが SoT)

| 置き場 | 命名 | 例 |
|---|---|---|
| **CF Secrets Store** binding `secret_name` (`wrangler.jsonc`/`wrangler.toml`) | **kebab-case** (Cloudflare 慣例) | `secrets-inventory-gcp-proxy-api-key`, `cf-secrets-inventory-secrets-store-write`, `gh-secrets-inventory-org-secrets-write` |
| **GCP Secret Manager** secret 名 | **SCREAMING_SNAKE_CASE** | `SECRETS_INVENTORY_GCP_PROXY_API_KEY`, `SECRETS_INVENTORY_GCP_PROXY_API_KEY_STAGING` |
| Cloud Run env var 名 (`--update-secrets=ENV=SECRET:latest` の `ENV`) | **SCREAMING_SNAKE_CASE** (Go `mustEnv` に流すため GCP secret 名と揃える) | `INVENTORY_API_KEY=SECRETS_INVENTORY_GCP_PROXY_API_KEY_STAGING:latest` |

- kebab-case = `[a-z0-9-]` のみ (大文字・`_` を含めない)
- SCREAMING_SNAKE_CASE = `[A-Z0-9_]` のみ (小文字・`-` を含めない)
- staging suffix は GCP 側 `_STAGING` / CF 側 `-staging` と各々の casing に従う

## なぜ揃えない (alias / rename しない) のか

- GCP Secret Manager は **secret 名を rename できない** (resource ID 固定)。
  rename は delete + create + version 再投入 + Cloud Run `--update-secrets`
  書き換え + 再 deploy を要し、その間 staging が落ちうる。
- CF Secrets Store も rename 不可 (delete + create = 値の再投入)。
- alias (同 value を 2 名で併存) は **rotation で 2 名同時 bump** が永続化し、
  drift の余地が残る。
- → 名前は各プラットフォームの慣例のまま固定し、`secret-verify-gcp.yml` 等で
  突合する時は規約を前提に扱う。命名違反は code review より前に hook で気付く。

## rotation は片方向 (GCP → CF/GH)

「GCP が source of truth」原則 (各 repo の `CLAUDE.md`) に従い、同一 value の
pair を回すときは:

1. **GCP 側に新 version を先に投入** (`rotate_secret` / `add-version`)
2. その値を CF Secrets Store / GitHub Actions org secret へ **propagate**
   (`sync_from_gcp` MCP tool。値は proxy memory のみで取り回し、context/log に出さない)

人手で CF / GH を直接書き換えて GCP と食い違わせない。propagate は MCP tool が担う。
値の投入そのものは `secret-inject` skill (no-leak) を使う。

## hook による enforcement

claude-hooks の `secret-naming-guard.sh` (PreToolUse, matcher `Write|Edit`) が
**非ブロッキング**で警告する:

- `wrangler.{toml,jsonc,json}` の `secret_name` が kebab-case でない (大文字 / `_`)
- `--set-secrets` / `--update-secrets` / `gcloud secrets create` の GCP secret 名が
  SCREAMING_SNAKE_CASE でない (小文字 / `-`)

警告は deny せず additionalContext で出すだけ。既存の違反は **随時修正** していく
(一括 rename は上記の通り高コストなので段階的に潰す)。

## 関連

- `secret-inject` — 値を no-leak で GCP/CF/GitHub に投入・rotate する skill
- `secrets-inventory-map` / `secrets-inventory-gcp-map` — 該当 repo の構造マップ
- ci-workflows `secret-verify-gcp.yml` — CF binding 名と GCP secret 名を突合する CI
