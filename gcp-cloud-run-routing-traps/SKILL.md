---
name: gcp-cloud-run-routing-traps
description: Cloud Run の「service は Ready なのに外から 404 / 届かない」系の診断・対処リファレンス。2026-06 の ippoan/rust-flickr cutover (ippoan/cf-flickr-proxy#1) で実測した確定知識。(1) Google フロント (run.app / ghs) は外部からの `/healthz` をインターセプトして汎用 404 を返す — health endpoint は `/health` を使う、(2) 404 は「Google 汎用 / Cloud Run インフラ / アプリ」の 3 種を body で鑑別する、(3) 新規 service の run.app hostname は GFE への配布ムラで一部経路 (US colo の CF Worker fetch 等) から数時間 404 になることがある、(4) domain mapping の managed cert は HTTP-01 challenge が 302 redirect に食われ CertificatePending が長引くことがある、(5) Cloud Run MCP / 手動 deploy は digest pin + per-secret IAM grant。トリガー:「Cloud Run 404」「That's an error」「run.app 届かない」「healthz 404」「health check 通らない」「CertificatePending」「domain mapping 証明書」「certificate provisioning stuck」「SECRETS_ACCESS_CHECK_FAILED」「Cloud Run deploy したのに見えない」「Worker から Cloud Run fetch できない」「ghs.googlehosted.com」「Google-Certificates-Bridge」等。
---

# gcp-cloud-run-routing-traps

Cloud Run「Ready なのに届かない」系の罠と診断。ippoan/cf-flickr-proxy#1 の cutover
(2026-06-09〜10、`rust-flickr-staging` @ cloudsql-sv/asia-northeast1) で全項目を実測済み。

## 罠 0 (最重要): `/healthz` は Google フロントに食われる

**run.app / ghs (domain mapping) の Google フロントは、外部からの `GET /healthz` を
インターセプトして Google 汎用 404 を返す。アプリには届かない。**

- service が Ready で `/` `/import` 等の他 path はアプリに届くのに、`/healthz` だけが
  run.app と domain mapping の両方で同一の Google 404 HTML (1568 bytes) になる
- GCP 内部経路や一部の接続元には届くことがあり「配布障害」と誤診しやすい (今回
  数時間の迷走の主因)
- **ippoan の Cloud Run service が `/health` 標準なのはこのため** (secrets-inventory-gcp /
  release-wave-gcp / rust-alc-api…)。新規 service の health endpoint は必ず `/health`。
  既に `/healthz` の app には alias を足す (rust-flickr#8 の例: 同一 handler を
  `.route("/health", get(healthz))` で 2 path に bind)
- 外形監視・cutover 検証を `/healthz` でやらない。**やると偽陰性で永遠に「未開通」に見える**

## 404 の三種鑑別 (最初にやる)

| body | 出所 | 意味 |
|---|---|---|
| Google 汎用 404 HTML (~1568B、`That's an error!!1` + robot 画像) | GFE | hostname 未配布 or `/healthz` interception。**request log に出ない** |
| `Error: Not Found` スタイルの素朴な HTML | Cloud Run インフラ | Cloud Run 層には到達。service 不在 / ready revision 無し / 旧 URL |
| アプリ固有の応答 (axum なら空 0B 404 / JSON、405 + `Allow` 等) | アプリ | **正常到達** |

決定打は **Cloud Run の request log** (`run.googleapis.com%2Frequests`): ログに出ていれば
到達、出ていなければ GFE 手前で死んでいる。`GET /import` (POST-only route) に 405 が
返るかは「アプリ到達」の最速プローブ。

## 罠 1: 新規 service の run.app hostname 配布ムラ

新規作成した service の run.app URL が、**接続元によって** Google 汎用 404 になる
ことがある (bot や GCP 内部からは届くのに、US colo 発の CF Worker fetch や特定 egress
からは 404)。同 project の既存 service は同じ経路で正常、という differential が特徴。

- 数時間続くことがあり、**service の削除→同名再作成では直らないことがある**
- DNS は無関係 (動く service と同一の GFE anycast IP に解決される)。HTTP/1.1 強制も無関係
- 対処: (a) **Cloudflare Workers から叩く場合は Smart Placement** (`placement: {mode:
  "smart"}`) で fetch を宛先リージョン発にする、(b) **domain mapping 経由** (ghs の
  ルーティングは別パイプライン)、(c) 時間待ち。実測では数時間で自然解消した
- 検証時は `/healthz` を使わない (罠 0 と重なると切り分け不能になる)

## 罠 2: domain mapping の managed cert が CertificatePending で長引く

`gcloud beta run domain-mappings create` 後、`DomainRoutable: True` (DNS 認識済み) でも
`CertificateProvisioned: CertificatePending` が続くことがある。

- **CF DNS は必ず DNS only (グレー雲)**。Proxied だと検証も origin TLS も成立しない
- CAA record は**無ければ無いで OK** (全 CA 発行可)。確認は DoH:
  `curl -H "accept: application/dns-json" "https://cloudflare-dns.com/dns-query?name=<zone>&type=CAA"`
- 機械的原因の実測例: **HTTP-01 challenge (`Google-Certificates-Bridge` UA) が service の
  request log に素通しされ、Cloud Run の http→https 302 redirect を食らって失敗し続ける**
  (本来はフロントがインターセプトして応答する)。CA は新 token で再試行し続け、フロント側
  配線が追いつくと発行される — 今回は mapping 作成から ~1.5h で発行された
- `Retry after 01:00/05:00` 表示は describe の同期ポーリング間隔で、CA の発行試行とは別。
  **mapping の delete→create でポーリングをリセット**できる (DNS が正しければ初回チェック即通過)
- 発行完了の検知は describe より「TLS handshake が通るか」が早い (接続切断 → HTTP 応答に変わる)
- 証明書は**ホスト名単位** (ワイルドカード無し)。mapping は **1 domain = 1 service**。
  既存 mapping (例: cloudrun-backend.mtamaramu.com → rust-logi) の cert/mapping は流用不可

## 罠 3: 手動 / MCP deploy の要点

`mcp__cloudRun_MCP__deploy_service_from_image` は secretKeyRef フル対応 (wrangler 相当の
1 発 deploy が可能)。CI (cloud-run-deploy.yml) が使えない時の代替として有効。

- **image は digest pin** (`...@sha256:<digest>`)。`:latest` 文字列のままだと template が
  不変扱いになり新 revision が作られないことがある。GHCR public package の digest 取得:
  ```sh
  TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:<org>/<repo>:pull" | jq -r .token)
  curl -sI -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
    "https://ghcr.io/v2/<org>/<repo>/manifests/latest" | grep -i docker-content-digest
  ```
- `SECRETS_ACCESS_CHECK_FAILED` → runtime SA に **per-secret** の accessor grant
  (project 全体には付けない):
  ```sh
  gcloud secrets add-iam-policy-binding <secret> --project=<proj> \
    --member="serviceAccount:<runtime-sa>" --role="roles/secretmanager.secretAccessor"
  ```
  grant 後は**同一 template の再 submit でも IAM 再評価され Ready になる** (この場合は
  digest 変更不要)。失敗 revision は traffic に乗らないので deploy 失敗は安全
- `--allow-unauthenticated` 相当は `invokerIamDisabled: true` を明示する

## 診断テクニック (CCoW から)

- **request log が出るか**が GFE 手前/到達の決定打 (上記)。Worker 側は
  `mcp__cf_logging__query_worker_observability` で fetch の応答 (wallTimeMs ~100ms で
  404 = 米国内エッジ折り返し) を読む
- CCoW の egress は TLS MITM (Anthropic CA) なので **upstream の本物の cert chain は
  見えない**。cert 発行確認は挙動 (接続切断→応答) か user のブラウザで
- CCoW の egress resolver は negative cache むらがある (getent は解決するのに curl が
  Could not resolve を返す等)。DoH (`cloudflare-dns.com/dns-query`) が安定
- **Cloud Shell は Google 内部経路**なので「内部からは届くか」の比較プローブに使える
- 公開 status (status.cloud.google.com) に出ない部分不調は普通にある。広域障害なら
  コミュニティが騒ぐ — 直近報告が無ければ project/リソース局所の問題を疑う
