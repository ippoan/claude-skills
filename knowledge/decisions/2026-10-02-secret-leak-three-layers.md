---
title: secret 流出対策を pre-push / push protection / PR gate の 3 層にした
date: 2026-10-02
status: active
tags: [secret-scanning, gitleaks, push-protection, pre-push, code-security-configuration]
repo: ci-workflows
---

## Summary

PR の gitleaks gate は push の後にしか走らず、public repo では公開済みになる。
公開前に止める層として pre-push の gitleaks と GitHub の push protection (org の
security configuration) を足した。configuration を API で作るときの罠も記録する。

## Context

- ippoan/ci-workflows#191 で `auto-merge.yml` に `Secret Scan (gitleaks)` が入り、PR で
  足された commit 範囲に検出があれば merge を queue しなくなった。
- ただし走るのは push の後。public repo は push した時点で公開されるので、この gate は
  「merge を止める」だけで流出は止めない。draft PR は検査対象外。
- 調べた時点で、両 org の全 repo で GitHub の secret scanning と push protection が
  `disabled` だった。作業マシンにも gitleaks は入っていなかった。
- きっかけは `gh secure` (GitHubSecurityLab/gh-secure) の調査。public repo の
  セキュリティ設定 5 種を `gh api` でまとめて有効化する gh 拡張。

## Decision

3 層にした。層ごとに止める時点と拾うものが違うので、どれも他の代わりにならない。

| 層 | 止める時点 | 拾うもの | 範囲 |
|---|---|---|---|
| pre-push の gitleaks | push の前 | provider 形式 + `KEY=平文` 型 | 配線したマシンだけ |
| GitHub push protection | push の受信時 | provider 形式のトークンだけ | 両 org の public repo 全部 |
| PR の gitleaks gate | push の後 | provider 形式 + `KEY=平文` 型 | 共有 CI を呼ぶ repo |

- **pre-push**: `ci-workflows/scripts/pre-push-gitleaks.sh` (ippoan/ci-workflows#192)。
  設定は PR gate と同じ `config/gitleaks.toml`。global の `core.hooksPath` 配下の
  `pre-push` から呼ぶ。検出とスキャン失敗は push を拒否、gitleaks 未導入は警告して通す。
- **push protection**: 両 org に security configuration `secret-push-protection` を作り、
  public repo に適用して新規 public repo の既定にした。secret scanning と push
  protection 以外の項目には触れない。

## 調査結果

### security configuration を API で作るときの組み合わせ制約

`POST /orgs/{org}/code-security/configurations` は項目の組み合わせで弾く。
エラー文言は plan で違った (Team plan の org と Free plan の org で別の文言)。

- `secret_scanning: enabled` にするなら `advanced_security` を `secret_protection` か
  `enabled` にする。`disabled` のままだと 400。
- `advanced_security: secret_protection` (Code Security は無効) のときは、次の 3 項目を
  `disabled` と明示する。`not_set` だと 422。
  - `code_scanning_default_setup`
  - `code_scanning_delegated_alert_dismissal`
  - `dependabot_delegated_alert_dismissal`
- `advanced_security: enabled` なら `code_scanning_default_setup: not_set` で通る。
- 省略した項目は `not_set` にならず既定値 (多くは `disabled`) が入る。既存の設定を
  動かしたくない項目は `not_set` を明示する。
- 適用は `POST .../{id}/attach` に `scope=public`、新規 repo の既定は
  `PUT .../{id}/defaults` に `default_for_new_repos=public`。
- 必要な scope は `admin:org`。`read:org` では GET は通るが POST が 403。

### 権限まわり

- `gh auth refresh -h github.com -s admin:org` は端末なしでも動く。stdin を閉じて
  バックグラウンドで走らせると one-time code を出力して承認を待つ。承認そのもの
  (コード入力と Authorize) は人が行う。
- Claude Code の auto mode の分類器は、次の 3 つを拒否した。回避せず、コマンドを
  人に渡して打ってもらった。
  - repo ごとの `security_and_analysis` の一括 PATCH
  - device flow の画面のブラウザ操作
  - security configuration の作成 POST

### gh-secure を使わなかった理由

- `branch-protection` は「承認 1 件必須」の旧式 branch protection を入れる。PR 作成で
  auto-merge する運用の repo では承認待ちで止まる。
- active な ruleset があると `--yes` でも y/n を聞くので無人実行できない。
- `status` は API のエラーを捨てるので、権限不足 (403/404) と未設定の区別がつかない。
- repo 単位のツールで、org の既定 (新規 repo への自動適用) は設定できない。

### pre-push スクリプトの範囲の取り方

- 既存 branch は `remote_sha..local_sha`。
- 新規 branch と、remote の先端を手元に持たない場合は `local_sha --not --remotes`
  (どの remote にもまだ無い commit)。
- 値を消す commit を上に積んでも、範囲内の履歴に残っていれば検出する。push 前なら
  commit を作り直せば済む。

## Rejected alternatives

- **既存の "GitHub recommended" configuration を適用** — CodeQL の default setup と
  Dependabot も一緒に有効になる。今回入れたいのは secret scanning だけ。
- **private repo にも適用** — Team plan では Secret Protection が committer 単位で
  課金される。private は pre-push の gitleaks で受ける。
- **repo ごとに PATCH で有効化** — 既存 repo にしか効かず、新規 repo の既定にならない。
- **PR gate だけで済ませる** — push の後なので、public repo では公開を止められない。
- **pre-push を fail-open (スキャン失敗でも通す)** — 壊れたまま誰も気づかない。
  未導入だけを警告で通し、導入済みで失敗した場合は push を止める。
