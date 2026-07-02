---
name: durable-object-worker
description: >
  Cloudflare Durable Object (DO) を ippoan/ohishi スタック (Nuxt/Worker + frontend-ci
  + Release Wave の no-traffic versions upload 運用) で「作る／既存 worker から切り出す」
  ための設計判断と手順。**新規**の DO migration を no-traffic `versions upload` に
  含めると error 10211 になる (既に適用済みの migration しか持たない worker は
  no-traffic のままで良い、`ippoan/auth-worker` が実例) ため、これから新規に DO を
  追加する時は **DO を別 worker に分離し app から service binding で叩く**のを標準にする。
  class 削除の catch-22 (10061/10064)・bespoke deploy workflow・coverage 100% gate・
  deploy ordering・WS 検証までを 1 枚にまとめる。
  reference 実装: ippoan/nuxt-items + workers/items-sync (#290)。
  トリガー:「Durable Object 作る」「DO 追加」「DO worker」「new_sqlite_classes」
  「error 10211」「10061」「10064」「versions upload できない」「migration で deploy 不可」
  「DO を no-traffic で出したい」「service binding で DO」「DO 100% になる」
  「delete-class できない」「WebSocket worker」「DO 分離」等。
---

# Cloudflare Durable Object worker の作り方 (no-traffic release 両立)

ippoan/ohishi の Worker は frontend-ci + Release Wave で **no-traffic
`wrangler versions upload`** (= deploy では traffic を動かさず、flip で明示的に
100% 化) を標準とする。**「新規」DO の追加はこの運用と相性が悪い** (既存 DO を
持つ worker がそのまま no-traffic を続けること自体は問題ない) ので、最初に
下の鉄則を押さえる。

## 鉄則: 「新規」DO migration を versions upload に含めると error 10211

> Cloudflare 公式: "Durable Object migrations are atomic operations and cannot be
> gradually deployed... new Worker versions with new migrations cannot be uploaded."
> **未適用の** migration は `wrangler deploy` (= 即 100% traffic) でしか適用できない。
> **no-traffic / 0% / gradual で新規 migration を当てる wrangler 引数は存在しない。**

**誤解しやすい点**: 10211 は「worker が `[[migrations]]` を持っている」ことでは
発火しない。発火するのは **その version upload が、まだ適用されていない
migration tag を新たに含む時**だけ。つまり:

- `[[migrations]]` の class が **1 つも適用されていない** worker に、
  new_sqlite_classes 入りの version を `versions upload` → **10211 で失敗**
- **既に適用済み** (= 過去に一度 `wrangler deploy` で通した) migration しか
  持たない worker を、その後 `versions upload` (no-traffic) で release
  → **成功する** (適用対象の新規 migration が無いため)。
  実例: `ippoan/auth-worker` は `LineworksWebhookDO` / `McpSession` /
  `IssueRoomDO` の DO + migration を **app 本体**に持ったまま、
  `release_no_traffic: true` (default) の `wrangler versions upload` で
  問題なく release され続けている (10211 を踏んでいない)。

→ 実務上の結論: **「今回新しく DO を追加する」変更を no-traffic release の
worker に直接混ぜると、その 1 回の deploy で 10211 を踏む。** 一度別ルート
(後述の bespoke `wrangler deploy` か、その回だけ `release_no_traffic: false`
に切り替える一時的な real deploy) で migration を適用してしまえば、
以降その worker に新しい DO/migration を追加しない限り no-traffic release を
続けられる。「DO を持つ worker は永久に no-traffic 化できない」わけではない。

## 定石 (推奨、必須ではない): DO を別 worker に分離し、app からは service binding で叩く

上の鉄則の通り「1 回だけ real deploy を挟めば app に DO を直接置いても no-traffic
運用は続けられる」が、それでも **新規 DO は別 worker に分離するのを標準にする**。
理由は 10211 回避そのものではなく:
- 新しい DO/migration を追加する度に「今回だけ real deploy」の一時運用を
  手動で管理するのは事故りやすい (`release_no_traffic: false` の戻し忘れ等)
- class 削除時の catch-22 (10061/10064、下記) を踏まない
- `nuxt-items` (→ `workers/items-sync`) が実際にこの形で運用中 (2026-06、#290)

`auth-worker` のように **既に long-standing な DO を持つ既存 worker** は
無理に分離し直す必要はない (現に no-traffic のまま動いている)。分離が効くのは
**「これから新規に追加する」DO**に対して。

```
[app worker]  (no-traffic versions upload 維持、migration 0)
  main = ./worker/index.ts
  [[services]] binding="X" service="<app>-sync"      ← service binding
  env.X.fetch(request) で /ws/* 等を転送するだけ
        │ worker→worker fetch (WebSocket upgrade も proxy 可)
        ▼
[<app>-sync worker]  (DO 本体。bespoke `wrangler deploy`)
  export { MyDO } from "./my-do"
  [[durable_objects.bindings]] name="X" class_name="MyDO"   ← 内部 DO binding
  [[migrations]] tag="v1" new_sqlite_classes=["MyDO"]
  default fetch: idFromName(...).get(id).fetch(request) で DO へ routing
```

### なぜ service binding か (external DO binding `script_name` ではなく)

app から別 worker の DO を使う方法は 2 つあるが **service binding を選ぶ**:

| | external DO binding (`script_name`) | **service binding (推奨)** |
|---|---|---|
| 参照 | `class_name="MyDO"` を参照 | worker 名のみ。class 参照なし |
| class 削除 | class_name 参照が delete-class を阻む (**10061**) | 衝突しない |
| WS | proxy 可 | proxy 可 (101 + DO 到達を実証済み) |
| routing | app が `idFromName().get().fetch()` | DO worker の default fetch 側で routing |

external DO binding は、後で app から DO を外す時に Cloudflare の
delete-class catch-22 (下記) を必ず踏む。service binding なら class_name を
一切参照しないので app は「DO を全く知らない」状態になり、migration も 0 にできる。

## Cloudflare DO エラー早見表

| code | 意味 | 対処 |
|---|---|---|
| **10211** | migration を含む version は versions upload 不可 | DO を別 worker へ。app は migration を持たない |
| **10061** (script_name) | `Cannot create binding for class in script '<x>' that does not exist` | **DO worker を先に deploy** してから app を deploy (ordering) |
| **10061** (delete) | `Cannot apply --delete-class ... without also removing the binding that references it` | その class を参照する binding を先に外す (service binding 化 or 2-step) |
| **10064** | `New version does not export class '<C>' which is depended on by existing Durable Objects` | その worker に旧 class 登録 + 既存 DO が残存。`deleted_classes` migration が要る (下記 catch-22) |

## class 削除の catch-22 と脱出法

ある worker が過去に DO class を定義 (`new_sqlite_classes` 適用済み) していて、
今その class を外したい時:
- class を export しないと **10064** (既存 DO が class に依存)
- `deleted_classes` で消そうとすると **10061** (class を参照する binding が残っている)
- binding を外すと、class 未 export で再び **10064**

→ CF 公式の正攻法は **2-step deploy** (binding を外し class は export 維持 →
別 deploy で deleted_classes)。だが migration を含むので `wrangler deploy`
(= 100%) が要る。**最も簡単な脱出は環境次第:**

- **staging 等 disposable env**: その worker を **一度削除して作り直す** のが最速。
  `npx wrangler delete --env staging` → 通常 deploy で fresh 再作成 (custom domain
  route も再付与)。旧 class 登録ごと消えるので migration 0 で済む。DO データは
  消えるが、別 worker 切替で元々 fresh namespace になるため実質損失なし。
- **prod がそもそも DO 未デプロイ**: prod は versions upload のみで来た = migration
  未適用 = class 登録なし。**migration 不要・100% も不要**でそのまま no-traffic 反映。

## DO worker の bespoke deploy workflow

frontend-ci は release script の `wrangler deploy` を **`wrangler versions upload`
へ global 置換**する (`${CMD//wrangler deploy/wrangler versions upload}`) ので、
**DO worker (migration あり) に frontend-ci を使うと壊れる**。専用 workflow を書く:

```yaml
# .github/workflows/<app>-sync-deploy.yml
on:
  push: { branches: [main], tags: ['v*'], paths: ['workers/<app>-sync/**', '.github/workflows/<app>-sync-deploy.yml'] }
  pull_request: { paths: ['workers/<app>-sync/**', '.github/workflows/<app>-sync-deploy.yml'] }  # PR で gate
  workflow_dispatch:
permissions: { contents: read }
jobs:
  deploy:
    runs-on: ubuntu-latest
    defaults: { run: { working-directory: workers/<app>-sync } }
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }       # wrangler v4 は Node 22+ 必須
      - run: npm ci
      - run: npx tsc --noEmit
      - run: npx vitest run --coverage     # 下記 coverage 100% gate
      # deploy は PR では skip (gate のみ)。push/dispatch=staging, tag=prod。
      - name: Deploy (staging)
        if: github.event_name != 'pull_request' && github.ref_type != 'tag'
        run: npx wrangler deploy --env staging
        env: { CLOUDFLARE_API_TOKEN: '${{ secrets.CLOUDFLARE_API_TOKEN }}' }
      - name: Deploy (production)
        if: github.event_name != 'pull_request' && github.ref_type == 'tag'
        run: npx wrangler deploy
        env: { CLOUDFLARE_API_TOKEN: '${{ secrets.CLOUDFLARE_API_TOKEN }}' }
```

ハマりどころ:
- **Node 22+** (wrangler v4 は v20 で `requires at least Node.js v22.0.0` と落ちる)
- **`pull_request` trigger を必ず入れる** — 無いと test/coverage が PR で gate されず、
  merge 後 deploy 直前に初実行になる (security ロジックが無 gate で deploy される)
- **deploy step は `github.event_name != 'pull_request'` で囲う** — PR で staging を
  deploy しないため

### coverage 100% gate (org 標準を DO worker でも維持)

pure な認可/ロジック file (cloudflare 非依存) は 100% gate する。`vitest.config.ts`:

```ts
export default defineConfig({
  test: {
    include: ['test/**/*.test.ts'],
    coverage: {
      provider: 'v8',
      include: ['src/auth-decision.ts'],   // pure な security ロジックだけ
      thresholds: { lines: 100, functions: 100, branches: 100, statements: 100 },
    },
  },
})
```

- DO class 本体 (`*-do.ts`、`cloudflare:workers` / DurableObject / WebSocket 依存) と
  worker entry は **node vitest で計測不可** → `@cloudflare/vitest-pool-workers` が要る。
  通常は coverage.include から外す (pure ロジックだけ 100% gate)。
- `@vitest/coverage-v8` を devDep に追加。`package.json` の `test` も
  `vitest run --coverage` にして `npm test` でも gate がかかるように。

## deploy ordering (bootstrap)

app の service binding は **対象 DO worker が存在しないと解決できない**。
- **DO worker を先に deploy** → その後 app を deploy。
- DO worker workflow を `workflow_dispatch` で先行起動できるのは、その workflow が
  **default branch (main) に乗ってから**。初回は「PR を merge → main で dispatch →
  app 反映」の順になる (chicken-and-egg)。

## WebSocket の動作確認 (log には出ない)

WS の **upgrade リクエストは Workers Observability に記録されない**。確認は:
- ブラウザ DevTools → Network → WS で `wss://.../...` が **101 Switching Protocols**
- または DO が WS auth で叩く下流 (例: auth-worker `/auth/introspect`) の **200** を
  Observability で確認 (= WS が service binding 越しに DO へ到達した間接証拠)

## 最小チェックリスト (新規 DO を足す時)

1. app は no-traffic release? → **新規 DO なら app に置かず別 worker に分離するのが
   標準** (既存 DO を持つ worker を無理に分離し直す必要はない、鉄則参照)
2. DO worker: `[[durable_objects.bindings]]` + `[[migrations]] new_sqlite_classes` +
   default fetch で routing + (必要なら) `[[secrets_store_secrets]]`
3. app: `[[services]]` binding に変更、`durable_objects.bindings`/`migrations` は **0**
4. bespoke deploy workflow (Node 22 / PR で gate / deploy は非 PR / coverage 100%)
5. DO worker を先に deploy → app
6. 既存 worker から DO を剥がす場合は class 削除 catch-22 に注意
   (staging は worker 削除→再作成、prod が未適用なら migration 不要)
7. WS は DevTools 101 + 下流 introspect 200 で確認
