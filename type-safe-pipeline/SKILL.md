---
name: type-safe-pipeline
description: >
  フロントエンドプロジェクトに ts-rs 型安全パイプラインを導入するスキル。
  CI で rust-alc-api の型を自動同期し、tsc エラー 0 を強制する。
  トリガー: /type-safe-pipeline <project>
user_invocable: true
---

# 型安全パイプライン導入

引数で指定されたフロントエンドプロジェクトに、rust-alc-api の ts-rs 型安全パイプラインを導入する。

## 引数

- `auth-worker` → `/home/yhonda/js/auth-worker`
- `alc-app` → `/home/yhonda/js/alc-app`
- `dtako-admin` → `/home/yhonda/js/nuxt-dtako-admin`
- `carins` → `/home/yhonda/js/nuxt-pwa-carins`
- `ichibanboshi` → `/home/yhonda/js/nuxt-ichibanboshi`

## 実行手順

### 1. 現状調査

- ts-rs 型ファイルの有無 (`types/alc-api.ts` or `types/generated/*.ts`)
- CI workflow の有無と内容
- `tsc --noEmit` / `nuxi typecheck` の結果
- `unknown` 型の箇所 (grep `await.*\.json()` で型引数なしを検索)

### 2. スクリプト追加

- `scripts/export-ts-bindings.sh` を rust-alc-api からコピー
- Workers の場合: `wrangler types` で `worker-configuration.d.ts` 生成

### 3. CI 更新 (`.github/workflows/test.yml`)

Workers の場合:
```yaml
- run: npx wrangler types
- name: Sync ts-rs types from rust-alc-api
  run: bash scripts/export-ts-bindings.sh src/types
  env:
    GH_TOKEN: ${{ github.token }}
- name: Type check
  run: npx tsc --noEmit && npx tsc -p test/tsconfig.json --noEmit
```

Nuxt の場合:
```yaml
- name: Sync ts-rs types from rust-alc-api
  run: bash scripts/export-ts-bindings.sh app/types
  env:
    GH_TOKEN: ${{ github.token }}
- name: Type check
  run: npx nuxi typecheck
```

**全ジョブ (test, integration-test 等) に追加すること。**

### 4. 型エラー修正

- `res.json()` → `res.json<Type>()` に型引数追加
- `Object is possibly 'undefined'` → `!` non-null assertion
- 必要なら Rust 側に camelCase レスポンス型を `#[ts(rename_all = "camelCase")]` で追加

### 5. defensive branch 削除

- `|| []`, `|| "fallback"` など backend が返さないレスポンスへの fallback を削除
- 対応する mock-only テスト (`if (isLive) return`) も削除

### 6. 検証

- `tsc --noEmit` (または `nuxi typecheck`) → 0 エラー
- `vitest run` → 全 pass
- CI push → 全ジョブ pass

### 7. PR 作成

## 設計原則

- **unknown 禁止** — `res.json<Type>()` で ts-rs 生成型を使う
- **defensive branch 禁止** — backend が返さないレスポンスの fallback は書かない
- **CI で型検証** — backend の型変更が frontend を壊したら CI fail
- **ts-rs が single source of truth** — Rust struct → TypeScript 型の一方向生成

## 参照

- 計画: `plans/cached-tickling-hennessy.md`
- Worker パターン: `/worker-vitest`
- Nuxt パターン: `/nuxt-vitest`
- 実装例: auth-worker PR #5, #6
