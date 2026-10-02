---
name: alc-workers-ops
description: rust-alc-api を Cloudflare Workers に分割した後の運用 (migration の置き場、worker のデプロイと版、secret、auth-worker の振り分け)。rust-alc-api / alc-migrations / auth-worker / 分割 worker の repo (alc-vein-worker 等) を触る前に読む。トリガー: migration / マイグレーション / alc-migrations / alc-vein-worker / alc-worker-kit / alc-worker-db / 分割 worker の repo / worker デプロイ / Service Binding / ALC_VEIN / version_metadata / Hyperdrive / tenant_tx / query_typed / 6543 / Supavisor 等。
---

# alc-workers-ops — 分割 worker と migration の運用

rust-alc-api を Cloudflare Worker に分割していく運用 (ippoan/rust-alc-api#697)。
**worker は worker ごとに別の repo に置く** (最初は ippoan/alc-vein-worker。
ippoan/rust-alc-api#721。2026-10-02 までは rust-alc-api の `workers/vein/` に在った)。
vein が最初の worker で本番に出ている (2026-10-02 に、本番の DB 接続を Hyperdrive 経由にした。
ippoan/rust-alc-api#723)。**事実だけを書く。ホスト名・IP・account ID・
Tunnel ID・Supabase の project ref・プーラーのホスト名・Hyperdrive の設定の ID・証明書の ID は
ここにも PR にも書かない。**

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
- **DB の部品の共有 crate `alc-worker-db` は ippoan/alc-worker-kit (public) に在る** (`crates/alc-worker-db`。
  いま kit に在る crate はこの 1 つ)。引き方は `alc-core-wasm` と同じ: **git 依存 (rev 固定)** で、直下の
  `[workspace.dependencies]` の **1 か所にだけ**書き、worker と `crates/<名前>` は `workspace = true` で継承する
  (出どころが 2 つになると `PgClient` が別の型になる)。**kit は tag を打たない。** kit は `alc-core-wasm` に依存しない。
  最初の利用者は vein で、2 本目 (ippoan/rust-alc-api#725) もこの crate を引く予定。
  rev を上げたら `cargo update -p alc-worker-db` で `Cargo.lock` も更新し、worker の repo の実 DB のテストを通す。
- `worker`・`tokio-postgres` も、kit と利用側で 1 つの版に解決すること
  (`cargo tree -i <名前> --target wasm32-unknown-unknown` で確かめる)。
- 本番は `workers_dev = false`・`preview_urls = false`・route なし。
  **auth-worker から Service Binding でだけ呼ばれる**。
- **Hyperdrive の binding (`[[hyperdrive]]`) はトップレベル (本番) にだけ置く。** `env.*` の下
  (staging を含む) の hyperdrive は `scripts/check-exposure.sh` が落とす (本番の DB へ届く binding を、
  workers.dev が開いている staging に置かないため)。binding は env に継承されない。
- `scripts/check-exposure.sh` と陰性対照 `check-exposure-test.sh` は worker の repo に在り、その repo の CI で回す。
  **陰性対照は、`[build]` の初出の直前と `[env.staging.observability]` の直前に行を挿して崩す作り**
  (挿した行がトップレベル / `[env.staging]` に入る前提)。**`[build]` より前に表を足す、または
  `[env.staging]` と `[env.staging.observability]` の間に表を挟むと、挿した行がその表の中に入り、
  検査が意味を失う。** 新しい表は `[build]` より後に置く (経緯は ippoan/rust-alc-api#698)。
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
- **vein の本番の DB 接続は Hyperdrive 経由** (binding `VEIN_HYPERDRIVE`。alc-vein-worker のタグ `v0.1.1`、
  ippoan/rust-alc-api#723)。それまでの Secrets Store の binding `VEIN_DATABASE_URL` の段
  (ippoan/rust-alc-api#720) は無くなった。`wrangler.toml` に書くのは Hyperdrive の設定の ID だけで、
  接続先と資格情報は設定の側に在る (repo に書かない)。
- **Hyperdrive の設定は、実行用ロールのもの 1 つを複数の worker で共有する** (worker ごとに作らない)。
  query caching は無効。
- 設定の作成・更新 (`wrangler hyperdrive create` / `update`) は**オーナーの端末で打つ**。出力に接続先が
  含まれるので、貼るのは必要な項目だけ。値を人にも LLM にも見せない。
- **DB の証明書の検証 (`verify-full`) は設定の側に在り、repo と CI からは検査できない。** 設定は共有なので、
  後の `hyperdrive update` で戻っても repo は気づけない。確かめ方: `npx wrangler hyperdrive get <ID>` の
  `mtls.sslmode` が `verify-full`・`caching.disabled` が `true` (貼るのはその 2 項目だけ)。
- **資格情報の入れ直し (rotate) は 2 か所**: Secret Manager の secret と、Hyperdrive の設定。設定の更新は
  反映された時点から効く (worker の deploy は要らない)。

## 5. DB 接続の規範

- monolith (session スコープの RLS) は直接接続の 5432。
- worker は `alc-worker-db` の `PgClient::tenant_tx` を通してトランザクション単位の RLS
  (`BEGIN` → `set_config(..., true)` と search_path → 本文 → `COMMIT`) にする場合に限り 6543。
  テナントを設定しない transaction を作る口は無い。
- Row を COMMIT 後まで持つと 42P05 になるので、戻り値は `TxOutput` (transaction の外へ持ち出してよい
  owned な値の印。`Row` には付かないので、外へ返すコードはコンパイルが通らない)。
- **名前付き prepared statement (tokio-postgres の `execute`・`query`・`query_one`・`query_opt`・`prepare`) を
  呼ばない。Hyperdrive 経由では接続が切れる。** 使うのは `TenantTx` の `query_typed`・`query_typed_one`・
  `query_typed_opt`・`execute_typed` (型付きの名前なしの文)。kit は `Client` と `Transaction` を呼び手に
  渡さない型で塞いでいる (`PgClient` の口は `new`・`current_user`・`tenant_tx` の 3 つ、`TenantTx` は上の 4 つ)。
  同じ文は staging の PgBouncer (transaction mode、`max_prepared_statements = 0`) も通る
  (staging と本番で同じコードが動き、違うのは接続の段だけ)。
- 型で塞げないもの: 型付きの 1 文として `COMMIT` や `set_config(.., false)` を流すこと。SQL の中身は
  各 worker の定数とレビューで見る。
- `tenant_tx` の閉包の制約は 2 つ。借用 (`&str` など) を持ち込めない (先に owned にして
  `move |tx| Box::pin(async move { … })`)。Future に `Send` を要求するので、R2 など JS の値の await を
  transaction の中に挟めない (短い transaction を 2 回に分ける)。
- Hyperdrive への接続は kit の `hyperdrive::connect` (wasm32 専用): binding が無い = `Ok(None)` /
  在るのに使えない = `Err` / 繋がった = `Ok(Some)`。エラーは `kind` で識別子を含まない label に落とす。
- vein の `src/db.rs` の段の順: VPC (staging) → DO (staging の fallback) → Hyperdrive `VEIN_HYPERDRIVE` (本番) →
  文字列 `DATABASE_URL` (ローカル専用)。**Hyperdrive の binding が在るのに使えないときは 500 で、次の段へ
  落ちない** (落ちるのは binding が無いときだけ)。staging は Hyperdrive を通さない (VPC → PgBouncer のまま)。
  ローカルの `wrangler dev` は binding を持たない `--env local` で立てる。
- vein の repo の実装は `crates/alc-vein/src/pg.rs` の 1 つで、worker と実 DB のテスト (`sql_db.rs`) が同じものを使う。
- **Hyperdrive の経路は CI では通せない** (ローカルの `wrangler dev` は Hyperdrive を通らない。kit の
  `hyperdrive` module は native では compile されず、CI が見るのは wasm32 の clippy とビルドまで)。
  配信せずに実物を通す手段: `npx wrangler@latest dev --remote --env <env> --test-scheduled` を立てて
  `/__scheduled` を叩く (ippoan/workers-rs-containers-lab の `probe-hyperdrive/`。外から届く口を持たない実験用 worker)。
- worker は `placement.region` を DB の近く (`aws:ap-northeast-1`) に固定する。
  placement は fetch で呼ばれる worker には効くが、定時実行と `wrangler dev --remote` には効かない
  (速度はそこでは測れない)。

## 6. auth-worker の振り分け

- `src/lib/alc-backend-route.ts` の `ALC_BINDING_ROUTES` に 1 行と、`wrangler.toml` の
  `[[services]]` を足せば、その path prefix が worker に回る (未定義なら Cloud Run)。
- `ALC_VEIN` は**本番だけ** (staging には bind しない)。
- **auth-worker は main への merge で `v*` のタグが自動で付く。** 手で Tag Release を
  打たない (二重タグになる)。本番へは Release Wave で切り替わる。flip の完了は
  1 回見ただけで判定しない。

## 7. 関連

rust-alc-api#697 / #680 / #695 / #721 / #723 / #725、ippoan/alc-vein-worker、ippoan/alc-worker-kit、
ippoan/workers-rs-containers-lab (`probe-hyperdrive/`)、ippoan/alc-migrations、rust-alc-api の `rust-alc-api-map` skill、
`migrate-test` skill。
