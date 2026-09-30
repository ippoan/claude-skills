---
name: alc-workers-ops
description: rust-alc-api を Cloudflare Workers に分割した後の運用 (migration の置き場、worker のデプロイと版、secret、auth-worker の振り分け)。rust-alc-api / alc-migrations / auth-worker / workers/* を触る前に読む。トリガー: migration / マイグレーション / alc-migrations / workers/vein / worker デプロイ / worker-vein / Service Binding / ALC_VEIN / version_metadata / 6543 / Supavisor 等。
---

# alc-workers-ops — 分割 worker と migration の運用

rust-alc-api を Cloudflare Worker に分割していく運用 (ippoan/rust-alc-api#697)。
vein が最初の worker で本番に出ている。**事実だけを書く。ホスト名・IP・account ID・
Tunnel ID・Supabase の project ref・プーラーのホスト名はここにも PR にも書かない。**

## 1. migration の正本は ippoan/alc-migrations

- 新しい migration は **alc-migrations に PR を出す**。
- rust-alc-api の `migrations/`・`scripts/init_local_db.sql`・`scripts/local_app_grants.sql` は
  **切り替えまで追加・変更禁止**。`ci.yml` の `pr-limit` job の step が落とす
  (rust-alc-api#700)。削除だけは通る。
- alc-migrations の中身: 薄い crate `alc-migrations` (`MIGRATOR` = `sqlx::migrate!`、
  `INIT_LOCAL_DB`、`LOCAL_APP_GRANTS`、feature `cli` の `alc-migrate` バイナリ)。
- **版の規約**: minor = 最新の migration 番号 (例 `0.152.0`)、patch = SQL 以外の変更。
  migration を足したら minor を上げる。
- 133 番は欠番 (埋めない)。`_sqlx_migrations` は 151 件・最大 152。
- CI は test / replay (postgres に 0 から流す) / safety で、約 1.5 分。
- 公開: tag `v*` → crates.io の trusted publishing。**初回だけは手で公開が要る (未実施)**。
- rust-alc-api をこの crate に切り替えるのは**未実施** (テストの `sqlx::migrate!` を
  `alc_migrations::MIGRATOR` に替え、`migrations/` を消す)。
- 規範:
  - 適用済み migration は変えない (checksum は SQL 本文の SHA-384)。
  - 既定は足すだけ (expand)。消す・名前を変えるのは全 worker が移った後に別 PR (contract)。
  - `SECURITY DEFINER` には `SET search_path = alc_api`。

## 2. 分割 worker の置き場と公開範囲

- rust-alc-api の `workers/<名前>/` に**独立した Cargo workspace** として置く (vein が最初)。
  ターゲットは `wasm32-unknown-unknown`、`worker-build` 0.8.7。
- 本番は `workers_dev = false`・`preview_urls = false`・route なし。
  **auth-worker から Service Binding でだけ呼ばれる**。
- `scripts/check-exposure.sh` と陰性対照 `check-exposure-test.sh` を CI で回す。
  **陰性対照は wrangler.toml の特定の表の直前に行を挿す作りなので、末尾に表を足すと
  検出できなくなる** (rust-alc-api#698 で実際に踏んだ)。
- JWT を検証するのは auth-worker だけ。domain worker は付け直されたヘッダ
  (`X-Tenant-ID` 等) を信頼する。

## 3. デプロイと版

- `.github/workflows/vein-deploy.yml`:
  - tag `worker-vein-v*` → 本番に `wrangler deploy --tag <タグ> --message <git SHA>`
  - main への merge (vein 関連の paths) → staging
  - PR → `--dry-run`
- 本番のタグは `/tag-release` を `target=worker-vein` で打つ (共通 tag-release の `prefix`)。
- **`vein-v*` は使えない**: monolith の `v*` (ci.yml / deploy.yml) に当たり、本番の
  migration とデプロイが発火する。worker のタグは `worker-<名前>-v*`。
- 応答ヘッダ `x-worker-version` (Cloudflare の version id) と `x-worker-tag` で、どの版が
  応答したか分かる。`[version_metadata]` は env に継承されないので、**トップレベルと
  `env.staging` の両方**に書く。
- `wrangler secret put` は新しい版を作って即デプロイするので、その版にはタグが付かない
  (`x-worker-tag` が空になる)。
- 版の一覧は ci-dashboard に集める方針 (未実装: `traffic-report` に git_sha / environment、
  migration-applied の hook)。

## 4. secret と token

- Cloudflare の token は **org の secret `CLOUDFLARE_API_TOKEN`** を使う。repo 単位に同名の
  secret を置かない (repo 単位の古い無効な token が org を上書きしてデプロイが落ちた。
  ユーザー「orgつかえよ」)。
- **Secret Manager に secret を増やさない。** 先に既存のものが使えないか確かめる
  (ユーザー「すでに secret 入ってるはずでしょ ふやすな」)。
- vein の本番 `DATABASE_URL` は、既存の DB 接続の secret を元に shell の中で Supavisor 用
  (東京・6543・transaction mode) に組み替えて `wrangler secret put` した (値はどこにも出さない)。

## 5. DB 接続の規範

- monolith (session スコープの RLS) は直接接続の 5432。
- worker は `in_tenant_tx` でトランザクション単位の RLS (`set_config(..., true)`) にする
  場合に限り 6543。
- Row を COMMIT 後まで持つと 42P05 になるので、戻り値は `TxOutput`。
- worker は `placement.region` を DB の近く (`aws:ap-northeast-1`) に固定する。

## 6. auth-worker の振り分け

- `src/lib/alc-backend-route.ts` の `ALC_BINDING_ROUTES` に 1 行と、`wrangler.toml` の
  `[[services]]` を足せば、その path prefix が worker に回る (未定義なら Cloud Run)。
- `ALC_VEIN` は**本番だけ** (staging には bind しない)。
- **auth-worker は main への merge で `v*` のタグが自動で付く。** 手で Tag Release を
  打たない (二重タグになる)。本番へは Release Wave で切り替わる。flip の完了は
  1 回見ただけで判定しない。

## 7. 関連

rust-alc-api#697 / #680 / #695、ippoan/alc-migrations、rust-alc-api の `rust-alc-api-map` skill、
`migrate-test` skill。
