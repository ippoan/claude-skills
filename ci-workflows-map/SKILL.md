---
name: ci-workflows-map
generated-from: ci-workflows:89d74d5a6c53a108672e5b6fb60e186e5ecc3c6e
description: ippoan/ci-workflows (ippoan/ohishi-exp org 共通の GitHub Actions reusable workflow 集) の構造ナビゲーション。frontend-ci / go-ci / lib-ci / rust-ci / cloud-run-deploy / auto-merge / branch-protection / release-wave-handler / tag-release 等の reusable workflow を種別ごとに索引化し、caller 必須 permissions・startup_failure・auto-merge dual-step・coverage 100% gate 等の gotcha を 1 枚にまとめる。トリガー: 「ci-workflows」「reusable workflow」「frontend-ci」「go-ci」「auto-merge」「branch-protection」「startup_failure」「cloud-run-deploy」「release-wave-handler」「secret-verify」「tag-release」等。
---

# ci-workflows-map — ippoan/ci-workflows 構造ナビゲーション

ippoan + ohishi-exp org 共通の **GitHub Actions reusable workflow 集**。各 consumer repo は
`.github/workflows/<name>.yml` から `uses: ippoan/ci-workflows/.github/workflows/<file>@main`
で 10〜20 行 caller を書いて呼ぶ。本体は `.github/workflows/` に集約 (本 repo 自身の CI は
`ci.yml` の actionlint)。

> ここは索引 (pointer)。各 workflow の input 全量 / 正確な job DAG は repo 側 (file header と
> CLAUDE.md) が正。frontmatter の `generated-from` が現在の repo tree-sha とズレたら
> session-start hook が再生成を促す → その時 tree-sha を更新する。

## 区画 (reusable workflow、種別ごと)

### 言語別 CI pipeline (caller の主役)

| workflow | 対象 | job 構成 / 備考 |
|---|---|---|
| `frontend-ci.yml` | Nuxt / Cloudflare Worker | typecheck/test/integration/deploy + 内蔵 disable→auto-merge dual-step。`project_type` で nuxt/worker 切替 |
| `go-ci.yml` | Go (Cloud Run) | `vet`/`test`/`build` + opt-in `secret-verify`。`coverage_100.toml` 検出で 100% gate。auto-merge は embed せず caller 側で組む |
| `lib-ci.yml` | `@ippoan/*` Node lib | `typecheck`/`lint`(auto)/`test`。lockfile 有無で `npm ci`/`install` fallback |
| `rust-ci.yml` | Rust | Rust CI |
| `android-ci.yml` | Android (Gradle) | Android CI |
| `shell-ci.yml` | shell script | Shell CI (shellcheck 等) |

### deploy / release

| workflow | 役割 |
|---|---|
| `cloud-run-deploy.yml` | Cloud Run へ AR remote-repo (pull-through cache) 経由 digest-pinned deploy |
| `tag-release.yml` | `workflow_dispatch` で `v{semver}` 正式タグ採番 (`TAG_RELEASE_PAT` 要) |
| `dev-tag-release.yml` | `push:main` で `{prefix}{N}` 開発タグ採番 (default `dev-N`) |
| `rust-binary-release.yml` | Rust binary を GitHub Release に (tag に `-` 含めば prerelease) |
| `lib-publish.yml` | `@ippoan/*` lib を GitHub Packages に publish (publish 前 typecheck+test gate) |
| `propagate-package.yml` | publish 後に consumer repo の依存を自動更新 |

### merge / branch protection / drift

| workflow | 役割 |
|---|---|
| `auto-merge.yml` | CI 完走後に `gh pr merge --auto` で enable (frontend/lib は内蔵、go/その他は caller から) |
| `branch-protection.yml` | Branches API で branch protection を **apply** (preset 適用) |
| `branch-protection-drift-check.yml` | 設定 drift を検知 |
| `check-dep-version.yml` | 依存バージョン整合チェック |
| `snapshot-check.yml` | snapshot 整合チェック |
| `cf-access-verify.yml` | Cloudflare Access 設定 verify |
| `secret-verify-gcp.yml` | GCP Secret Manager に必要 secret が存在するか verify (go-ci/frontend-ci に内製化済、単体 caller も維持) |

### release wave (ci-dashboard#137 連携)

| workflow | 役割 |
|---|---|
| `release-wave-handler.yml` | `repository_dispatch` (stage/flip/rollback 等) を受け platform 別 deploy → ci-dashboard webhook に shared secret 付き POST。設定は `config/release-wave-targets.yaml` 集約 |

### 本 repo 自身用 (`-self` 接尾)

`ci.yml` (actionlint) / `auto-merge-self.yml` / `branch-protection-self.yml` — ci-workflows 自身の CI。

## その他の区画

| パス | 中身 |
|---|---|
| `config/release-wave-targets.yaml` | wave 参加 repo の platform / service / preview hostname。新規参加 = yaml entry 追加 + repo に caller 1 file |
| `scripts/cloud-run/deploy.sh` `extract_secrets.py` | cloud-run-deploy.yml が呼ぶ補助 script |
| `.github/actions/{pr-limit,report-backend-deploy,report-frontend-compat}/action.yml` | composite action (PR 数制限 / deploy・compat レポート) |

## entrypoint / 使い方

- 自身が実行 entrypoint を持つのは `-self` 系と `ci.yml` のみ。他は **caller repo から `workflow_call` で呼ばれる**のが起点。
- consumer は `/ci-init` skill か CLAUDE.md の caller テンプレートを使う。

## gotcha (CLAUDE.md / README 由来)

- **caller の `permissions` 不足 → `startup_failure`** (job 0 件・log 0 行で 1 秒終了、空 jobs 列)。GitHub は reusable が要求する権限を caller で許可してないとエラー文も出さず起動拒否する。
  - frontend-ci/lib-ci: 内蔵 auto-merge のため **top-level (Option A)** に `contents: write` + `pull-requests: write` (+ `packages: read`) 必須。
  - go-ci: auto-merge 無いので job-level (Option B) `contents: read` + `id-token: write` でも可。
  - **`secret-verify` を使わない caller でも `id-token: write` の declare 必須** (`if:` skip 予定でも parse 時の permissions check が走る、ci-workflows#38)。
- **auto-merge は dual-step**: CI 開始時に `disable-auto-merge` で強制 disable (緩い branch protection での誤 merge 防止) → 完走後に再 enable。go-ci.yml も 2026-05 以降 `disable-auto-merge` を内蔵し `pull-requests: write` を必須化 (breaking change)。
- **coverage 100% gate (go-ci)**: working_directory に `coverage_100.toml` があれば、registered file の (exclude_funcs 以外の) 全 function が 100% であることを fail-gate。section 名は relative path、`go tool cover -func` と suffix match。
- **`has_integration: true` にしたら `compat_backend_repo` 必須** (未設定だと API Integration job が loud fail。backend 不要なら `'none'` で opt-out)。
- `npm_publish_directory` は comma-separated で複数 package を 1 CI で publish (dev = `0.0.<PR>-dev.<SHA>` 共通、release = tag 共通の lock-step)。
- cross-org (ohishi-exp) では `secrets: inherit` が効かないので明示渡し。
- release-wave-handler は `client_payload.*` を **untrusted** 扱い (checkout ref に使う前に正規表現で ref injection 検証)。

## CCoW / CI から見た立ち位置

- ippoan の全 repo の CI/deploy/merge/release の **共通土台**。各 repo map の「CI は ci-workflows の <x>.yml」という記述はここを指す。
- 親 issue `ippoan/ci-dashboard#137` (Release Wave) の Phase 4 executor 配線元 (`release-wave-handler.yml` + `config/release-wave-targets.yaml`)。release-wave-gcp / rust-alc-api 等を束ねる。

## 関連 skill

- `ci-init` — consumer repo に `test.yml` caller を生成 (本 repo の reusable を使う)
- `auto-merge-401` / `gh-actions-phantom-permission` — auto-merge.yml / permission scope 由来の既知 CI fail のトラブルシュート
- `ci-cache-patterns` / `coverage-check` / `coverage-test-patterns` — Rust CI cache / coverage gate 補助
- `release-wave-gcp-map` / `secrets-inventory-gcp-map` — go-ci.yml + cloud-run-deploy.yml + secret-verify の consumer 実例
- `repo-map` / `cross-repo-symbol-index` — この per-repo map の運用方針 (generated-from 鮮度 hook)
