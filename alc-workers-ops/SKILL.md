---
name: alc-workers-ops
description: rust-alc-api を Cloudflare Workers に分割した後の運用 (migration の置き場、worker のデプロイと版、secret、auth-worker の振り分け)。rust-alc-api / alc-migrations / auth-worker / 分割 worker の repo (alc-vein-worker 等) を触る前に読む。トリガー: migration / マイグレーション / alc-migrations / alc-vein-worker / 分割 worker の repo / worker デプロイ / Service Binding / ALC_VEIN / version_metadata / 6543 / Supavisor 等。
---

# alc-workers-ops — 分割 worker と migration の運用

rust-alc-api を Cloudflare Worker に分割していく運用 (ippoan/rust-alc-api#697)。
**worker は worker ごとに別の repo に置く** (最初は ippoan/alc-vein-worker。
ippoan/rust-alc-api#721。2026-10-02 までは rust-alc-api の `workers/vein/` に在った)。
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

- **worker ごとに別の repo** に置く (vein は ippoan/alc-vein-worker。オーナーが vein で選んだ形で、
  2 本目 = ippoan/rust-alc-api#725 もこれに合わせる予定)。同じ repo に在ると、worker だけの変更でも
  backend の CI・タグ `v*`・再配信・Release Wave が動き、rust-alc-api の「作者あたり open PR 1 本」も
  取り合うため (ippoan/rust-alc-api#721)。
- alc-vein-worker の配置: worker は repo の直下 (`Cargo.toml`・`wrangler.toml`・`src/`・`scripts/`・
  `tests/`・`container/`)、route の crate は `crates/<名前>/` (vein は `crates/alc-vein/`)。直下の
  `Cargo.toml` が workspace の root で、`Cargo.lock` は 1 つ。ターゲットは `wasm32-unknown-unknown`、
  `worker-build` 0.8.7。
- **共有 crate `alc-core-wasm` は rust-alc-api に残り**、worker の repo から **git 依存 (rev 固定)** で引く。
  直下の `[workspace.dependencies]` の **1 か所にだけ**書き、worker と `crates/<名前>` は
  `workspace = true` で継承する。**出どころが 2 つになると `TenantId` が別の型になり、コンパイルは通るのに
  全リクエストが 500 になる** (tenant ヘッダーの layer が入れる型と route が取り出す型が合わない)。
  backend と worker の両方が同じ route の crate を使う形 (ひし形) を作らない。
  確かめ方: `cargo tree -i alc-core-wasm --target wasm32-unknown-unknown` で出どころが 1 つ。
- 本番は `workers_dev = false`・`preview_urls = false`・route なし。
  **auth-worker から Service Binding でだけ呼ばれる**。
- `scripts/check-exposure.sh` と陰性対照 `check-exposure-test.sh` は worker の repo に在り、その repo の CI で回す。
  **陰性対照は wrangler.toml の特定の表の直前に行を挿す作りなので、末尾に表を足すと
  検出できなくなる** (rust-alc-api#698 で実際に踏んだ)。
- JWT を検証するのは auth-worker だけ。domain worker は付け直されたヘッダ
  (`X-Tenant-ID` 等) を信頼する。

## 3. デプロイと版

- worker の repo の `.github/workflows/deploy.yml` (alc-vein-worker):
  - PR → `wrangler deploy --dry-run`
  - main への merge → staging (`--env staging`)
  - **タグ `v*` → 本番**に `wrangler deploy --tag <タグ> --message <git SHA>`
- 本番のタグは、その repo の Tag Release (手動 `workflow_dispatch`、入力 `bump` = patch / minor / major)
  で打つ。**マージでの自動タグは無い** (マージ = staging、手動のタグ = 本番)。手で `v*` を push しない。
  タグが 1 つも無いときの最初は `bump=minor` で `v0.1.0`。
- 単独 repo なので `v*` が backend のタグと当たらない。**rust-alc-api の `tag-release.yml` から入力
  `target` は無くなった**ので、接頭辞付きのタグ (`worker-vein-v*`) と `target=worker-vein` はもう使わない。
  rust-alc-api で `v*` を打つと backend の本番 migration と配信が走るのは今までどおり。
- staging の DB の image が使う SQL は、ippoan/alc-migrations を rev 固定で取る
  (worker の repo の `container/ALC_MIGRATIONS_REV` と `scripts/fetch-migrations.sh`)。
- 応答ヘッダ `x-worker-version` (Cloudflare の version id) と `x-worker-tag` で、どの版が
  応答したか分かる。`[version_metadata]` は env に継承されないので、**トップレベルと
  `env.staging` の両方**に書く。
- `wrangler secret put` は新しい版を作って即デプロイするので、その版にはタグが付かない
  (`x-worker-tag` が空になる)。
- 版の一覧は ci-dashboard に集める方針 (未実装: `traffic-report` に git_sha / environment、
  migration-applied の hook)。

## 4. secret と token

- Cloudflare の token は **org の secret `CLOUDFLARE_API_TOKEN`** を使う。repo 単位に同名の
  secret を置かない (新しい worker の repo でも同じ。repo 単位の古い無効な token が org を上書きしてデプロイが落ちた。
  ユーザー「orgつかえよ」)。
- **Secret Manager に secret を増やさない。** 先に既存のものが使えないか確かめる
  (ユーザー「すでに secret 入ってるはずでしょ ふやすな」)。
- vein の本番の DB 接続は、Secrets Store の binding `VEIN_DATABASE_URL` から接続文字列を読む形
  (ippoan/rust-alc-api#720。値はどこにも出さない)。Hyperdrive 経由に替える予定が在る
  (ippoan/rust-alc-api#723、未着手)。

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

rust-alc-api#697 / #680 / #695 / #721 / #723 / #725、ippoan/alc-vein-worker、ippoan/alc-migrations、rust-alc-api の `rust-alc-api-map` skill、
`migrate-test` skill。
