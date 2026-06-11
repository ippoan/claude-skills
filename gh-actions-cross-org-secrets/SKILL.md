---
name: gh-actions-cross-org-secrets
description: >
  GitHub Actions の cross-org reusable workflow で secret が消える問題の確定知識
  (2026-06-11 ippoan/ci-workflows#125〜#127 で実測)。`secrets: inherit` の org
  境界判定は「reusable の所在 org」ではなく **workflow run の repo org 基準**で、
  ohishi-exp の run では caller が明示渡しして中間 reusable が受領済みの secret
  すら次の hop の inherit で全部落ちる。修正は「全 hop 明示転送」。診断用の
  secret 可視性 probe job と「re-run は reusable sha を pin する」罠も含む。
  トリガー:「missing GitHub App credentials」「CI_APP_ID 空」「cross-org secret」
  「secrets: inherit 効かない」「ohishi-exp auto-merge fail」「nested reusable
  secret 落ちる」「inherit 罠」「secret probe」「org secret 届かない」等。
---

# GitHub Actions cross-org reusable の secret 転送

## 確定事実 (実測、2026-06-11)

ohishi-exp/nuxt-ichibanboshi#36 の probe で確定させた挙動:

| 観測点 | 結果 |
|---|---|
| caller (ohishi-exp repo) の job で `secrets.CI_APP_ID != ''` | **true** (org secret は存在・可視) |
| caller → frontend-ci (ippoan) へ **明示渡し** + frontend-ci は宣言済み | (受領は成立しているはず) |
| frontend-ci → auto-merge.yml への nested `secrets: inherit` 後の env | **空** |

→ **`secrets: inherit` の境界判定は workflow run の repo org 基準**。
ippoan caller の run では inherit が通り、ohishi-exp caller の run では
チェーンのどこに inherit があってもそこで全 secret が落ちる
(明示受領済みでも転送されない)。

## 修正パターン (ci-workflows#126 + #127)

cross-org caller を通したい reusable チェーンは **全 hop 明示転送**:

1. 各 reusable の `on.workflow_call.secrets` に対象 secret を **宣言**
   (未宣言だと caller は明示渡しすらできない — #126)
2. nested 呼び出しの `secrets: inherit` を **明示転送に置換** (#127):

   ```yaml
   uses: ippoan/ci-workflows/.github/workflows/auto-merge.yml@main
   secrets:
     CI_APP_ID: ${{ secrets.CI_APP_ID }}
     CI_APP_PRIVATE_KEY: ${{ secrets.CI_APP_PRIVATE_KEY }}
     TAG_RELEASE_PAT: ${{ secrets.TAG_RELEASE_PAT }}
   ```

   同 org caller (hop1 inherit) でも reusable の secrets context に org secret が
   乗るため、同じ式で解決する = regression なし。
3. cross-org caller 側は named secret を明示渡し:

   ```yaml
   secrets:
     CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
     CI_APP_ID: ${{ secrets.CI_APP_ID }}
     CI_APP_PRIVATE_KEY: ${{ secrets.CI_APP_PRIVATE_KEY }}
   ```

## 診断: secret 可視性 probe (値を出さない)

「secret が無いのか、途中で落ちているのか」を切り分ける。caller repo に
一時 job を足した draft PR を作り、確認後 close + commit revert:

```yaml
  secret-probe:
    runs-on: ubuntu-latest
    steps:
      - env:
          HAS_APP_ID: ${{ secrets.CI_APP_ID != '' }}
        run: echo "CI_APP_ID present: $HAS_APP_ID"
```

- caller で present + nested で空 → inherit hop が犯人 (本 skill の修正)
- caller で空 → org secret の存在 / Repository access / 名前を疑う

## 関連の罠

- **re-run は run 作成時の reusable sha を pin する** — reusable 側を直しても
  `Re-run failed jobs` では旧 sha のまま。検証は **空 commit push で fresh run**
  を起こすこと。
- 2026-05-28 の ci-workflows#80 で auto-merge.yml の github.token fallback が
  撤去された。それ以前の cross-org caller は fallback で「動いているように
  見えていた」(bot actor / rate limit の副作用つき)。「前は動いてた」の正体は
  だいたいこれ。
- 歴史: ippoan/ci-workflows#125 (起票) → #126 (宣言追加、不足) → #127 (明示転送、
  確定修正)。caller 配線例: ohishi-exp/{nuxt-ichibanboshi#35, nuxt_dtako_logs#13,
  nuxt-dtako-admin#46}。
