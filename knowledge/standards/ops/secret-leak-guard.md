---
title: secret 流出は pre-push / push protection / PR gate の 3 層で止める
category: ops
status: recommended
recommended: pre-push の gitleaks + org の security configuration (secret scanning + push protection) + auto-merge.yml の gitleaks gate
decision: 2026-10-02-secret-leak-three-layers
---

3 層とも有効にしておく。止める時点と拾うものが層ごとに違う。

| 層 | 実体 | 拾うもの |
|---|---|---|
| pre-push (公開前) | `ippoan/ci-workflows` の `scripts/pre-push-gitleaks.sh` | provider 形式 + `KEY=平文` 型 |
| push の受信時 | org の security configuration `secret-push-protection` | provider 形式のトークンだけ |
| PR (公開後) | `auto-merge.yml` の `Secret Scan (gitleaks)` | provider 形式 + `KEY=平文` 型 |

- gitleaks の設定は `ippoan/ci-workflows` の `config/gitleaks.toml` が唯一。pre-push と
  PR gate が同じものを読む。repo 側の `.gitleaks.toml` は読まれない。
- 誤検知の除外は該当行の `gitleaks:allow` か、repo 直下の `.gitleaksignore` に
  fingerprint を 1 行ずつ。
- 新しいマシンでは gitleaks を workflow の `GITLEAKS_VERSION` と同じ版で入れ、global の
  `core.hooksPath` 配下の `pre-push` に 1 行足す (手順は ci-workflows の README)。
  未導入のマシンでは `KEY=平文` 型が公開前に止まらない。
- security configuration は public repo だけに適用する。private に適用すると
  Secret Protection が課金される。
- push が GitHub 側で拒否されたら push protection を疑う。
- 検出が本物で push 済みなら、履歴の修正より先にその認証情報を失効・変更する。
  public repo では commit を消しても漏れた事実は消えない。
- draft PR は PR gate の検査対象外。
- org の configuration を変えるのは人が打つ (`admin:org` scope が要る)。API の
  組み合わせ制約は decision を参照。
