---
name: ci-cache-patterns
description: "Rust + GitHub Actions CI のキャッシュ戦略設計スキル。sccache / swatinem/rust-cache / Docker layer cache の選定・設定・組み合わせパターンを提供する。トリガー: CI ワークフロー作成、GitHub Actions のビルド時間最適化、CI 遅い、キャッシュ、sccache、rust-cache、Docker キャッシュ、ビルド時間、CI 高速化。"
---

# CI Cache Patterns for Rust Projects

## 選定フローチャート

```
CI ビルド高速化が必要
├─ cargo build / cargo test → sccache (GHA backend) + swatinem/rust-cache
├─ cargo llvm-cov → nextest で --lib --test を 1 コマンドに統合
├─ Docker イメージ作成 → CI runner でビルド + Docker は COPY のみ
└─ 新ジョブ追加 → 既存ジョブのキャッシュを再利用できるか確認
```

## ツール選定ガイド

| ツール | キャッシュ対象 | 判定方式 | workspace crate |
|---|---|---|---|
| **sccache** | rustc コンパイル成果物 | チェックサム | **○ 正しくヒット** |
| swatinem/rust-cache | target/ + registry | mtime | × デフォルトで削除 |
| Docker layer cache | Docker イメージ層 | layer hash | - |

**原則: sccache を最優先。** swatinem/rust-cache は registry ダウンロード高速化の補助。

## 基本パターン

### 1. cargo build / cargo test

```yaml
- uses: mozilla-actions/sccache-action@v0.0.9
- name: Build
  env:
    SCCACHE_GHA_ENABLED: "true"
    RUSTC_WRAPPER: "sccache"
  run: cargo build --release
```

### 2. cargo llvm-cov (テスト + カバレッジ)

```yaml
# 1コマンドで lib + test を同時実行 (2回コンパイル回避)
cargo llvm-cov nextest --no-report --lib --workspace --test mock_xxx
```

### 3. Docker イメージ

```yaml
# CI runner でビルド (sccache) → Docker は COPY のみ
- name: Build
  env:
    SCCACHE_GHA_ENABLED: "true"
    RUSTC_WRAPPER: "sccache"
  run: cargo build --release
- uses: docker/build-push-action@v6
  with:
    context: docker-context
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

## 注意事項

- **sccache と cargo llvm-cov は RUSTC_WRAPPER が競合** → 同一ジョブで両方使わない
- **swatinem/rust-cache は workspace crate をデフォルトで削除** → 差分ビルドには sccache を使う
- **並列ジョブ追加時**: sccache は各ジョブで独立に動作。main ブランチのキャッシュを全ブランチが参照可能
- **`Swatinem/rust-cache@v2` の `save-if` default は default branch のみ** → `release.yml` 等
  tag push (`refs/tags/v*`) で起動する workflow は default で **一度も save されない**。
  tag push でも save したい場合は明示的に override:
  ```yaml
  save-if: ${{ github.ref == format('refs/heads/{0}', github.event.repository.default_branch) || startsWith(github.ref, 'refs/tags/v') }}
  ```
  reusable workflow に sccache + rust-cache を入れただけだと「動いているように見えて save されていない」
  状態が長期間 (例: ippoan/ci-workflows#10、reusable 導入から 3 日間 cold が継続) 続くので注意。
- **`shared-key` 変更 / top-level env への変数追加は cache key を変える** → 過去 cache が一度
  捨てられて clean slate になり、その run 自体は cold で完了。本命の効果は **次の run** で初めて
  数字に出る。具体的に効くもの:
  - `shared-key` の文字列変更 (例: `${{ inputs.bin_name }}` → `${{ inputs.bin_name }}-${{ matrix.t.target }}`)
  - top-level `env:` への新変数追加 (例: `RUSTC_WRAPPER` を追加すると rust-cache の
    `add-rust-environment-hash-key: true` (default) によって env hash が変わり key 末尾が再 base 化)

  → cache 戦略変更を投入した直後の 1 run で「効いていない」と判断せず、**最低 2 release
  (= 1 回 priming + 1 回 hit 検証) を待ってから評価**する。

## 詳細リファレンス

設定例、実測ベンチマーク、Docker 内ビルドの比較表、nightly checksum-freshness については [patterns.md](references/patterns.md) を参照。
