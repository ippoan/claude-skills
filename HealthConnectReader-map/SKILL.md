---
name: HealthConnectReader-map
generated-from: HealthConnectReader:666489a25adae1a5141de5e8aa411607dbf98184
description: ippoan/HealthConnectReader (Kotlin/Android、Health Connect 経由でトレッドミル運動データ ExerciseSession/Distance/Speed を読んで worker に upload する自分用アプリ) の構造ナビゲーション。MainActivity の権限フロー / HealthReader 読取 / WebView JS bridge / 日次 UploadWorker / 自動更新の配置と、Manifest 権限・署名・Health Connect の gotcha を 1 枚にまとめる。トリガー:「HealthConnectReader」「hcreader」「Health Connect」「ExerciseSession」「DistanceRecord」「SpeedRecord」「dataOriginFilter」「READ_EXERCISE 権限」「UploadWorker」「APK 署名」「release.keystore」等。
---

# HealthConnectReader-map — ippoan/HealthConnectReader 構造ナビゲーション

Kotlin/Android アプリ。Health Connect から Life Fitness 等のトレッドミルが書いた運動
データ (`ExerciseSession` / `Distance` / `Speed`) を読み、画面 (WebView) と worker への
HTTPS POST に出す自分用ツール。全 source は 1 package `com.ippoan.hcreader` に flat 配置。

> ここは索引 (pointer)。細部は repo 側が正。frontmatter の `generated-from` が現在の
> repo tree-sha とズレたら session-start hook が再生成を促す → その時 tree-sha を更新する。

## 区画 (`app/src/main/java/com/ippoan/hcreader/`)

| ファイル | 主要 symbol | 役割 |
|---|---|---|
| `MainActivity.kt` | `MainActivity` / `permissions` set / `ensurePermissionsGranted` / `checkForUpdate` / `startUpdateDownload` | entrypoint Activity。権限フロー + WebView 起動 + 自動更新 DL/インストール + バージョン常時表示オーバーレイ (Refs #6/#14/#30/#35/#36) |
| `HealthReader.kt` | `HealthReader(client)` / `readToday` / `readTodayJson` / `todayRange` | 読取ロジック本体。client を DI で受ける薄いラッパー。per-type try-catch で partial 読取許容 |
| `HCBridge.kt` | `HCBridge` / `readToday` / `readPastDays` / `getUploadToken` / `scheduleDailyUpload` / `requestPermission` | WebView `@JavascriptInterface` bridge。JS ↔ Kotlin の橋渡し |
| `UploadWorker.kt` | `UploadWorker` / `doWork` / `postUpload` / `schedule` / `cancel` / `isScheduled` | WorkManager の日次 upload worker。HC read → worker に HTTPS POST |
| `UpdateChecker.kt` | `UpdateChecker` (object) / `check` / `fetchLatest` / `parseLatest` / `LATEST_JSON_URL` | gh-pages 静的 `latest.json` を fetch してアプリ内自動更新を判定 (旧 api.github.com → gh-pages に変更、rate limit 回避) |
| `app/src/main/AndroidManifest.xml` | — | 権限宣言 / intent-filter / FileProvider |
| `app/build.gradle.kts` | `versionName` / `keyAlias` / `UPLOAD_TOKEN` BuildConfig | バージョン・署名・BuildConfig |
| `app/src/main/res/xml/file_paths.xml` | — | FileProvider の external-files-path |

## entrypoint / 起動フロー

- launcher Activity = `MainActivity` (`android.intent.action.MAIN` / `LAUNCHER`)。
- `onCreate` → `HealthConnectClient.getSdkStatus` で HC 利用可否 → WebView をロード → JS から `HCBridge` 経由で `readToday` / `readPastDays` / `scheduleDailyUpload` を呼ぶ。
- 権限は `permissions` set (= `ExerciseSession` / `Distance` / `Speed` の READ + `PERMISSION_READ_HEALTH_DATA_HISTORY`) を `ensurePermissionsGranted` で grant 要求。
- 日次 upload は `UploadWorker.schedule` (WorkManager) で予約。

## gotcha (CLAUDE.md / README 由来)

- **権限は Manifest と `permissions` set の両方に揃える**: record を足したら Manifest の `uses-permission android:name="android.permission.health.READ_*"` と code の `permissions` set を同時追加。片方欠けると grant が silent fail。**現状の scope は 3 種 (EXERCISE / DISTANCE / SPEED) に固定 (Issue #1)。`READ_HEART_RATE` 等を勝手に足さない**。
- **過去 30 日より前を読むには `READ_HEALTH_DATA_HISTORY` が必須** (Android 14+ HC 仕様、Refs #6)。
- **Android 14+ (API 34+) は Activity に `VIEW_PERMISSION_USAGE` + `HEALTH_PERMISSIONS` intent-filter が必須**。無いと権限 UI が silent fail でダイアログが出ない (Refs #25)。`ACTION_SHOW_PERMISSIONS_RATIONALE` も宣言必須。
- **upload 経路は `TREADMILL_ORIGINS = setOf(DataOrigin("com.lifefitness.connect"))` 固定フィルタ**: `readTodayJson` / `readPastDaysJson` は sessions/distances/speeds すべてをこの origin に絞る (#33)。Fitbit / Google Fit の重複 source が混入して距離が過大になる実害を修正済み。診断用 `readToday()` は引き続き全件 (フィルタなし)。
- **署名**: v1+v2 のみ (v3/v4 off)、`--min-sdk-version 28`。alias `hcreader` は `build.gradle.kts` の `keyAlias` と `release.yml` の `--ks-key-alias` の **2 箇所で一致必須**。PKCS12 は `keypass == storepass` 強制なので secret は 1 個。
- keystore (`*.keystore` / `*.jks`) や secret は **commit しない** (`.gitignore` 済、`git add -f` 禁止)。
- **`main` 直 push / force push / amend / rebase -i 禁止** (`git-safe-push.sh` が block)。PR → user が手動 merge。
- `Closes/Fixes/Resolves #N` 禁止 → `Refs #N`。

## CCoW / CI から見た立ち位置

- CI = `.github/workflows/ci.yml` + `release.yml`。release.yml は `ci-workflows/auto-merge.yml` を呼ぶ `auto-merge` job を持ち、`build` (APK build + 署名 + Pages deploy) green 後に `gh pr merge --auto --squash` を queue。
- `main` push で `v<versionName>+<run>` 正式タグ → GitHub Release + gh-pages 配信。PR push で `dev-pr<N>-<run>` prerelease (Pages 触らない、PR コメントに APK link)。
- org-level secret は全 `HCREADER_` prefix (`ippoan/secrets-inventory` の `/mcp/secret-upload` 経由で投入)。upload 先 worker は `HealthConnectReaderWorker`。
- CLAUDE.md は `ippoan/claude-md` の `CLAUDE.md.template` 派生 (共通部は template 側を直す)。

## 関連 skill

- `HealthConnectReaderWorker-map` — upload 先の Cloudflare Worker backend (R2 raw 保存 / D1 突合)。本アプリの送信先
- `secret-inject` — `HCREADER_*` org secret の no-leak 投入経路
- `branch-issue-linking` — `<issue>-<type>-<desc>` 命名 + `Refs #N` 規約
- `repo-map` / `cross-repo-symbol-index` — この per-repo map の運用方針 (generated-from 鮮度 hook)
