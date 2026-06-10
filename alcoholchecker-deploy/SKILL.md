---
name: alcoholchecker-deploy
generated-from: AlcoholChecker:d7d854e343ed36001ce808fed9e634f6e1bab538
description: ippoan/AlcoholChecker (Android キオスクアプリ) の deploy / 配信モデルの SoT。dev 端末 (is_dev_device=true) は PR 時点で prerelease build を FCM OTA push、prod 端末は Release Wave / 管理画面トリガーで明示配信 (master merge では自動配信しない)。release.yml の PR/master 二相動作・versionCode=run_number 単調増加・download_url allowlist・alc.ippoan.org 移行 (workers.dev は 404 で死亡)・rollback 不可 (versionCode downgrade) の gotcha をまとめる。トリガー:「AlcoholChecker デプロイ」「APK 配信」「dev 端末 配信」「OTA push」「trigger-update-dev」「download_url」「dev-pr タグ」「versionCode 順序」「prod 端末 リリース」「Android release wave」「アルコールチェッカー アプリ更新」等。
---

# alcoholchecker-deploy — ippoan/AlcoholChecker の配信モデル

WebView ベースの業務用 Android アプリ (Device Owner キオスク端末 + 一般端末)。
2026-06-10 の PR #2 で **dev/prod 配信を分離** した。この skill が配信運用の SoT。

## 配信モデル (どの端末にいつ届くか)

| 対象 | タイミング | 経路 |
|---|---|---|
| **dev 端末** (`devices.is_dev_device=true`) | **PR を開いた時点** | release.yml PR build → `POST /api/devices/trigger-update-dev` (`X-Internal-Secret`) → FCM `app_update` (`download_url` = prerelease asset) |
| **prod 端末** (その他全部) | **明示操作のみ** | Release Wave (AlcoholChecker#3 で設計中) / 管理画面 AdminDashboard の trigger-update |
| master merge | **何も配信しない** | stable release + gh-pages root を作るだけ (OTA 発火なし) |

## release.yml の二相動作 (`.github/workflows/release.yml`)

`push: master` と `pull_request: master` の両方で同一 workflow が走る
(= **run_number カウンタ共有**。PR build N の後の master build は必ず N+k なので
versionCode が単調増加し、OTA の「target > current で更新」が壊れない)。

### PR path (staging = dev 端末)

1. release 署名 APK ビルド (`versionCode = run_number` に sed 置換)
2. prerelease tag `dev-pr<N>-<run>` — tag に `-` を含むので **releases/latest に出ない**
3. gh-pages `dev/pr<N>/` に APK + sha256 + QR 配置、PR に QR コメント
4. `trigger-update-dev` を curl — body に `version_code` / `version_name` / `download_url`
   (= `https://github.com/ippoan/AlcoholChecker/releases/download/dev-pr<N>-<run>/app-release.apk`)
5. build green 後 `auto-merge` job (ci-workflows `auto-merge.yml@main`、org secret
   `CI_APP_ID`/`CI_APP_PRIVATE_KEY`) が squash auto-merge を queue。App token actor
   (`ippoan-ci-bot[bot]`) の merge push が master run を連鎖発火させる

### master path (stable)

- tag `v{versionName}+{run}` + GitHub Release (= releases/latest 更新) + gh-pages root 更新
- **OTA は発火しない** — prod への配信は上表どおり明示操作

### リリース手順 (人間がやること)

1. PR に patch bump (`app/build.gradle.kts` の `versionName` x.y.Z) を含める
2. PR を出す → dev 端末で検証 (自動 OTA 済み) → auto-merge で stable が自動生成
3. prod 端末へ届けたい時だけ管理画面 trigger-update (将来: Release Wave flip)

## OTA の仕組み (app 側)

- FCM data message `type=app_update` を `MyFirebaseMessagingService.handleAppUpdate` が受信
- `download_url` は **allowlist 検証** (https + `github.com` +
  `/ippoan/AlcoholChecker/releases/download/` prefix)。不一致は無視して
  `OtaUpdateService.DEFAULT_APK_URL` (= releases/latest) に fallback
- `current versionCode >= target` ならスキップ。Device Owner 端末は PackageInstaller
  silent install、それ以外は通知タップでインストーラ起動
- backend 側 forward は rust-alc-api#407 (`TriggerUpdateBody.download_url` → FCM data)。
  **本番 rust-alc-api への反映は `/tag-release patch` が必要** — 未反映の間は
  FCM に download_url が乗らず、旧アプリは releases/latest fallback
  (1 PR サイクルで新アプリへ自己回復する設計)

## URL (2026-06 移行済み、重要)

- **`alc-app.m-tama-ramu.workers.dev` は死んでいる** — custom domain 移行で
  workers.dev サブドメインが Cloudflare の 404 placeholder を返す。
  CI から curl して HTML が返り `jq: parse error` になったらこれ
- アプリ/CI の API は **`https://alc.ippoan.org`** (assetlinks.json も配信済み、
  device-claim App Links host も同 host)
- `alc-signaling.m-tama-ramu.workers.dev` (WebRTC signaling) は **生存・継続使用**
- `OtaUpdateService.DEFAULT_APK_URL` は `ippoan/AlcoholChecker` (repo transfer 済み、
  旧 `yhonda-ohishi-alc` は 301 redirect)

## Gotcha

- **rollback 不可** — Android は versionCode downgrade をインストールできない。
  「前のバージョンに戻す」は旧 tag のソースを新 versionCode で再ビルドする別フローが
  必要 (Release Wave 設計 AlcoholChecker#3 の主要課題)
- **WebView origin 変更は activation 消失** — BASE_URL を変えると localStorage
  (`alc_device_id` 等) がリセットされ端末の再アクティベーションが要る
  (workers.dev → alc.ippoan.org 移行で 1 回発生)
- dev 端末の prerelease は releases/latest に影響しないので、prod 端末が誤って
  PR build を拾うことはない
- `FCM_INTERNAL_SECRET` (repo secret) が trigger-update-dev の認証。alc-app worker の
  `server/api/devices/trigger-update-dev.post.ts` が rust-alc-api へ proxy する

## 関連

- ippoan/AlcoholChecker#1 (settings_token) / #2 (配信分離の実装 PR) / #3 (Release Wave 設計)
- ippoan/rust-alc-api#406 / #407 (download_url forward)
- skill `ippoan-android-baseline` (org Android 標準 / HealthConnectReader が参照実装)、
  `alc-app-map` (フロント側構造)
