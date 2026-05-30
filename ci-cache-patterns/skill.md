---
name: ci-cache-patterns
description: Rust + GitHub Actions CI のキャッシュ戦略設計スキル。sccache / swatinem/rust-cache / Docker layer cache の選定・設定・組み合わせパターンを提供する。トリガー: CI ワークフロー作成、GitHub Actions のビルド時間最適化、CI 遅い、キャッシュ、sccache、rust-cache、Docker キャッシュ、ビルド時間、CI 高速化。
---

# Rust + GitHub Actions CI キャッシュ戦略

## 前提: ブランチスコープ

```
main → PR: ✅  PR → main: ❌  PR A → PR B: ❌
```

`actions/cache`, `swatinem/rust-cache`, `sccache-action` 全て同じ制限。main スコープにキャッシュ保存が必須。

## 前提: cargo fingerprint

fingerprint に含まれるもの: ソースハッシュ, rustc バージョン, RUSTFLAGS, **RUSTC_WRAPPER**, `cargo llvm-cov` フラグ (`-C instrument-coverage`), プロファイル。

**1つでも異なると全再コンパイル。** cache-warm と PR で完全に同じコマンド・環境変数を使うこと。

## 推奨構成

### swatinem/rust-cache のみ (sccache 併用は非推奨)

tokio, axum, serde 等の主要 Rust OSS と同じパターン。sccache との併用は RUSTC_WRAPPER の有無で fingerprint が変わりキャッシュ無効化される。

```yaml
- uses: swatinem/rust-cache@v2
  with:
    shared-key: <job-specific-key>
```

### cache-warm ジョブ (main push 専用)

PAT auto-merge で main push CI を発火し、cache-warm ジョブだけ実行。

```yaml
cache-warm:
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    strategy:
      matrix:
        target:
          - { name: "release", key: "release-build", cmd: "cargo build --release" }
          - { name: "test", key: "test-lib", cmd: "cargo llvm-cov nextest --no-report --ignore-run-fail --lib --workspace" }
```

ルール:
- コマンドは PR のジョブと **完全一致** (fingerprint 一致のため)
- `--ignore-run-fail` でテスト失敗を無視 (DB なしで失敗するが target/ は保存される)
- `RUSTC_WRAPPER=sccache` を使うなら cache-warm にも必ず入れる
- 他のジョブ (check, test-matrix) は main push でスキップ: `!(github.ref == 'refs/heads/main' && github.event_name == 'push')`

### auto-merge の GITHUB_TOKEN 問題

GITHUB_TOKEN でマージすると main push event が発火しない (GitHub セキュリティ仕様)。PAT で解決:

```yaml
# reusable workflow
secrets:
  AUTO_MERGE_PAT:
    required: false
steps:
  - env:
      GH_TOKEN: ${{ secrets.AUTO_MERGE_PAT || github.token }}
    run: gh pr merge ${{ github.event.number }} --squash --repo ${{ github.repository }}
```

### Docker build-once-promote

```
PR: docker-push → :sha + :dev
Tag push: migrate pulls :dev → retags to :version + :sha → deploy
```

squash merge で SHA が変わるため tag push では `:dev` を promote。Docker ビルドは PR の1回だけ。

## アンチパターン

| パターン | 問題 |
|---|---|
| sccache + rust-cache 併用 | RUSTC_WRAPPER fingerprint 不一致 |
| cache-warm と PR で異なるコマンド | フラグ不一致で全再コンパイル |
| main push でフルテスト | PR + tag push と3重実行、cache-warm だけに絞る |
| `cargo test --no-run` で warm | PR が `cargo llvm-cov nextest` なら fingerprint 不一致 |

## デバッグ

```bash
# main スコープのキャッシュ確認
gh api repos/OWNER/REPO/actions/caches --paginate \
  --jq '.actions_caches[] | select(.key | test("rust")) | "\(.ref) \(.key[0:60])"' \
  | grep "refs/heads/main"
```

CI ログの読み方:
- `Restored from cache key "..." full match: true` → 復元成功
- `No cache found` → miss
- `Compiling proc-macro2` → 依存クレート再コンパイル (fingerprint 不一致)
- `Compiling alc-core` のみ → 自プロジェクトだけ再コンパイル (正常)

### rust-cache が save しない場合

exact match で復元 + target/ 変更なし → save スキップ。対策: ビルドコマンドを実行して target/ を更新させる。
