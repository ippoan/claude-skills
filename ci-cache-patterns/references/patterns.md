# CI Cache Patterns — 詳細リファレンス

## Table of Contents
- [sccache (rustc レベルキャッシュ)](#sccache)
- [swatinem/rust-cache (target/ キャッシュ)](#swatinem)
- [Docker ビルドキャッシュ](#docker)
- [cargo llvm-cov + nextest 最適化](#llvm-cov)
- [cargo nightly checksum-freshness](#nightly)
- [実測値](#benchmarks)

## sccache

### なぜ sccache か

- rustc 呼び出しをラップし、**入力のチェックサム** でキャッシュ判定
- mtime に依存しない → git checkout 後でも正しくキャッシュヒット
- GitHub Actions Cache API を直接使用 → ブランチ間でキャッシュ共有

### 設定

```yaml
- uses: mozilla-actions/sccache-action@v0.0.9

- name: Build
  env:
    SCCACHE_GHA_ENABLED: "true"
    RUSTC_WRAPPER: "sccache"
  run: cargo build --release
```

### ブランチ間キャッシュ共有ルール (GitHub Actions)

- main のキャッシュ → 全ブランチから参照可能
- PR のキャッシュ → 同一 PR の再実行のみ参照可能

### キャッシュパージ

`SCCACHE_GHA_VERSION` 環境変数を変更するとキャッシュが無効化される。

### 制約

- `cargo llvm-cov` の `RUSTC_WRAPPER` と競合する
- release build で `CARGO_INCREMENTAL=0` (デフォルト) なら sccache と互換

### 参照
- https://github.com/Mozilla-Actions/sccache-action
- https://depot.dev/blog/sccache-in-github-actions
- https://github.com/mozilla/sccache

## swatinem

### 用途

- cargo registry (crates.io ソース) のダウンロード時間短縮
- 外部 crate のコンパイル済み .rlib キャッシュ

### 設定

```yaml
- uses: swatinem/rust-cache@v2
```

### 重要な制約

- **workspace crate の成果物はデフォルトで削除される**
- `cache-workspace-crates: "true"` で保持可能だが fingerprint が mtime ベースのため git checkout 後にキャッシュミス
- `CARGO_INCREMENTAL=0` をデフォルトで設定する

### workspace crate の差分ビルドに使えない理由

1. cargo の fingerprint は出力ファイルの mtime で新旧判定
2. `actions/checkout` が全ファイルに現在時刻を付与 → 全ソースが「変更あり」と誤判定
3. → **sccache を使うべき**

### 参照
- https://github.com/Swatinem/rust-cache
- https://github.com/rust-lang/cargo/issues/6529

## docker

### CI runner 上でビルド + Docker は COPY のみ (推奨)

```yaml
- name: Build release binaries
  env:
    SCCACHE_GHA_ENABLED: "true"
    RUSTC_WRAPPER: "sccache"
  run: cargo build --release

- name: Prepare Docker context
  run: |
    mkdir -p docker-context
    cp target/release/my-app docker-context/
    cp Dockerfile docker-context/

- uses: docker/build-push-action@v6
  with:
    context: docker-context
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

### なぜ Docker 内でビルドしないか

| 手法 | 外部依存 | workspace crate | CI で動作 |
|---|---|---|---|
| ダミービルド層 | ○ cached | × 毎回全再コンパイル | ○ |
| --mount=type=cache | ○ | ○ 差分ビルド | **× CI で毎回空** |
| **CI runner + sccache** | **○** | **○ 差分ビルド** | **○** |

- `--mount=type=cache` は Docker ホストのローカルストレージ → GitHub Actions は毎回新マシンなのでキャッシュが消える

### 参照
- https://docs.docker.com/build/ci/github-actions/cache/
- https://github.com/docker/build-push-action/issues/1011

## llvm-cov

### 2回コンパイル問題

```yaml
# NG: 2回コンパイル
cargo llvm-cov --no-report --lib --workspace
cargo llvm-cov nextest --no-report --test mock_xxx

# OK: 1回コンパイル
cargo llvm-cov nextest --no-report --lib --workspace --test mock_xxx
```

### なぜ 2 コマンドだと 2 回コンパイルされるか

- `--lib` → lib profile、`--test` → test profile は別の compilation unit
- 1 コマンドに統合すれば nextest が両方を同時実行

### 参照
- https://github.com/taiki-e/cargo-llvm-cov
- https://nexte.st/docs/integrations/test-coverage/

## nightly

cargo nightly の `-Z checksum-freshness` は mtime ではなくファイルチェックサムで freshness 判定。CI での差分ビルドが完全に動作する。stable 未対応。

```bash
cargo +nightly -Z checksum-freshness build --release
```

**注意**: nightly toolchain を追加すると `swatinem/rust-cache` のキャッシュキーが変わりキャッシュミスする。

### 参照
- https://github.com/rust-lang/cargo/issues/14136

## benchmarks

### sccache 実測値 (rust-alc-api, 2026-04-02)

| 指標 | 値 |
|---|---|
| 初回ビルド | 1m 08s (cache miss 100%) |
| 2回目 (1 crate 変更) | 32s (cache hit 82%) |
| 3回目 (1 crate 変更) | ~30s (cache hit 100%) |

### cargo llvm-cov 統合 実測値

| 手法 | コンパイル | ビルド時間 |
|---|---|---|
| 2コマンド分離 | 22 Compiling (2回) | 71s |
| 1コマンド統合 | 11 Compiling (1回) | 46s |
