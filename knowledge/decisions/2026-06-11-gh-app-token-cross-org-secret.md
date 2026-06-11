---
title: 別 org への GitHub secret 配布は per-org PAT でなく App installation token mode + named secret 明示渡し
date: 2026-06-11
status: active
tags: [ci, secrets, github-app, cross-org, auto-merge, secrets-inventory]
repo: secrets-inventory-gcp
issue: 51
---

## Summary

ohishi-exp org の repo を ippoan 標準 CI (auto-merge.yml reusable) に乗せるため、
ohishi-exp org に `CI_APP_ID` / `CI_APP_PRIVATE_KEY` を配布する必要があった。
**per-org PAT (#49) を却下し、`ippoan-ci-bot` App の installation token mode
(secrets-inventory-gcp#51) を採用**。配布は `sync_from_gcp` の `gh_org` で GCP
から行い、**caller の `secrets: inherit` はクロス org で効かないため named
secret の明示渡しが必須**という 2 点が確定事項。

## Context

- ohishi-exp/rust-ichibanboshi#4 で auto-merge を入れたが、ippoan の標準 reusable
  `auto-merge.yml@main` は App credential (`CI_APP_ID`/`CI_APP_PRIVATE_KEY`) を
  fail-loud 必須にしている。ohishi-exp org にその secret が無く動かなかった。
- 当初は self-contained job (`gh pr merge --squash`、TAG_RELEASE_PAT fallback) で
  代替したが、reusable の deploy gate / mergeable 検査が効かない劣化版だった。
- App `ippoan-ci-bot` は ippoan / ohishi-exp 両 org に install 済み。App 秘密鍵は
  GCP Secret Manager に保管済み (`CI_APP_ID` / `CI_APP_PRIVATE_KEY` /
  `CI_APP_PRIVATE_KEY_PKCS8`)。

## Decision

1. **proxy に GitHub App installation token mode を追加** (secrets-inventory-gcp#51):
   env `GH_APP_ID_SECRET_NAME` + `GH_APP_PRIVATE_KEY_SECRET_NAME` を設定すると、
   App JWT → `GET /orgs/{org}/installation` → installation token (1h、org 別 cache)
   で org secrets API を叩く。**App が install された org すべてに書ける**ので、
   org 追加 = App install だけ (新規 credential ゼロ)。鍵 PEM は PKCS#1/#8 両対応。
2. **配布は `sync_from_gcp { gh_org }`** (secrets-inventory#76/#77): GCP の既存値を
   `?gh_org=ohishi-exp` で別 org の GitHub org secret に伝播。値は proxy 内で完結し
   context/log に載らない。
3. **caller は named secret を明示渡し** (ci-workflows#121 で文書化): `secrets:
   inherit` は reusable が **同一 org/enterprise** にある時しか secret を渡さない。
   別 org caller (ohishi-exp → ippoan/ci-workflows) は空になり "missing GitHub App
   credentials" で fail する。`secrets: { CI_APP_ID: ${{ secrets.CI_APP_ID }}, ... }`
   と明示する。

## Rejected alternatives

- **per-org PAT (`GH_EXTRA_ORGS` allowlist、secrets-inventory-gcp#49)** — org ごとに
  長命 PAT を発行・保管・rotate。実装はしたが #51 で App mode を入れたため fallback
  扱いに後退 (App mode 有効時は使わない)。App 方式は credential ゼロで blast radius
  も 1h token に縮む。
- **reusable を SHA pin / ohishi-exp に複製** — org 全体が `@main` + inherit で同じ
  App 鍵を流しているので 1 repo だけ pin しても暴露は閉じない。複製は共有 reusable の
  意義を消す。秘密鍵の blast radius を本気で縮めるなら「caller 側で token を mint して
  短命 token だけ渡す」org 全体改修 (~30 repo) が必要で、これは別途判断 (未着手)。
- **self-contained auto-merge job** — reusable の deploy gate / mergeable 検査・App
  actor merge が効かない劣化版。App credential が入った時点で reusable に復帰した。

## 動作確認

ohishi-exp/rust-ichibanboshi#7 で end-to-end 実証 (sync 投入 → reusable auto-merge
→ App token mint → squash merge) が green。
