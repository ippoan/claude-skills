---
name: cores3-crash-triage
description: alc-app-s3 (M5Stack CoreS3 ハブ) の「画面が切れる/消える・再起動する・落ちた」を切り分けるトリアージ手順と、クラッシュログ基盤 (2026-07-14 導入、ippoan/alc-app-s3#43/#44) のリファレンス。panic 前ログは .noinit リング → 復帰後 kind=crash_log を WS 送信 → cf-alc-recorder (DO) が R2 bucket alc-crash-logs へ直書き + メール通知 (backend hub_measurements へは流さない)。画面消失の A/B/C/D 切り分け表、R2/Observability での確認クエリ、dev ビルド (mem-hud) 配信、既知の罠 (mimetext は nodejs_compat 必須 / OTA 後照会のゾンビ WS / 構造化ログの filter は event キー) を収録。トリガー:「CoreS3 画面が切れる」「画面が消える」「crash_log」「クラッシュログ」「EVT CRASH」「alc-crash-logs」「panic 前ログ」「reset_reason」「brownout」「dev ビルド 配信」「mem-hud」「メモリ HUD」「CoreS3 再起動」「クラッシュ通知メール」等。
---

# cores3-crash-triage — CoreS3 の画面消失/クラッシュ切り分け

対象: `ippoan/alc-app-s3` (CoreS3 統合ハブ firmware) + `ippoan/alc-app` cf-alc-recorder。
導入経緯: 2026-07-14 に実機 `Q3SXkQPvnM1CBtVAsQimOA` で「画面が切れる」が 2 回発生
(当時は記録手段なし) → クラッシュログ基盤を実装 (alc-app-s3#43, #45 / alc-app#114 #115 #116)。

## アーキテクチャ (crash_log の流れ)

```
CoreS3 firmware
  ├ .noinit DRAM リング 4KB (ソフトリセットで保持、電源断は magic 検証で判定)
  │   ← esp_log 全部 (vprintf tee) + Rust panic メッセージ (panic hook) + EVT HEAP
  ├ 起動時 esp_reset_reason() がクラッシュ由来 (panic/int_wdt/task_wdt/wdt/
  │   brownout/pwr_glitch/cpu_lockup) なら snapshot を kind="crash_log" で
  │   既存 WS キュー (NVS 永続・ack 冪等) へ。RAM 未保持でも reason だけは送る
  ↓ WSS
cf-alc-recorder (RecorderHub DO / POST /measurements)
  ├ R2 `alc-crash-logs` に直書き — key: {tenant}/{device}/{seq 12桁0詰}.json (再送冪等)
  ├ メール通知 (send_email binding CRASH_EMAIL → m.tama.ramu@gmail.com、best-effort)
  └ backend (rust-alc-api hub_measurements) へは **流さない** (allowlist に crash_log 無し。
     rust-alc-api#570 は #571 で revert 済み — 復活させないこと)
```

- payload: `{type, reset_reason, reset_code, version, slot, truncated, log(末尾1KB)}`
  + R2 object に tenant/device/seq/recorded_at_ms/received_at_ms
- 純粋ロジックは `crates/hub-core/src/crashlog.rs` (coverage 100% 対象)、
  firmware 側 `crates/hub-drivers/src/crashlog.rs`、ホストへは `EVT CRASH <reason>`、
  Log 画面に「crash 復帰」イベント

## 画面が消えたままの切り分け (A/B/C/D)

単発 panic は数秒で再起動して Idle に戻る — 「消えたまま」は以下のどれか:

| | シナリオ | crash_log | WS 接続 | 備考 |
|---|---|---|---|---|
| A | クラッシュループ (画面 init 前に落ち続ける) | 復帰時にまとめて届く (NVS 永続) | 断続 | 前科: #40 SPI 二重 init panic ループ、BLE_INIT Malloc failed |
| B | 起動途中 hang (I2C 無限待ち等) | 出ない (reset していない) | 切れたまま | /device/setup で未接続が続く |
| C | 画面系だけ死亡 (LCD/SPI wedge、UI 停止) | 出ない | **接続中のまま** | 現計装で唯一直接捕まらない → UI heartbeat 追加が次の一手 |
| D | 電源 (給電断/brownout) | reason=brownout (log は空になり得る) | 断 | |

## 確認手順

1. **メール**: 件名 `[alc] CoreS3 crash: <reason> (<device_id>)` が届いていればそれが一次情報。
2. **R2**: dashboard または `npx wrangler r2 object get alc-crash-logs/<tenant>/<device>/<seq>.json`。
   prefix 一覧は `wrangler r2 object list --prefix {tenant}/{device}/`。
3. **Workers Observability** (cf_logging MCP / dashboard):
   service `alc-recorder` (staging は `alc-recorder-staging`) で `[crash_log] stored` を検索。
   - **罠**: JSON 構造化ログは `$metadata.message` の includes では引けない —
     フィールド名 (例 `event`) を直接 filter キーにする。groupBy に「そのイベントに
     存在しないキー」を混ぜると 0 件になる。plain 文字列ログ (`[crash_log] ...`) は
     message includes で引ける。
4. **端末側**: USB で `EVT CRASH` 行 / Log 画面の「crash 復帰」。

## dev ビルド (mem-hud) 配信

- 開発機はステータスバーに RAM/PSRAM 使用率が出る dev ビルドで運用する。
- 配信: https://auth.ippoan.org/device/setup — developer アカウント
  (`DEVELOPER_EMAILS`) にのみ「CoreS3 は dev ビルドを配信」checkbox が出る →
  OTA URL が `alc-hub-cores3-dev-app.bin` に切り替わる (alc-app-s3#44)。
  CI (build.yml cores3 leg) が `--features mem-hud` で dev バリアントを Pages に公開。
- 通常ビルドで OTA すると HUD が消える (このための checkbox)。

## 既知の罠

- **mimetext (メール通知) は `nodejs_compat` 必須** — 外すと wrangler bundle が
  `Could not resolve "path"` で fail (alc-app#116)。PR CI では捕まらない
  (deploy job は main/tag 限定 + dynamic import で test 未到達)。
- **OTA 後のバージョン照会**: 再起動でゾンビ WS が recorder に残り「接続中」に
  見えるため、初回照会はタイムアウトし得る。/device/setup は成功まで 120s
  リトライする (auth-worker#390)。照会タイムアウト ≠ 更新失敗。
- **cf-alc-recorder の本番反映は alc-app の v* タグのみ** (main push は staging まで)。
- **coredump パーティションは未導入** — C レベル crash の backtrace は取れない
  (要再フラッシュのため見送り)。Rust panic はメッセージ + 位置が ring に入る。
- crash_log の WS payload はログ末尾 1KB に切り詰め (NVS キュー 4KB 制約)。
  フル 4KB は端末リング内のみ。

## 関連

- 実装 PR: alc-app-s3#45 (firmware + dev CI) / alc-app#114 (R2) #115 (メール) #116
  (nodejs_compat) / auth-worker#386 (dev 選択) #390 (照会リトライ)
- issue: ippoan/alc-app-s3#43 (基盤) #44 (dev 配信)
