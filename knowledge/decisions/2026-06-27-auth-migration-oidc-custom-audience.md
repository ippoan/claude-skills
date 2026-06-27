---
title: rust-alc-api の認証を auth-worker に移管し OIDC custom audience で守る (#434)
date: 2026-06-27
status: active
tags: [auth, oidc, cloudflare, cloud-run, confused-deputy]
repo: rust-alc-api
issue: 434
---

## Summary

LINE/LINE WORKS の OAuth を auth-worker に移管し rust を dumb backend 化する。auth-worker→rust の
internal call は OIDC `aud=alc-api-internal`、data call は `aud=service URL` で分離し confused-deputy を防ぐ。
tenant/role はヘッダ注入、ログイン保持は cookie(`logi_auth_token`)。

## Context

`require_tenant` の bare `X-Tenant-ID` フォールバックが無認証アクセスを許していた(#434)。#441 で rust を
「注入 identity を信頼する dumb backend」化したため、Cloud Run を `--no-allow-unauthenticated` で lockdown
(= `allUsers` 削除)しない限り header 直注入で認証バイパス可能。lockdown には rust から公開認証エンドポイント
(`/api/auth/{line,lineworks}/*`)を無くす必要がある。

ログインフロー(確定):
1. browser → `auth.ippoan.org/oauth/line/redirect`(開始)
2. auth-worker → LINE authorize
3. user 承認 → auth-worker `/oauth/line/callback?code=…`
4. auth-worker が code 交換 → profile 取得(自前)
5. auth-worker ──OIDC(`aud=alc-api-internal`)──▶ rust `/api/internal/auth/users/…`(user 確認/upsert)
6. rust → auth-worker に user 情報(id/tenant/role/slug)
7. auth-worker が JWT 発行(`JWT_SECRET`)
8. auth-worker が cookie(`logi_auth_token=JWT`)set + `redirect_uri#token=…`

auth-worker は移管に必要な道具を既に保有: `JWT_SECRET`(rust と共有、`/alc-proxy` でローカル JWT 検証済み)、
`ALC_API_PROXY_SA_KEY`(OIDC mint)、`signInternalJWT`(rust `/api/internal/*` を叩く既存配線)。

## Decision

**案B: OIDC 一本化 + Cloud Run custom audiences。**

- auth-worker が OAuth オーケストレーション(code 交換・JWT 発行)を持つ。rust は DB プリミティブを
  `/api/internal/auth/*`(`require_internal_jwt` 配下)で薄く公開するだけ(token は発行しない、user + slug を返す)。
- data/internal の分離は **OIDC の `aud` claim**: `/alc-proxy`(data forward)は `aud=service URL`、
  internal call は `aud=alc-api-internal`。rust の internal middleware は `aud=alc-api-internal` を要求。
- これで confused-deputy(consumer が `/alc-proxy/api/internal/…` で internal に到達)を **aud 不一致で構造的に
  ブロック**(`/alc-proxy` は service-URL audience でしか mint しないため)。GCP 公式の confused-deputy 対策。
- 結果: rust から `JWT_SECRET` も撤去可能(user JWT も internal-JWT も検証しなくなる)。
- 移行中は `require_internal_jwt`(HS256 internal-JWT)を温存(非破壊)、lockdown 時に OIDC custom-audience
  検証へ一括 cutover。
- Phase: 1 rust internal endpoints / 2-3 auth-worker engine(LINE WORKS / LINE)/ 4 consumer repoint /
  5 rust 公開 auth 撤去 / 6 lockdown cutover(`--add-custom-audiences=alc-api-internal` + `allUsers` 削除)。

## Rejected alternatives

- **案A(internal-JWT を `X-Internal-Token` 別ヘッダへ)** — OIDC + internal-JWT の二段防御。動くが
  トークン2枚・rust が `JWT_SECRET` を保持し続ける。custom audiences で同等の分離が OIDC 一枚で実現でき
  シンプルなので不採用。
- **auth-worker に直接 DB(Supabase)接続を持たせる** — DB owner が分裂。internal-JWT/OIDC 経由で rust の
  data endpoint を叩く方が DB 所有を rust に一本化できる。
- **`/alc-proxy` の path-denylist だけで internal 到達を防ぐ** — custom audience の方が「トークンの中身」で
  弾けて堅い(belt-and-suspenders としては併用可)。
