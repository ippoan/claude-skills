---
name: auto-merge-401
description: >
  ippoan/ci-workflows の `auto-merge.yml` reusable workflow が
  cross-repo (frontend-ci.yml caller 経由) から呼ばれた際に
  `gh pr merge --auto` で `non-200 OK status code: 401 Unauthorized
  Bad credentials` を返す既知の intermittent 問題と、再発時の対処手順。
  同じ token で `gh pr view` (read) は通るが `enablePullRequestAutoMerge`
  mutation (write) で 401 が出る。PR 自体は GitHub background auto-merge
  engine 経由で merge されるため cosmetic fail だが Actions タブが赤くなる。
  トリガー: 「auto-merge 401」「Bad credentials auto-merge」「cross-repo
  auto-merge fail」「enablePullRequestAutoMerge 401」「gh pr merge 401」
  「reusable workflow auto-merge fail」「PR merged ても Auto Merge job だけ赤」等。
---

# Auto Merge 401 (cross-repo reusable chain)

## 症状

`ippoan/ci-workflows/.github/workflows/auto-merge.yml@main` を **cross-repo**
(= caller が ci-workflows 以外、例: auth-worker / ci-dashboard) から
`frontend-ci.yml` 経由で呼んだ際、`Auto Merge` job が以下のログで fail:

```
PR #<N> mergeable: MERGEABLE
non-200 OK status code: 401 Unauthorized body: "{\n  \"message\": \"Bad credentials\",
  \"documentation_url\": \"https://docs.github.com/rest\",\n  \"status\": \"401\"\n}"
Error: Process completed with exit code 1.
```

- `gh pr view --json mergeable` (read) は 200 で返ってる (= token 自体は valid)
- 次の `gh pr merge --auto --squash` (write mutation) で 401

## 影響

- **cosmetic only**: PR 自体は GitHub の background auto-merge engine 経由で
  merge される (= 過去に 1 度でも auto-merge enable できた PR は GitHub 側に
  queue されてて、required check 通った瞬間 GitHub が merge を実行)
- ただし Actions タブで run が赤くなる、status check の見た目が悪い

## 既知の条件

| 条件 | 401 出る? |
|---|---|
| ci-workflows 自身の PR (same-repo) | No |
| `frontend-ci.yml` caller (auth-worker / ci-dashboard) | **時々 Yes** |
| 同じ run の `gh pr view` | No (200 OK) |
| 次の `gh pr merge --auto` | 401 |

intermittent な印象。同じ PR でも rerun で通ったり通らなかったり (2026-05-23
セッションで観測: 1st run success → branch update 後 2nd run fail → 3rd
rerun success、code 変更なし)。

## 原因仮説 (確証なし)

1. **SAML SSO 認可の eventual consistency**: ippoan org が SSO 有効、cross-repo
   reusable から呼ばれた installation token が org SSO authorize を伝搬する
   タイミングで mutation を弾くケース
2. **`actions: write` permission**: cli/cli#11493 で「`actions:write` 不足が
   misleading な 401 として bubble する」報告あり
3. **2026-03 GitHub change** (community#190610): auto-merge enable が全
   required check 通過後必須化。job 順序的には需要を満たすが micro-timing
   で signal propagation 遅延

## 試行済の対処と結果

### ❌ A. `actions: write` permission 追加 (ci-workflows#55)

`auto-merge.yml` の job permissions に `actions: write` を追加。

```yaml
permissions:
  contents: write
  pull-requests: write
  actions: write    # 追加
```

**結果**: reusable workflow chain の **全 caller** (test.yml レベルまで) が
`actions: write` を declare する必要があり、全 worker repo の test.yml が:

```
Error calling workflow 'ippoan/ci-workflows/.github/workflows/auto-merge.yml@main'.
The nested job 'auto-merge' is requesting 'actions: write',
but is only allowed 'actions: none'.
```

で `startup_failure` 連発 → **ci-workflows#56 で revert** 済。

教訓: reusable workflow に新 permission を要求すると caller chain 全部の
test.yml を同時更新が必要 (= 大規模 breaking change)。安易に追加しない。

### ⏳ B. `peter-evans/enable-pull-request-automerge@v3` action 切り替え (未試行)

action 内部の token 渡し方が違うため、reusable chain でも動く可能性。
公式に近い 3rd party で実績多数。

実装案:

```yaml
# auto-merge.yml (reusable)
steps:
  - uses: peter-evans/enable-pull-request-automerge@v3
    with:
      token: ${{ secrets.GITHUB_TOKEN }}
      pull-request-number: ${{ github.event.number }}
      merge-method: squash
```

### ⏳ C. tolerant exit (未試行)

`gh pr merge --auto` の exit code を握りつぶし、「既に queue 済の可能性」
notice にして job success 化:

```bash
gh pr merge "$PR" --auto --squash --repo "$REPO" || {
  echo "::notice::auto-merge enable failed (may already be queued)"
  exit 0
}
```

**注意**: 真の merge failure (= 一度も queue できてない PR) も swallow して
しまうリスク。最初の 1 回だけ enable できれば background engine が処理
するので、initial queue が成功した後の rerun 失敗は無害。

### ⏳ D. 専用 granular PAT (未試行)

ippoan org の専用 service account (e.g. `ippoan-automerge-bot`) で fine-
grained PAT (Contents r/w + PR r/w) を発行。caller 別に渡す。

**懸念**: PAT 共有で rate limit 枯渇 (ci-workflows#49 で当時の `TAG_RELEASE_PAT`
で発生した user PAT GraphQL 5000pt/h 枯渇) を再発させない設計が必要。

## 再発時の優先対処順

1. **まず rerun**: intermittent なので 1-2 回 rerun で通る可能性 (実際に
   2026-05-23 で観測)
2. **PR が merge されてるか確認**: GitHub 側の background auto-merge engine が
   裏で merge してることが多い (= 何もしなくて OK の cosmetic fail)
3. **頻発するなら B (peter-evans action) を試す**: 別 PR で `auto-merge.yml`
   を action 化、cross-repo PR で検証
4. **B も駄目なら C (tolerant exit)**: 確実に noise を消す、本物の failure を
   見落とすリスクと trade-off

## 関連リソース

- ci-workflows#49: TAG_RELEASE_PAT 撤去 → github.token 統一 (この後 401 発生)
- ci-workflows#55 / #56: actions:write 試行 → revert (breaking change)
- ci-dashboard#125 / #126: 再現ケース (どちらも background engine で merged)
- [cli/cli#11493](https://github.com/cli/cli/issues/11493) — misleading 401 報告
- [community#190610](https://github.com/orgs/community/discussions/190610) —
  2026-03 auto-merge 挙動変更
- [peter-evans/enable-pull-request-automerge](https://github.com/peter-evans/enable-pull-request-automerge)
