---
name: worker-vitest
description: >
  Cloudflare Workers / フロントエンドプロジェクトの Vitest テスト作成・統合スキル。
  mock/live 統一テスト、REST proxy ハンドラーテスト、カバレッジ 100% 達成に使用。
  トリガー: 「テスト書いて」「テスト追加」「カバレッジ」「coverage」
  「mock/live」「stubOrReal」「worker テスト」「ハンドラーテスト」等。
---

# Worker / Frontend Vitest テストスキル

Cloudflare Workers およびフロントエンドプロジェクトの Vitest テスト作成・カバレッジ改善パターン集。
Nuxt 以外のプロジェクト (Workers, vanilla TS) で使用。Nuxt プロジェクトは `nuxt-vitest` スキルを使用。

## 設計原則

1. **1つの `it()` が mock/live 両方で動く** — `stubOrReal()` で切り替え
2. **exact value assert** — `created_at`/`updated_at` だけ `typeof` チェック、他は全て exact
3. **テスト内 CRUD** — seed 不要、テスト自身が upsert → assert → delete
4. **カバレッジ 100%** — mock/live 両方で要求。live で漏れがあれば CI fail
5. **unknown 禁止** — `res.json<Type>()` で ts-rs 生成型を型引数に使う。`as` キャストや `unknown` 放置は禁止
6. **defensive branch 禁止** — backend が返さないレスポンスに対する `|| []` や `|| "fallback"` は書かない。到達不能ブランチはプロダクトコードから削除する

## 型安全パイプライン

rust-alc-api の ts-rs 型を自動で frontend に同期し、型エラーを CI で検出する。

### 型の流れ

```
Rust struct (#[derive(TS)])
  → #[ts(export)]                    snake_case (backend API 型)
  → #[ts(export, rename_all = "camelCase")]  camelCase (handler レスポンス型)
  → cargo test で bindings/ に .ts 出力
  → CI artifact にアップロード
  → export-ts-bindings.sh で frontend に同期
  → tsc --noEmit で型チェック
```

### CI パイプライン

```yaml
# .github/workflows/test.yml
- run: npx wrangler types                        # worker-configuration.d.ts 生成
- run: bash scripts/export-ts-bindings.sh src/types  # rust-alc-api から型同期
  env:
    GH_TOKEN: ${{ github.token }}
- run: npx tsc --noEmit && npx tsc -p test/tsconfig.json --noEmit  # 型チェック
- run: npm run test:coverage                      # テスト + カバレッジ
- run: node scripts/check_coverage_100.mjs        # 100% リグレッション検出
```

### tsconfig 構成

```jsonc
// tsconfig.json (src)
{
  "compilerOptions": {
    "target": "ES2022", "module": "ESNext", "moduleResolution": "bundler",
    "strict": true, "noUncheckedIndexedAccess": true,
    "rootDir": "./src"
  },
  "include": ["src/**/*", "worker-configuration.d.ts"]
}

// test/tsconfig.json
{
  "extends": "../tsconfig.json",
  "compilerOptions": {
    "rootDir": "..", "noEmit": true,
    "types": ["@cloudflare/vitest-pool-workers", "node"]
  },
  "include": ["./**/*.ts", "./env.d.ts", "../src/**/*.ts", "../worker-configuration.d.ts"]
}
```

### ts-rs 型の使い方

```typescript
// src/types/alc-api.ts (自動生成)
export type SsoConfigRow = { provider: string, client_id: string, ... };        // backend API
export type SsoConfigMapped = { provider: string, clientId: string, ... };      // handler response (camelCase)

// src/handlers/api-sso.ts
import type { SsoConfigListResponse, SsoConfigRow } from "../types/alc-api";
const data = await resp.json<SsoConfigListResponse>();  // ← unknown 禁止

// test/handlers/api-sso.test.ts
import type { SsoConfigMapped } from "../../src/types/alc-api";
const data = await res.json<{ configs: SsoConfigMapped[] }>();  // ← unknown 禁止
```

## ワークフロー

1. **ソースを読む** — 対象ハンドラーの全分岐 (認証チェック、バリデーション、成功、エラー) を把握
2. **パターン特定** — 下記パターンから該当を選択
3. **テスト作成** — `test/handlers/*.test.ts` に作成
4. **検証** — `npx vitest run --coverage` (mock) → `ALC_API_URL=... npx vitest run --coverage` (live)

## テスト実行コマンド

```bash
# mock モード (CI デフォルト)
npx vitest run --coverage

# 単一ファイル
npx vitest run test/handlers/api-sso.test.ts

# live モード (要 docker compose)
docker compose -f docker-compose.test.yml up -d
ALC_API_URL=http://localhost:18081 npx vitest run --coverage
docker compose -f docker-compose.test.yml down
```

## パターン選択ガイド

| シナリオ | パターン | 詳細 |
|---------|---------|------|
| REST proxy ハンドラー (mock/live) | `stubOrReal` + in-test CRUD | [P1](references/patterns.md#1-rest-proxy-handler) |
| 認証チェック (401/403) | Token extraction テスト | [P2](references/patterns.md#2-auth-check) |
| バリデーション (400) | 必須フィールド欠落テスト | [P3](references/patterns.md#3-validation) |
| エラーパススルー | Backend エラー転送テスト | [P4](references/patterns.md#4-error-passthrough) |
| フィールドマッピング | snake_case → camelCase 変換 | [P6](references/patterns.md#6-field-mapping) |
| ルーターテスト | 全ルート疎通確認 | [P7](references/patterns.md#7-router-test) |

## ファイル構成

```
worker-configuration.d.ts   # wrangler types で自動生成
src/types/
  alc-api.ts                # export-ts-bindings.sh で rust-alc-api から同期
scripts/
  export-ts-bindings.sh     # CI artifact から ts-rs 型を取得
test/
  helpers/
    stub-or-real.ts         # stubOrReal(), testEnv(), authRequest() 等
    mock-env.ts             # createMockEnv() — Env ファクトリ
    live-env.ts             # isLive, makeJwt(), waitForApi()
  handlers/                 # ハンドラー単位テスト (mock/live 統一)
  integration/              # ルーターテスト
```

## カバレッジルール

- **`v8 ignore` 禁止** — テスト追加 or リファクタで対処
- **coverage_100.toml**: 100% 達成時に登録
- **mock/live 両方で 100%**: mock だけ 100% では不十分。live でも全ブランチカバー必須
- **defensive branch 禁止**: live で到達不能なブランチはプロダクトコードから削除する

## よくあるピットフォール

| 問題 | 原因 | 対策 |
|------|------|------|
| `res.json()` が `unknown` | 型引数なし | `res.json<Type>()` で ts-rs 型を指定 |
| live で branches < 100% | `if (isLive) return` で mock-only テスト | defensive branch をプロダクトコードから削除 |
| live で `typeof` チェックだらけ | mock/live 別々に書いた名残 | exact value assert に統一 |
| seed.sql 依存でテスト壊れやすい | テストデータ外部依存 | テスト内で upsert → assert → delete |
| mock テストが live で落ちる | mock レスポンスと実 API の乖離 | live で動かして乖離を検出 |
| `created_at` の exact assert 失敗 | DB 生成タイムスタンプ | `typeof` チェックに限定 |
| CI で型が古い | backend 型変更が frontend に反映されない | CI で export-ts-bindings.sh + tsc |
