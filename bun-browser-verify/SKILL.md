---
name: bun-browser-verify
description: >
  CCoW で lib/SDK ロジックを deploy/publish せず bun で実行し、browser-only 認証
  (CF Access cookie / SPA が握る短命 token / egress WAF で CCoW から直叩き不可) な API への
  送受信だけを cdp 経由で手元ブラウザに肩代わりさせて、本番相当の構造/挙動検証を
  非破壊・高速に回す手法。「ビルド/署名は bun (CCoW)・認証付き IO はブラウザ」の分業ハーネス。
  e-Gov 個別署名 Trial を worked example に同梱。
  トリガー:「bun で検証」「deploy せず確認」「local-lib-run」「browser-only 認証の API を叩く」
  「CF Access で bun から叩けない」「SPA の token で fetch」「egress WAF 403」「Trial 構造検証」
  「cdp で代理 fetch」「署名を bun で再現」「e-Gov 構造エラー 特定」等。
---

# bun-browser-verify — CCoW bun 実行 + ブラウザ IO 代理の検証ハーネス

## いつ使うか

「アプリの実コードと同じ入力を組み立てて、本番(相当)API に投げ、返るエラーを見たい。
でも staging に deploy するのは遅い/破壊的」というとき。特に **認証がブラウザ側にしか無い**
ケース:

- 対象 API が **Cloudflare Access** 配下 (CCoW からは sign-in HTML が返る)
- 認証 token が **SPA のメモリ/`window` にしか無い** (例 `window._egovToken`、リロードで消える)
- 対象 origin が **egress WAF で CCoW の IP を弾く** (HTML `403 Forbidden`)

この 3 つのどれかがあると **bun (CCoW) から直接は叩けない**。そこで役割を割る:

| 担当 | やること | 理由 |
|---|---|---|
| **bun (CCoW)** | 入力(zip/payload/署名)をアプリ実コードを移植して組み立てる | 速い・iterate しやすい・依存を本物で動かせる |
| **ブラウザ (cdp)** | その payload を **fetch で送受信**する | cookie(CF Access) + token(SPA) + 同一オリジンを持つのはブラウザだけ |

token は **ブラウザから出さない** (cdp の `browser_eval` 内で `window._token` を使って fetch する)。
CCoW の会話/ログに 1 度も載らない。

> **まず直叩きを試す**。CF Access も WAF も無く、token を安全に渡せるなら bun だけで完結する
> (`fetch` を bun で実行)。このハーネスは「ブラウザ認証の壁」がある時の回避策。

## 4 ステップ・ループ

```
[1] ブラウザを cdp に繋ぐ        → cdp-agent (MSI+quick tunnel) か cdp-pair (Worker+DO)
[2] bun で payload をビルド       → アプリ実コードを移植 (署名/暗号も bun で再現)
[3] ブラウザ経由で送信 (Trial等)  → browser-eval.sh で window の token+cookie 付き fetch
[4] 返ったエラーを読んで [2] へ   → 1 イテレーション数秒、deploy 不要・非破壊
```

### [1] ブラウザ接続

- **cdp-agent** (手元 Windows に MSI、self-host): popup の「接続用プロンプトをコピー」で
  `https://<rnd>.trycloudflare.com/mcp` を受け取る。詳細は `cdp-agent` skill。
- **cdp-pair** (Cloudflare Worker+DO): `mcp__cdp-relay__browser_*` を直接呼ぶ。`cdp-pair` skill。
- 対象アプリのページを **ログイン済みタブ**で開いておく (token / CF Access cookie がそのタブに要る)。
- `browser_eval` が無い古い agent なら `tools/list` で確認 (navigate/screenshot しか無い版がある)。

### [2] bun で payload ビルド (アプリ実コードの移植)

要点は **「アプリと同じ入力を作る」**。アプリの該当関数 (zip 構築・署名・暗号) を bun スクリプトに
移植する。ブラウザ専用 API を使う lib は **shim を global 注入**すれば bun で動くことが多い:

- lib が `new DOMParser()` / `Node.ELEMENT_NODE` / `XMLSerializer` 等の **global を前提**に
  している → `linkedom` の対応クラスを **対象 lib の import より前に** `globalThis` へ注入する
  (再利用スニペット `examples/dom-lib-in-node.ts`、egov 実例は worked example)。順序が肝で、
  lib が module 評価時に global を捕捉するため import 後の注入では効かないことがある:

  ```ts
  import { DOMParser, Node, XMLSerializer } from 'linkedom'
  ;(globalThis as any).DOMParser = DOMParser
  ;(globalThis as any).Node = Node            // Node.ELEMENT_NODE 等の定数も生える
  ;(globalThis as any).XMLSerializer = XMLSerializer
  import { parsePfx, signConfig } from '@ippoan/egov-shinsei-sdk/xmldsig'  // ← 注入後に import
  ```

- PKCS12/RSA 署名・C14N 等も SDK が `node-forge`/`linkedom` 依存なら **bun でそのまま動く**。
  証明書(テスト用 PFX)等の値は **skill/repo に commit しない** (`.gitignore`)。

### [3] ブラウザ経由で送信

`scripts/browser-eval.sh <MCP_URL> --file expr.js` で、ブラウザ上で fetch する JS を実行:

```js
// expr.js — window の token を使い、同一オリジン(=CF Access cookie 付き)で送信
(async () => {
  const fd = "<base64-payload>";              // bun が出した built.b64 を埋める (--file で渡す)
  const t = window._egovToken;                // SPA がメモリに持つ token
  const r = await fetch('/api/egov/apply', {
    method: 'POST',
    headers: { 'Authorization': 'Bearer ' + t, 'Content-Type': 'application/json',
               'X-eGovAPI-Trial': 'true' },   // Trial = 非破壊の構造検証
    body: JSON.stringify({ proc_id: '...', send_file: { file_name: 'z.zip', file_data: fd } })
  });
  return JSON.stringify({ status: r.status, body: await r.text() });
})()
```

数百KB の base64 を埋めるので **`--file` で渡す** (シェル引数長を避ける)。返った `report_list` 等の
エラーを読み、[2] のビルドを直して再送する。

### [4] 反復

エラーを 1 つずつ潰す。`FORCE_*` のような上書きノブを bun 側に足すと、値の総当たり
(version sweep 等) が高速にできる (worked example の `FORCE_VER_i`/`FORCE_ID_i`/`FORCE_NAME_i`)。

## worked example: e-Gov 個別署名 Trial (`examples/egov/`)

`ippoan/nuxt-egov` の最終確認試験 (個別署名 No.23〜49) の構造エラーを非破壊で特定した実例。

- `examples/egov/build-trial-zip.ts` — `final-test.vue` の `submitOne` 個別署名分岐を移植。
  skeleton(`/procedure/{id}` の results を `skeleton.json` に保存)から zip を組み、
  `@ippoan/egov-shinsei-sdk/xmldsig` の `parsePfx`/`signConfig` で **bun 上で署名**する
  (`linkedom` の `DOMParser`/`Node` を global 注入)。GPKI テスト証明書は
  `nuxt-egov/app/composables/useXmlSign.ts` の `TEST_PFX_BASE64` を `pfx-const.ts` に置く
  (証明書値は commit しない)。
- 送信は `browser-eval.sh <MCP_URL> --file send.js` で `/api/egov/apply` に
  `X-eGovAPI-Trial: true` で投げる (CF Access cookie + `window._egovToken` はブラウザが持つ)。

このループで判明した事実 (= 設計上の確定知識):

1. **bun から e-Gov 直叩きは `403`(WAF)、staging proxy 直叩きは CF Access sign-in HTML** →
   送信はブラウザ必須。proxy(CF Worker)は e-Gov に到達できるがそれ自体が Access 配下。
2. **Trial(`X-eGovAPI-Trial:true`)でも署名が前段**。署名必須手続は未署名だと
   `署名が必要な手続です。` で止まり、様式ID等の構造検証に到達しない → 署名を bun で再現する必要がある。
   `linkedom` の C14N で作った署名を **e-Gov は受理**する (署名エラーは出ない)。
3. e-Gov の `report_list[].content` は **エラーを 1 つずつ**返すので、潰す→再送を繰り返す。
   複数様式手続の `_02` は「様式ID `…0002` が未登録」→ version 総当たりでも全滅 →
   `_01` の登録様式(ID/版/名称)のコピー扱いにすると次は「申請書ファイル名称が一致しない」…と
   段階的に正解構造へ寄せられる (正確な対応表は e-Gov spec が要る。`egov-spec` skill で取得)。

## gotcha

- **quick tunnel URL は agent 再起動で変わる**。`530 unregistered` / 到達不能なら popup から取り直す。
  agent 本体が落ちていると `127.0.0.1:19222/ext/info` が `ERR_CONNECTION_RESET`、popup の
  「connected」表示は残骸。agent を再起動 → タブ再接続 → URL 再取得 (`cdp-agent` skill)。
- **SPA token はリロードで消える**。`window._token` が空なら再ログインしてもらう。JWT なら
  `exp` を decode して残り時間を確認できる。
- **token を会話/ツール引数/ログに出さない**。`browser_eval` の JS 内で `window` から読むだけにする
  (本 skill が browser 経由 IO に拘る理由の一つ)。ファイルに落とす場合も `.gitignore` + 使用後削除。
- **大きな payload は `--file`**。式に直書きするとシェル引数長や JSON エスケープで壊れる。
- **証明書/秘密値を skill や repo に commit しない**。worked example の `pfx-const.ts` は `.gitignore`。
- **これは検証ハーネス**。確定した修正は最後にアプリ本体 (例 `final-test.vue`) に反映し、PR の CI/staging で裏取りする。
