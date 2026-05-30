---
name: bazel-rust
description: |
  Rust (Cargo workspace) プロジェクトに Bazel (rules_rust + crate_universe) を導入するスキル。
  BUILD.bazel の生成、ハマりポイントの回避、crate 追加時の BUILD.bazel 更新に使用。
  トリガー: 「Bazel」「BUILD.bazel」「rules_rust」「crate_universe」「bazel build」「bazel test」等。
---

# Bazel + Rust (rules_rust / crate_universe) スキル

## 概要

Cargo workspace を Bazel でビルドするための BUILD.bazel 生成・管理スキル。
rules_rust + crate_universe (`crate.from_cargo`) で Cargo.toml を single source of truth にする。

## ハマりポイント (実証済み)

### 1. `all_crate_deps()` の `package_name` は指定しない

**問題**: `all_crate_deps(package_name = "alc-core")` → `Tried to get all_crate_deps for package alc-core but that package had no Cargo.toml file`

**原因**: crate_universe が生成する `_NORMAL_DEPENDENCIES` のキーは **Bazel パッケージパス** (`crates/alc-core`) であり、Cargo パッケージ名 (`alc-core`) ではない。

**解決**: `package_name` を省略する。`native.package_name()` が自動で `crates/alc-core` を返す。

```python
# NG
deps = all_crate_deps(package_name = "alc-core")

# OK
deps = all_crate_deps(normal = True)
```

### 2. `proc_macro_deps` を必ず分離する

**問題**: `async-trait` 等の proc_macro crate が `unresolved import` エラーになる。

**原因**: `all_crate_deps()` のデフォルトは `normal = True` のみ。proc_macro crate は `_PROC_MACRO_DEPENDENCIES` に分離されている。

**解決**: `deps` と `proc_macro_deps` を明示的に分ける。

```python
rust_library(
    name = "my-lib",
    srcs = glob(["src/**/*.rs"]),
    deps = all_crate_deps(normal = True) + ["//crates/dep-crate"],
    proc_macro_deps = all_crate_deps(proc_macro = True),
)
```

テストターゲットも同様:

```python
rust_test(
    name = "my-lib_test",
    crate = ":my-lib",
    deps = all_crate_deps(normal_dev = True),
    proc_macro_deps = all_crate_deps(proc_macro_dev = True),
)
```

### 3. `include_bytes!` / `include_str!` には `compile_data` が必要

**問題**: sandbox 内でファイルが見つからない (`No such file or directory`)

**解決**: `compile_data` で対象ファイルを明示的に追加。

```python
rust_library(
    name = "alc-pdf",
    srcs = glob(["src/**/*.rs"]),
    compile_data = glob(["assets/**"]),  # include_bytes! で参照するファイル
    ...
)
```

### 4. `sqlx::migrate!("./migrations")` にも `compile_data` が必要

**問題**: マイグレーションディレクトリが sandbox 内に存在しない。

**解決**:

```python
rust_binary(
    name = "migrate",
    srcs = ["src/bin/migrate.rs"],
    compile_data = glob(["migrations/**"]),
    ...
)
```

### 5. `rust_binary` が workspace crate を直接 `use` する場合

**問題**: `src/bin/archive.rs` が `use alc_core::...` しているが `unresolved module` エラー。

**原因**: `rust_binary` の `deps` に `":rust_alc_api_lib"` を入れても、lib が依存する workspace crate は **推移的に** binary から見えない。binary が直接 `use` する crate は明示的に `deps` に追加する必要がある。

**解決**: 全 workspace crate を変数化して共有。

```python
_WORKSPACE_CRATES = [
    "//crates/alc-core",
    "//crates/alc-notify",
    # ...
]

rust_binary(
    name = "my-bin",
    srcs = ["src/main.rs"],
    deps = [":my_lib"] + all_crate_deps(normal = True) + _WORKSPACE_CRATES,
    proc_macro_deps = all_crate_deps(proc_macro = True),
)
```

### 6. `all_crate_deps()` は外部依存のみ

workspace member 間の依存は `all_crate_deps()` に含まれない。明示的に Bazel label (`//crates/xxx`) で追加する。

```python
rust_library(
    name = "alc-dtako",
    deps = all_crate_deps(normal = True) + [
        "//crates/alc-compare",   # workspace member
        "//crates/alc-core",      # workspace member
        "//crates/alc-csv-parser", # workspace member
        "//crates/alc-pdf",       # workspace member
    ],
)
```

## BUILD.bazel テンプレート

### Standalone lib (外部依存のみ)

```python
load("@rules_rust//rust:defs.bzl", "rust_library", "rust_test")
load("@crates//:defs.bzl", "all_crate_deps")

rust_library(
    name = "my-crate",
    srcs = glob(["src/**/*.rs"]),
    crate_name = "my_crate",
    deps = all_crate_deps(normal = True),
    proc_macro_deps = all_crate_deps(proc_macro = True),
    visibility = ["//visibility:public"],
)

rust_test(
    name = "my-crate_test",
    crate = ":my-crate",
)
```

### Lib with workspace deps

```python
rust_library(
    name = "my-crate",
    srcs = glob(["src/**/*.rs"]),
    crate_name = "my_crate",
    deps = all_crate_deps(normal = True) + [
        "//crates/dependency-crate",
    ],
    proc_macro_deps = all_crate_deps(proc_macro = True),
    visibility = ["//visibility:public"],
)
```

### Root (bin + lib + tests)

```python
_WORKSPACE_CRATES = [
    "//crates/crate-a",
    "//crates/crate-b",
]

rust_library(
    name = "my_lib",
    srcs = glob(["src/**/*.rs"], exclude = ["src/main.rs", "src/bin/**"]),
    crate_name = "my_crate",
    deps = all_crate_deps(normal = True) + _WORKSPACE_CRATES,
    proc_macro_deps = all_crate_deps(proc_macro = True),
    visibility = ["//visibility:public"],
)

rust_binary(
    name = "my-app",
    srcs = ["src/main.rs"],
    deps = [":my_lib"] + all_crate_deps(normal = True) + _WORKSPACE_CRATES,
    proc_macro_deps = all_crate_deps(proc_macro = True),
)

rust_test(
    name = "unit_tests",
    crate = ":my_lib",
    deps = all_crate_deps(normal_dev = True),
    proc_macro_deps = all_crate_deps(proc_macro_dev = True),
)
```

## MODULE.bazel テンプレート

```python
module(name = "my_project", version = "0.1.0")

bazel_dep(name = "rules_rust", version = "0.69.0")

crate = use_extension(
    "@rules_rust//crate_universe:extensions.bzl",
    "crate",
)

crate.from_cargo(
    name = "crates",
    cargo_lockfile = "//:Cargo.lock",
    manifests = [
        "//:Cargo.toml",
        "//crates/crate-a:Cargo.toml",
        "//crates/crate-b:Cargo.toml",
    ],
)

use_repo(crate, "crates")
```

## crate 追加・変更時の手順

1. `Cargo.toml` に依存追加 (`cargo add xxx`)
2. `cargo update` で `Cargo.lock` 更新
3. `CARGO_BAZEL_REPIN=1 bazel sync --only=crates` で Bazel 依存を再解決
4. `bazel build //...` で検証

## .gitignore に追加するもの

```
/bazel-*
MODULE.bazel.lock
```

## CI キャッシュ戦略

### 推奨: bazel-github-actions-cache

GitHub Actions Cache API を直接 Bazel remote cache として使う。
tar/untar 不要でオンデマンド取得。

```yaml
# ci.yml
- uses: bazelbuild/setup-bazelisk@v3
- uses: tsawada/bazel-github-actions-cache@v0
- run: bazel build --config=ci -c opt //...
```

```
# .bazelrc
build:ci --remote_cache=http://localhost:3055
build:ci --strip=always
```

**重要**: GitHub Actions cache は **main ブランチでの保存が PR ブランチから読める**。
main push 時に `cache-warm-bazel` ジョブで温める必要がある。

### 試行して不採用になった方式

| 方式 | 問題 |
|------|------|
| bazel-remote + R2 | ダウンロード ~8s + R2 レイテンシ、secrets 管理 |
| actions/cache + disk_cache | tar 展開 ~30-40s がボトルネック |

### 実測パフォーマンス (12 crate workspace, actions/cache 方式)

| | 時間 | プロセス |
|---|---|---|
| 初回 (キャッシュなし) | ~188s | 1372 sandbox |
| 2回目 (disk cache hit) | ~61s | 1372 disk cache hit |
| うち Bazel 起動+解析 | ~60s | (キャッシュ復元含む) |
| うち実ビルド | 0.8s | |

### ハマりポイント: `-c opt` でキャッシュミス

**10. `compilation_mode` が違うとキャッシュが全ミスする**

Bazel はコンパイルフラグごとにキャッシュキーが異なる。

```bash
bazel build //...          # -c fastbuild (デフォルト)
bazel build -c opt //...   # -c opt (リリース相当)
```

`-c fastbuild` で温めたキャッシュは `-c opt` では**一切ヒットしない**。
CI で Docker イメージ用に `-c opt` を使う場合、キャッシュも `-c opt` で温める必要がある。

**対策**: CI の全ビルドステップで同じ `-c opt` を使う。テスト用 (`bazel test`) もリリース用 (`bazel build -c opt`) も統一する。

**11. Bazel 出力バイナリは read-only (`-r-xr-xr-x`)**

`strip` や他のインプレース操作は `Permission denied` で失敗する。

```bash
# NG
cp bazel-bin/my-app docker-context/
strip docker-context/my-app  # Permission denied

# OK
cp bazel-bin/my-app docker-context/
chmod u+w docker-context/my-app
strip docker-context/my-app
```

## Cargo との共存

| 機能 | ツール | 理由 |
|------|--------|------|
| ビルド | Bazel | 増分ビルド + リモートキャッシュ |
| フォーマット | `cargo fmt` | Bazel に equivalent なし |
| Lint | `cargo clippy` | Bazel の rust_clippy は未成熟 |
| カバレッジ | `cargo llvm-cov` | Bazel coverage は未成熟 |
| IDE | `Cargo.toml` | rust-analyzer 互換 |

## ippoan branch protection との連動 (gotcha)

`auth-worker dashboard` の `ippoan-rust-default` preset を適用すると、main branch protection の required check は:

- `ci / rustfmt`
- `ci / clippy`
- `ci / cargo test`
- `ci / cargo build --release`

になる。**この `ci / ` prefix は workflow file の `name:` ではなく、`jobs.<key>:` 側の "caller job key" が prefix される仕様** (= `jobs.ci.uses: reusable.yml` で reusable を呼ぶと caller job key = `ci` が prefix される)。

### NG: inline job (check 名が一致しない)

```yaml
# .github/workflows/ci.yml — 動かない
name: ci
jobs:
  rustfmt:       # ← job key
    name: rustfmt
    runs-on: ubuntu-latest
    steps:
      - run: cargo fmt --check
```

→ check context が `rustfmt` (job key だけ) or `ci / rustfmt` (workflow name + job key) の **どちらに matching するか実装依存**で、branch protection の `ci / rustfmt` requirement と一致せず "4 of 4 required status checks are expected" で merge block される。実機検証 (mcp-relay-rs#10) で確認済。

### OK: reusable workflow を `jobs.ci` から呼ぶ

```yaml
# .github/workflows/ci.yml
name: ci   # display 用、prefix matching には使われない
jobs:
  ci:                                                       # ← この key が check 名 prefix
    uses: ippoan/ci-workflows/.github/workflows/rust-ci.yml@main
    with:
      binary_name: my-app
      shared_key: my-app
```

→ check names: `ci / rustfmt` / `ci / clippy` / `ci / cargo test` / `ci / cargo build --release` → preset 一致。

### lib-only crate (binary 無し) の場合

`ippoan/ci-workflows/rust-ci.yml` は `binary_name` 必須 + `./target/release/$BIN --help` の smoke test を走らせる → lib-only crate には流用不可。

**解**: local reusable workflow を repo 内に同梱して `jobs.ci.uses: ./.github/workflows/_lib-ci.yml` で呼ぶ。

```yaml
# .github/workflows/_lib-ci.yml
name: lib-ci
on:
  workflow_call:
    inputs:
      shared_key:
        required: false
        type: string
        default: my-lib

env:
  CARGO_TERM_COLOR: always

jobs:
  rustfmt:
    name: rustfmt
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: rustfmt
      - run: cargo fmt --all -- --check

  clippy:
    name: clippy
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          components: clippy
      - uses: Swatinem/rust-cache@v2
        with:
          shared-key: ${{ inputs.shared_key }}
      - run: cargo clippy --workspace --all-targets --all-features -- -D warnings

  cargo-test:
    name: cargo test
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
        with:
          shared-key: ${{ inputs.shared_key }}
      - run: cargo test --workspace --all-targets --all-features --no-fail-fast

  cargo-build-release:
    name: cargo build --release
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
      - uses: Swatinem/rust-cache@v2
        with:
          shared-key: ${{ inputs.shared_key }}
      - run: cargo build --release --workspace --locked
```

```yaml
# .github/workflows/ci.yml (lib-only)
name: ci
on:
  pull_request:
    branches: [main]
jobs:
  ci:                                            # ← prefix 元
    uses: ./.github/workflows/_lib-ci.yml
    with:
      shared_key: my-lib
  # coverage / bazel-build / auto-merge は別 job として併走させる
```

Phase 2 で binary を吸収したら `_lib-ci.yml` を捨てて `ippoan/ci-workflows/rust-ci.yml` に乗り換え可能。

### workflow `name:` の case sensitivity

`name: CI` (大文字) で実行すると check 名は `CI / X`、`name: ci` (小文字) で `ci / X`。branch protection の `ippoan-rust-default` preset は `ci / X` lowercase で登録されており、**case sensitive で matching** する。`name:` を lowercase に揃えること。

### 失敗症状

| 症状 | 原因 | 対処 |
|---|---|---|
| `405 4 of 4 required status checks are expected. []` | check 名が preset の context と不一致 | `jobs.ci.uses:` 経由 reusable に変更 + `name: ci` lowercase |
| dashboard に `blocked blocked` (force push + delete) しか出ないのに merge block | `required_status_checks.contexts` の 4 が全部 stale (= 過去 check 名のまま) | preset を Remove → Apply で再登録 |
| auto-merge job 自体は success だが PR `mergeable_state: "blocked"` のまま | `gh pr merge --auto` で queue 済、required check 待ち。check 名が正しければ非同期で fire する | check 名を確認、合っていれば数十秒〜数分待つ |

### 検証手順

1. PR 作成後、`gh pr checks <PR>` で `<workflow> / <job>` 形式の context 名を確認
2. dashboard `auth.ippoan.org/dashboard/branch-protection` で当該 repo の Required checks 列と突き合わせ
3. 一致しない場合は ci.yml を reusable パターンに修正 + push
4. 修正後 `gh pr merge <PR> --squash` で manual merge 試行 (admin) or auto-merge queue を待つ
