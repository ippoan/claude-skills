---
name: auto-merge-deploy-race
description: >
  CI 内蔵の auto-merge job が deploy job (staging cutover) の完了を待たずに
  merge → branch 削除 → 走行中の cutover が cancel され、**deploy 失敗が
  無音化する** race の解説と対処手順。rollback で旧 revision が traffic を
  維持するため service は正常に見え、「PR は merged なのに変更が staging に
  反映されていない」状態になる (2026-06-10 rust-alc-api#391 の enforce が
  これで 2 回未適用になった実害あり)。新 secret の secretKeyRef 追加と
  組み合わさると per-secret accessor grant 漏れも同時に隠れる。
  トリガー: 「merged なのに staging に反映されない」「deploy が cancelled」
  「cutover cancel」「auto-merge race」「enforce 効いてない」「merge したのに
  旧挙動」「Deploy job が merge で消えた」「run failure なのに merged」
  「staging 反映確認」「draft で deploy 完走待ち」等。
---

# auto-merge × deploy の race — merge が cutover を殺し、失敗が無音化する

## 症状

- PR は **merged**、CI run の conclusion は **failure** (または Deploy 系 job が `cancelled`)
- staging を実測すると**変更前の挙動のまま** (例: 新 env が効いていない)
- service 自体は正常 (rollback step が旧 revision に 100% traffic を戻すため、health は 200)

## 機構

repo 内蔵の `auto-merge` job (例: rust-alc-api `ci.yml`) は

```yaml
needs: [check, coverage-check, build-image]   # deploy が無い
```

で merge を queue する。build が速いと **staging cutover (`gcloud run services
replace`) の最中に merge が成立 → head branch 削除 → cutover job が cancel**。
cancel された deploy は webhook も飛ばず、PR は merged 表示なので誰も気づかない。

`needs` に `deploy` を足さない理由: staging 環境障害 (docker.io flaky 等) で
全 PR が merge 不能になる SPOF 化とのトレードオフ (未解決の設計判断)。

## 実害事例 (2026-06-10, ippoan/rust-alc-api#391)

`STAGING_API_KEY` (export/import の opt-in 認証) を render.sh に足した PR #403 が
この race で cutover cancel → **enforce が無音で未適用**。さらに再 deploy 時に
新 secret の **per-secret accessor grant 漏れ** (`Permission denied on secret`)
も発覚 — race が無ければ初回 deploy で即検知できていたエラー。教訓:
**「merged = 反映済み」と思い込まず、staging への実測を完了条件にする**。

## 検知 (merged 後に必ずやる)

1. **staging 実測** — 変更が観測できる request を 1 本 (例: 認証追加なら
   `curl -o /dev/null -w '%{http_code}'` で 401 を期待)
2. PR の checks で `Deploy / Deploy <svc>` が **success** か (cancelled/missing なら黒)
3. branch CI run の conclusion が failure なら `get_job_logs failed_only=true` —
   ただし **cancelled job は "failed jobs" に出ない** (failed_jobs:0 でも
   total_jobs との差分が cancel を示唆する)

## 復旧手順

deploy workflow が `workflow_call` only (dispatch 不可) の場合、再 deploy には
PR が要る:

1. **draft PR** を出す (no-op に近い diff で可 — render.sh へのコメント追記等)。
   draft の間は auto-merge が効かないので cutover が最後まで完走する
2. cutover fail なら原因対処 (新 secret なら runtime SA へ per-secret grant:
   `gcloud secrets add-iam-policy-binding <NAME> --project=cloudsql-sv
   --member="serviceAccount:747065218280-compute@developer.gserviceaccount.com"
   --role="roles/secretmanager.secretAccessor"`) → run **完了後**に
   `rerun_failed_jobs` (実行中は 403 "already running")
3. staging 実測で新挙動を確認 **してから** ready 化 → merge

### 罠: draft 解除の rate limit

`mcp__github__update_pull_request {draft:false}` は user PAT bucket を使う。
`API rate limit already exceeded` の時は relay (App token) に draft 解除
ツールが無く、draft のままの merge は 405 → **user に GitHub UI の
"Ready for review" を 1 クリックしてもらうのが最速**。

## 予防

- `cloudrun/` / `deploy.yml` / `migrations/` を触る PR は**最初から draft** で出す
- 「インフラ反映を伴う PR の完了条件は staging 実測」をセッションの定義に入れる
- 恒久対策 (deploy 結果の可視化 / needs 追加のトレードオフ判断) は repo 側の
  設計課題として残っている
