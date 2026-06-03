---
name: ippoan-android-baseline
description: ippoan org の Android アプリ標準 (baseline)。新規 Android repo を立てる / 既存を直す時に「ビルド・署名・配信・更新通知・versioning・CI・branch/PR 規約」をどう揃えるかの SoT。reference 実装は ippoan/HealthConnectReader。要点: gh-pages 一次配信 + QR、versionName(build.gradle) + versionCode=github.run_number、tag v<name>+<run>、apksigner v1+v2 (--min-sdk-version 28)、更新通知は api.github.com ではなく gh-pages latest.json + tag 比較 (REST レート制限 60/hr を食わない)。トリガー:「Android 基準」「Android baseline」「Android repo 立てる」「APK 配信」「gh-pages 配信」「release.yml Android」「versionCode run_number」「UpdateChecker」「latest.json」「apksigner」「keystore alias」「Health Connect アプリ」「自動更新 Android」等。
---

# ippoan-android-baseline — ippoan org の Android アプリ標準

ippoan org で Android アプリ repo を立てる / 直す時の **共通 baseline**。reference
実装は **[ippoan/HealthConnectReader](https://github.com/ippoan/HealthConnectReader)**
(現状 org 唯一の Android repo)。構造の詳細は `HealthConnectReader-map` skill、
ここは「**どの repo でも揃えるべき標準**」だけを抜き出す。

> 細部 (正確な行 / 最新版) は HealthConnectReader 側が正。差異が出たらこの skill を更新。

## 1. プロジェクト基本

| 項目 | 標準 | 備考 |
|---|---|---|
| 言語 / ビルド | Kotlin + AGP + Gradle (Kotlin DSL `build.gradle.kts`) | |
| `compileSdk` / `targetSdk` | **36** | Health Connect `connect-client:1.1.0-rc02+` が API 36 要求。低いと `checkReleaseAarMetadata` で fail |
| `minSdk` | **28** | 署名の `--min-sdk-version` と揃える |
| `applicationId` | `com.ippoan.<app>` | |
| `versionName` | `build.gradle.kts` に literal (例 `"0.1.0"`)。**bump は PR で** | release.yml が grep で抜くので `^[[:space:]]*versionName[[:space:]]*=` の代入行に厳格マッチ (コメント行に "versionName" を書くと壊れる — 実害 HealthConnectReader#24) |
| `versionCode` | **`github.run_number`** を CI で注入 (`cfg("HCREADER_VERSION_CODE","1").toInt()`)。dev ローカルは 1 固定 | これで毎 release インクリメント → 更新検出が効く |

## 2. 署名 (apksigner)

- **v1 + v2 のみ** (v3 / v4 off)、`--min-sdk-version 28`
- alias は **build.gradle.kts の `keyAlias` と release.yml の `--ks-key-alias` の 2 箇所で必ず一致** (HealthConnectReader は `hcreader`)
- keystore secret 3 点: `RELEASE_KEYSTORE_BASE64` / `RELEASE_STORE_PASSWORD` / `RELEASE_KEY_PASSWORD` (org or repo secret)
- `*.keystore` / `*.jks` は `.gitignore`。**`git add -f` で強制追加しない**。CI で base64 から復元
- CI から渡す secret は末尾改行混入に注意 (`cfg().trim()` で吸収。投入は `tr -d '\n'` 推奨)

## 3. 配信 = gh-pages 一次 + GitHub Release 二次

release asset の Azure 署名 URL は mobile browser × キャリア × Play Protect で
「DL が進まない」事例があるため、**gh-pages の静的配信を一次チャネル**にする
(alc-app 準拠):

| event | tag | gh-pages 配置 | prerelease |
|---|---|---|---|
| `push: main` | `v<versionName>+<run_number>` | root `app-release.apk` | false |
| `pull_request` | `dev-pr<N>-<run_number>` (`-` 入りで `releases/latest` に出ない) | `dev/pr<N>/app-release.apk` | true |

- QR (`qrencode`) の target は **github.io の安定 URL** (release asset ではなく)
- gh-pages branch が無ければ release.yml が `git checkout --orphan` で自動 init
- **Settings → Pages → source: `gh-pages` branch / `/`** の有効化だけ初回 user 手動
- concurrency group を `event + (PR#|ref)` で切り gh-pages push race を直列化

## 4. アプリ内更新通知 (重要 — api.github.com を使わない)

**`api.github.com/repos/.../releases/latest` を叩かない**。public repo でも REST API
は未認証 **60 req/時/IP** のレート制限対象。代わりに **gh-pages の静的
`latest.json`** を見る (Pages/web frontend は REST レート枠と別 = 制限ゼロ)。

release.yml が **stable (main) のみ** root に吐く:

```json
{"tag":"v0.1.0+50","versionName":"0.1.0","versionCode":50,
 "apkUrl":"https://<owner>.github.io/<repo>/app-release.apk",
 "htmlUrl":"https://github.com/<owner>/<repo>/releases/tag/v0.1.0+50"}
```

- dev PR build (`REL_DIR` 非空) では `latest.json` を更新しない = 利用者を dev 版へ誘導しない
- アプリは起動時に fetch → `versionCode > BuildConfig.VERSION_CODE` なら更新あり
- **再 nag 抑制は tag 比較だけ** — `last_seen_tag` を `SharedPreferences` に保存し、同じ tag を前に見せていればダイアログを出さない。tag が変わった時だけ出す。**時間ベースの 24h cache は不要** (API を食わないので間引く意味がない。むしろ「24h 気づかない」弊害)
- fetch 失敗 (404 / network / parse) は **silent skip** (fail-open)。`latest.json` は初回 main release まで存在しない前提

> 経緯: HealthConnectReader#18 で api.github.com polling を入れたが、#21 で
> gh-pages latest.json + tag 比較に置き換え (api 廃止 / 時間 cache 廃止)。

## 5. 自動 install (任意)

更新ダイアログ「更新」→ `DownloadManager` で app-specific 外部ストレージに DL →
`ACTION_DOWNLOAD_COMPLETE` 受信 → `FileProvider` content:// URI を `ACTION_VIEW`
+ `application/vnd.android.package-archive` でインストーラ起動。Android 8+ は
`canRequestPackageInstalls()` を確認し未許可なら `ACTION_MANAGE_UNKNOWN_APP_SOURCES`
へ誘導。`REQUEST_INSTALL_PACKAGES` 権限 + `FileProvider`
(`${applicationId}.fileprovider`) + `res/xml/file_paths.xml` が要る (HealthConnectReader#30)。

## 6. 権限 (Health Connect 系のとき)

- `permissions` set に足した record type は **Manifest の `uses-permission` にも対応する `READ_*` を同時追加**。片方だけだと grant 失敗
- Android 14+ は権限ダイアログに **`VIEW_PERMISSION_USAGE` + `HEALTH_PERMISSIONS` intent-filter** が必須。無いと `requestPermissions.launch()` が silent fail (HealthConnectReader#25)
- 過去 30 日超の read は `READ_HEALTH_DATA_HISTORY` が要る
- source 混入対策は `dataOriginFilter = setOf(DataOrigin("..."))` で絞る (HealthConnectReader#28/#32)

## 7. CI / branch / PR 規約 (org 共通に揃える)

- `release.yml` は `app/**` or workflow 自身の変更で発火。APK build + 署名 + GitHub Release + gh-pages deploy
- **auto-merge は workflow 側** (`ippoan/ci-workflows/.github/workflows/auto-merge.yml@main` を `needs: build` で呼ぶ)。`mcp__github__enable_pr_auto_merge` を Claude が直接叩くのは user 明示指示時のみ
- `TAG_RELEASE_PAT` を org secret に置くと PR merge 後の `push: main` が PAT actor で発火し main run が chain (未設定だと `github.token` actor で起動しないので手動 `workflow_dispatch`)
- **`main` 直 push 禁止**、PR 経由。`git push --force` / `commit --amend` / `rebase -i` は claude-hooks が block
- branch: `<issue-number>-<type>-<short-desc>` (`type ∈ feat|fix|refactor|infra`) または `claude/<topic>`
- PR / commit は **`Refs #N`** (`Closes/Fixes/Resolves` 禁止 = auto-close 防止)。PR 本文の issue ref は claude-hooks の `pr-refs-link-guard` が強制 (無いと create_pull_request が deny)
- ローカルに Android SDK が無い CCoW では `assembleRelease` は回せない → **CI の `Build APK` / `Lint` で検証**する前提で PR を出す

## 8. やってはいけない

- `versionName` の代入行以外 (コメント等) に "versionName" 文字列を書く (release.yml の grep が壊れる)
- 更新通知で api.github.com を叩く (レート制限。gh-pages latest.json を使う)
- keystore / secret を commit する (`git add -f` 含む)
- CI green のためのテスト無効化 / skip flag (root cause を直す)
- issue scope 外の権限を勝手に足す (Health Connect の record type 等)

## 関連 skill

- `HealthConnectReader-map` — reference 実装の構造ナビ
- `ci-workflows-map` — auto-merge / reusable workflow の caller 規約
- `branch-issue-linking` — `Refs #N` / branch 命名規約
- `package-publish-debug` — GHCR / Pages 配信のトラブル対応
