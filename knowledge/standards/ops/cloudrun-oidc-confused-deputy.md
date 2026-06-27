---
title: Cloud Run で proxy が OIDC を mint する時は用途別 custom audience で confused-deputy を防ぐ
category: ops
status: recommended
recommended: 用途 (data / internal 等) ごとに別 aud で OIDC ID token を mint し、受け手が aud を検証する
decision: 2026-06-27-auth-migration-oidc-custom-audience
---

OIDC ID token は SA が mint し claim は固定(`aud` 以外に tenant/role 等 custom claim は載らない)。
1 つの SA key で複数用途(公開 data forward と internal endpoint)の OIDC を mint すると、片方の経路が
もう片方の保護対象に到達できる「confused-deputy」になる。**用途ごとに `aud` を分けて受け手で検証**して防ぐ。

- Cloud Run は 1 service に複数 audience を設定可(default の `*.run.app` URL は常に有効 +
  `gcloud run ... --add-custom-audiences=<aud>`)。`aud` の集合は Cloud Run IAM が署名と共に検証し、
  Authorization の ID token は backend にも素通しされるので app 側で `aud` を更に絞れる。
- 例(rust-alc-api #434): `/alc-proxy`(user data forward)は `aud=service URL`、auth-worker→rust の
  `/api/internal/*` は `aud=alc-api-internal`。internal middleware が `aud=alc-api-internal` を要求するので、
  consumer が `/alc-proxy/api/internal/…` で internal に到達しようとしても aud 不一致で弾かれる。
- env 分離(staging/prod)は service URL / custom aud が env ごとに異なるため OIDC audience が自動で担保
  (staging の token を prod に replay しても aud 不一致)。
- mint 側は audience 引数を変えるだけ(例: `mintGoogleIdToken(saKey, "alc-api-internal")`)。
- 注意: `aud` は「どの用途向けか」の静的スコープ。tenant/user/role は別途ヘッダ(`X-Tenant-ID`/`X-User-*`)で運ぶ。

参考: GCP docs "Set custom audiences for services" / "Confused Deputy Attack on Cloud Run"。
