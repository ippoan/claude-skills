---
name: gh-actions-phantom-permission
description: GitHub Actions の "phantom 0-job failure" run (Actions タブが毎 push 赤くなる、run name が `.github/workflows/<file>.yml` の file path で workflow `name:` field じゃない、jobs 配列が空、duration 0s) の root cause 特定 + fix 手順。`administration:write` のような **`GITHUB_TOKEN` permission scope に存在しない** scope を `permissions:` block に declared している事が原因のケース。actionlint v1.7.12 の `unknown permission scope` warning を `-ignore` flag で suppress していると見落としやすい。actions/runner#4001 (workflow_dispatch + push event 取り違え) とは別現象。トリガー:「phantom failure」「0-job failure」「Actions タブが毎回赤くなる」「branch-protection.yml が毎 PR push で fail」「administration permission」「GITHUB_TOKEN permission scope」「unknown permission scope」「workflow_call only phantom」「registration failure」「empty jobs array」「actions/runner#4001 と思ったら違った」等。
---

# gh-actions-phantom-permission

GitHub Actions が毎 push で `0 jobs / 0s duration / failure` の **phantom run** を Actions タブに残す症状の原因特定 + fix。

## 一次診断 (60 秒)

| 観察 | 示唆 |
|---|---|
| run name が `.github/workflows/<file>.yml` (= file path) で workflow の `name:` field が出ない | workflow が parse すらされず registration-stage で fail している |
| `jobs` 配列が空 (`list_workflow_run_jobs` が `[]`) | 同上 |
| **同 push に対して** ある file は phantom emit、他の workflow_call-only file は emit せず | file content の特定要素 (permissions / on: 等) が原因 |
| 関連 file の modify 有無に関わらず毎 push で発生 (empty commit でも出る) | registration-stage の毎 push validation が trigger |

→ 該当 file の `permissions:` block を確認:

```bash
grep -A 5 '^permissions:\|  permissions:' .github/workflows/<file>.yml
```

declared scope に **下記 14 公式 scope 以外** のものがあれば bingo。

## `GITHUB_TOKEN` 公式 permission scope (14 個)

```
actions / attestations / checks / contents / deployments / discussions /
id-token / issues / models / packages / pages / pull-requests /
repository-projects / security-events / statuses
```

出典: <https://docs.github.com/en/actions/writing-workflows/choosing-what-your-workflow-does/controlling-permissions-for-github_token>

### よくある誤記

| 書きがち | 実は無効 | 真の出自 |
|---|---|---|
| `administration: write` | ✗ `GITHUB_TOKEN` には mint 不可 | fine-grained PAT の "Administration" repository permission (Branches Protection API が要求する側) |
| `admin: write` | ✗ そんな scope は存在しない | 略記したつもりで invalid |
| `branches: write` | ✗ | `contents:` で代用、または PAT |

`Administration` という名前は fine-grained PAT 側にだけ存在 → 「workflow の `permissions:` に書ける」と勘違いしやすい罠。

## 根本原因

GitHub の trigger evaluator は `permissions:` block を parse 通すが、scope 認可で fail。fail-fast せずに **0-job failure record として workflow run history に残す**。
parse が途中で止まるため run name に workflow の `name:` field ではなく file path が surface する。

`actionlint` v1.7.12+ は `unknown permission scope` warning でこれを正しく flag するが、 `-ignore 'unknown permission scope "administration"'` のような suppression を入れていると linter が本物の bug を指していたのに skip しているという mis-direction が発生する (実例: ippoan/ci-workflows#23)。

## 別現象との切り分け

[actions/runner#4001](https://github.com/actions/runner/issues/4001): **`workflow_dispatch`-only** workflow が push event に誤 match して 0-job failure を emit する別 bug。`on:` block に `workflow_dispatch:` がある場合だけ。本 skill の症状とは独立で、両方乗ると 2 重に phantom emit する。

| 症状 | actions/runner#4001 | 本 skill (invalid scope) |
|---|---|---|
| `workflow_dispatch` を drop すると治る | ✓ | ✗ |
| invalid scope を消すと治る | ✗ | ✓ |
| 該当 file を modify した push でだけ出る | ✓ (typically) | ✗ (empty commit でも出る) |
| run name が file path | ✓ | ✓ |

## Fix: PAT secret + scope rewrite

invalid scope を 完全に消し、必要な権限を **fine-grained PAT (or GitHub App installation token)** から env 経由で渡す。

### Before

```yaml
permissions:
  contents: read
  administration: write    # ← invalid GITHUB_TOKEN scope
jobs:
  apply:
    permissions:
      contents: read
      administration: write
    steps:
      - env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

### After

```yaml
on:
  workflow_call:
    secrets:
      ADMIN_PAT:                       # 既存 PAT を再利用するなら TAG_RELEASE_PAT 等
        description: |
          Fine-grained PAT with "Administration: write" repository permission.
        required: true
permissions:                            # 削除でも可
  contents: read
jobs:
  apply:
    permissions:
      contents: read                    # administration: write は宣言しない
    steps:
      - env:
          GH_TOKEN: ${{ secrets.ADMIN_PAT }}
```

caller 側も `secrets: { ADMIN_PAT: ${{ secrets.ADMIN_PAT }} }` で受け渡し。

### PAT 既存資産の再利用

ippoan org では `TAG_RELEASE_PAT` (`tag-release.yml` 用) が既に各 repo に配布済み。新規 secret 配布コストを避けるなら、`TAG_RELEASE_PAT` の fine-grained permission に "Administration: write" を追加で済ませる方が早い。

### GitHub App token 案 (より堅牢)

PAT 配布より長期堅牢にしたい場合は org 内 GitHub App (例 `ippoan-ci-bot`) を作成し、各 repo に install 後、workflow で:

```yaml
- uses: actions/create-github-app-token@v1
  id: app-token
  with:
    app-id: ${{ secrets.CI_BOT_APP_ID }}
    private-key: ${{ secrets.CI_BOT_PRIVATE_KEY }}
- env:
    GH_TOKEN: ${{ steps.app-token.outputs.token }}
```

App 側で "Administration: write" を付与しておけば、PAT rotation 不要。

## Follow-up: 関連 cleanup

invalid scope の使用箇所が repo 内に複数ある (`grep -rln '<invalid-scope>' .github/workflows/`) ことが多い。一括 fix を推奨。

`actionlint` の suppression flag (`-ignore 'unknown permission scope "<scope>"'`) は invalid scope を全消去後に削除する。残しておくと別 invalid scope を入れた時に再度 mis-direction する。

## 検証手順

fix の push 後に **empty commit** を push し、Actions タブで該当 file の 0-job failure run が **増えていない** ことを確認:

```bash
git commit --allow-empty -m "test: verify phantom suppressed"
git push
gh run list -L 5 -b <branch-name>
```

empty commit で新 phantom run が出なければ fix 成功。出る場合は他 file にも invalid scope が残っている可能性。

## 実例: ippoan/ci-workflows#23

`branch-protection.yml` (workflow_call-only reusable) が毎 PR push で `.github/workflows/branch-protection.yml` 0-job failure を残す症状。

- PR #14 で `workflow_dispatch` 追加 → 悪化 (actions/runner#4001 が重なった)
- PR #24 で `workflow_dispatch` drop → 改善せず (残り半分の原因 `administration:` が残存)
- PR #25 で `administration:` 撤去 + `TAG_RELEASE_PAT` 経由 → 解決

詳細は [#23 thread](https://github.com/ippoan/ci-workflows/issues/23) と [#25](https://github.com/ippoan/ci-workflows/pull/25) を参照。

## 教訓

- `actionlint` の `-ignore` flag を入れる前に **本当に false positive か** を確認する。invalid scope のような実 bug を suppress すると mis-direction が長期化する。
- 「公式 docs が正で linter が古い」と決めつけない。逆 (linter が正で自分の認識が古い) の方が多い。
- phantom failure に出会ったら、まず `permissions:` block の **全 scope** を 14 個リストと照合する。grep 一発。
