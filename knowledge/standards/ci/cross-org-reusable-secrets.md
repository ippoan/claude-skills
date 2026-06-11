---
title: 別 org の repo を ippoan 標準 CI (reusable workflow) に乗せる手順
category: ci
status: recommended
recommended: App installation token mode で secret 配布 + caller は named secret 明示渡し
decision: 2026-06-11-gh-app-token-cross-org-secret
---

`ohishi-exp/*` 等 **ippoan と別 org** の repo を `ippoan/ci-workflows` の reusable
(auto-merge.yml 等) に乗せる時の確定手順。

## 罠: `secrets: inherit` はクロス org で効かない

`secrets: inherit` は reusable が **同一 org / enterprise** にある時しか secret を
渡さない。別 org caller (ohishi-exp → ippoan/ci-workflows) が inherit を使うと
`CI_APP_ID` / `CI_APP_PRIVATE_KEY` が**空**になり `missing GitHub App credentials`
で fail する。何度も踏むので auto-merge.yml の `Require App token` step の `::error`
に caller owner 付き FIX 手順を出力済み (ci-workflows#121)。

→ 別 org caller は **named secret を明示渡し**:

```yaml
auto-merge:
  uses: ippoan/ci-workflows/.github/workflows/auto-merge.yml@main
  secrets:
    CI_APP_ID: ${{ secrets.CI_APP_ID }}
    CI_APP_PRIVATE_KEY: ${{ secrets.CI_APP_PRIVATE_KEY }}
```

同 org (ippoan) caller は従来どおり `secrets: inherit` で良い。

## 新 org オンボード 3 step

1. **App を org に install + permission**: `ippoan-ci-bot` App を対象 org に install
   し、Organization permissions → **Secrets: Read and write** を付与 → 各 org が
   permission update を承認。
2. **secret を sync** (= per-org PAT は不要): GCP の既存 App credential を
   `sync_from_gcp` の `gh_org` で対象 org に伝播。proxy が App installation token
   mode で書くので org 追加 = App install だけ:
   ```
   sync_from_gcp { name: 'CI_APP_ID', targets: ['gh'], gh_org: '<org>' }
   sync_from_gcp { name: 'CI_APP_PRIVATE_KEY_PKCS8', targets: ['gh'],
                   gh_org: '<org>', gh_name: 'CI_APP_PRIVATE_KEY' }
   ```
   前提: secrets-inventory-gcp Cloud Run に `GH_APP_ID_SECRET_NAME` /
   `GH_APP_PRIVATE_KEY_SECRET_NAME` env + runtime SA への per-secret accessor grant。
3. **caller を named secret 明示渡しで配線** (上記)。

## 関連

- proxy 実装: secrets-inventory-gcp#51 (App mode) / #49 (per-org PAT、fallback)
- worker tool: secrets-inventory#76/#77 (`sync_from_gcp` の `gh_org`)
- 実証: ohishi-exp/rust-ichibanboshi#7
