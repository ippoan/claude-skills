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

### rust-cache の save-if default は default branch のみ

`Swatinem/rust-cache@v2` の `save-if` default は default branch のみ → `release.yml` 等 tag push (`refs/tags/v*`) で起動する workflow は default で**一度も save されない**。tag push でも save したい場合は明示的に override:

```yaml
save-if: ${{ github.ref == format('refs/heads/{0}', github.event.repository.default_branch) || startsWith(github.ref, 'refs/tags/v') }}
```

reusable workflow に rust-cache を入れただけだと「動いているように見えて save されていない」状態が長期間続くので注意 (実測: ippoan/ci-workflows#10、reusable 導入から 3 日間 cold が継続)。

### shared-key 変更 / top-level env への変数追加は cache key を変える

過去 cache が一度捨てられて clean slate になり、その run 自体は cold で完了。本命の効果は**次の run** で初めて数字に出る。具体的に効くもの:

- `shared-key` の文字列変更 (例: `${{ inputs.bin_name }}` → `${{ inputs.bin_name }}-${{ matrix.t.target }}`)
- top-level `env:` への新変数追加 (例: `RUSTC_WRAPPER` を追加すると rust-cache の `add-rust-environment-hash-key: true` (default) によって env hash が変わり key 末尾が再 base 化)

→ cache 戦略変更を投入した直後の 1 run で「効いていない」と判断せず、**最低 2 release (= 1 回 priming + 1 回 hit 検証) を待ってから評価**する。

## 詳細リファレンス

sccache 構成の設定例、実測ベンチマーク、Docker 内ビルドの比較表、nightly checksum-freshness については [patterns.md](references/patterns.md) を参照。
