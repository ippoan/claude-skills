---
name: nuxt-vitest
description: >
  Nuxt 4 + Vitest のテスト作成・修正・カバレッジ改善スキル。
  composable/utils のユニットテスト、カバレッジ 100% 達成、スキップテスト修正に使用。
  トリガー: 「テスト書いて」「テスト追加」「カバレッジ」「coverage」
  「テスト修正」「fix test」「skipped test」「100%」「vitest」等。
---

# Nuxt + Vitest テストスキル

Nuxt 4 プロジェクトの Vitest テスト作成・カバレッジ改善の実証済みパターン集。

## ワークフロー

1. **ソースを読む** — 対象ファイル (`app/composables/` or `app/utils/`) の全ブランチ、モジュールスコープ状態、ブラウザ API 使用を把握
2. **パターン特定** — 下記テーブルから該当パターンを選択。複数該当する場合は組み合わせる
3. **テスト作成** — `tests/composables/useXxx.test.ts` or `tests/utils/xxx.test.ts` に作成
4. **検証** — `npm test` → `npm run test:coverage` → `node scripts/check_coverage_100.mjs`

## テスト実行コマンド

```bash
# 全テスト
npm test

# 単一ファイル
npx vitest run tests/composables/useXxx.test.ts

# カバレッジ
npm run test:coverage

# 100% リグレッション検出
node scripts/check_coverage_100.mjs
```

## モックパターン選択ガイド

| シナリオ | パターン | 詳細 |
|---------|---------|------|
| Pure util (外部依存なし) | 直接 import、モック不要 | [P1](references/patterns.md#1-pure-utils) |
| API 呼び出し composable | `vi.mock('~/utils/api')` | [P2](references/patterns.md#2-api-mock-composable) |
| ブラウザ API (Serial/BLE/NFC) | `Object.defineProperty(navigator, ...)` | [P3](references/patterns.md#3-browser-api-mock) |
| Android bridge | `(window as any).Android = {...}` | [P4](references/patterns.md#4-android-bridge-mock) |
| Nuxt auto-import (useRoute 等) | `mockNuxtImport()` + `vi.hoisted()` | [P5](references/patterns.md#5-nuxt-auto-import-mock) |
| モジュールスコープ状態 (singleton) | `vi.resetModules()` + dynamic import | [P6](references/patterns.md#6-module-scope-state-isolation) |
| onMounted / onUnmounted | `withSetup()` ヘルパー | [P7](references/patterns.md#7-withsetup-helper) |
| Worker (postMessage) | MockWorker + `vi.stubGlobal` | [P8](references/patterns.md#8-async-composable-worker) |
| WebSocket | MockWebSocket + `vi.stubGlobal` | [P9](references/patterns.md#9-mockwebsocket) |
| Fake timers | `vi.useFakeTimers({ toFake: [...] })` | [P10](references/patterns.md#10-fake-timers) |
| API mock + live 両対応 | `api-test-env.ts` ヘルパー | [P11](references/patterns.md#11-api-dual-mode) |
| Vue テンプレートブランチ | 子コンポーネント抽出 | [P14](references/patterns.md#14-vue-コンポーネント-v8-ブランチカバレッジ) |

## カバレッジルール

- **`v8 ignore` 禁止** — `/* v8 ignore next */` は使わない。テスト追加 or リファクタで対処
- **SSR ガード**: `if (import.meta.client)` は `onMounted` 内に移動するか削除 ([P12](references/patterns.md#12-ssr-guard))
- **到達不能ブランチ**: 常に true/false の条件はリファクタで除去 ([P13](references/patterns.md#13-unreachable-branch))
- **coverage_100.toml**: 100% 達成時に `[[files]]` + `branches = true` で登録

## よくあるピットフォール

| 問題 | 原因 | 対策 |
|------|------|------|
| `ws.close()` 後の状態チェック失敗 | MockWebSocket の `close()` が同期的に `onclose` を発火 | `close()` **前**にチェック |
| Fake timers でタイムアウト | happy-dom が `navigator`, `WebSocket` と干渉 | `toFake` で必要なタイマーだけ指定 |
| happy-dom が native API を上書き | `save-native.ts` の順序 | `setupFiles` で最初に配置 |
| useState がテスト間でリーク | Nuxt の shared state | `beforeEach` でリセット |
| テストデータ ID で 400 | fake ID (`'s1'` 等) | 有効な UUID を使用 |
| `toBe` でオブジェクト比較失敗 | 参照比較になる | `toStrictEqual` を使用 |
| `require()` で ESM エラー | Vitest は ESM | `import()` を使用 |

## CI 連携

- **Workflow**: `.github/workflows/test.yml` — push/PR to main でトリガー
- **Pipeline**: `npm ci` → ts-rs 型同期 → `vitest run --coverage` → `check_coverage_100.mjs` → Job Summary → artifact
- **ブランチワークフロー**: main 直接 push 禁止 → branch → PR → `gh pr merge --squash --auto`
- **WASM スタブ**: CI では wasm-pack 不要 (ダミー package.json + index.js で代替)

### 型安全パイプライン (ts-rs)

rust-alc-api の ts-rs 型を CI で自動同期し、型エラーを検出する。

```yaml
# .github/workflows/test.yml に追加
- name: Sync ts-rs types from rust-alc-api
  run: bash scripts/export-ts-bindings.sh app/types
  env:
    GH_TOKEN: ${{ github.token }}
- name: Type check
  run: npx nuxi typecheck
```

- **unknown 禁止**: `res.json()` の戻り値には ts-rs 生成型を型引数で指定
- **defensive branch 禁止**: backend が返さないレスポンスに対する `|| []` 等は書かない
- 型の流れ: Rust `#[derive(TS)]` → `cargo test` → CI artifact → `export-ts-bindings.sh` → `app/types/generated/`

## テスト環境構成

```
vitest.config.ts              # Nuxt 環境 + happy-dom + カバレッジ設定
tests/
  setup.ts                    # fake-indexeddb セットアップ
  save-native.ts              # Node.js native API 保存 (happy-dom 上書き前)
  helpers/
    with-setup.ts             # composable を Vue コンポーネントコンテキストで実行
    api-test-env.ts           # mock/live 切り替え + fetch スタブ
    api-test-data.ts          # テストデータ一元管理 (ID, リクエストボディ)
  mocks/
    fc1200-wasm.ts            # WASM モジュールのモック (CI 用)
  fixtures/
    seed.sql                  # live テスト用 DB シードデータ
  composables/                # composable テスト
  utils/                      # util テスト
  middleware/                 # middleware テスト
  integration/                # 統合テスト
coverage_100.toml             # 100% 達成ファイル登録簿
scripts/check_coverage_100.mjs # リグレッション検出スクリプト
```
