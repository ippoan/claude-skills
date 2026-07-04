---
name: wrangler-deploy-temporary
description: >
  `wrangler deploy --temporary` (Wrangler 4.102.0+、2026-06 導入) で認証不要の一時
  Cloudflare アカウントに実 Workers edge へ即デプロイし、60分で自動失効する PoC
  ハーネス。**外部サイトへの Workers egress 到達性検証** (WAF/datacenter IP
  ブロックの有無、実 colo の確認) に最適。CCoW のような Cloudflare アカウント
  未接続の環境でも動く。デプロイ結果 URL 自体が Cloudflare の JS challenge に
  守られるため curl では読めず、cdp-relay 等の実ブラウザ経由で読む必要がある点に
  注意。real credential を要する実ログインフローの検証は、worker 自身が返す
  HTML フォームに手元でユーザーが直接入力する方式 (credential は CCoW を一切
  経由しない) + cookie state をブラウザの hidden field に往復させる「再ログイン
  不要の探索 UI」パターンで安全に行える。
  トリガー: 「wrangler deploy --temporary」「一時 Worker」「ephemeral worker」
  「egress 疎通確認」「Workers から到達できるか」「WAF ブロックされるか PoC」
  「datacenter IP ブロック確認」「一時アカウント」「claim URL」「60分で失効」
  「実ログイン検証」「credential をブラウザで直接入力」「cookie state 往復」
  「毎回ログインさせたくない」「探索 UI」等。
---

# wrangler-deploy-temporary — 認証なし一時 Worker で egress PoC

Cloudflare が 2026-06 に追加した機能。`wrangler deploy --temporary` は
**Cloudflare アカウント未接続でも** 実 Workers edge に即デプロイでき、
60分で自動失効する（claim しない限り何も恒久化しない）。

CCoW のように Cloudflare アカウントに未ログインな環境で、
「この Worker から外部サイトに fetch した時、WAF/datacenter IP で
弾かれないか」を実測したい時に最適。

## いつ使う

- スクレイパーの Worker 化を検討する前に、対象サイトが Cloudflare Workers の
  egress (datacenter IP、colo 不定) からの到達をブロックしていないか確認したい
- 新規 Worker の挙動を、本番アカウントに触れず・deploy 履歴を汚さず試したい
- 「Workers 版で本当に動くか」を実装前に安く検証したい (実装してから気づくと
  高くつく — dtako-scraper#22 / browser-render-rust#14 の経緯参照)

## 前提

- Wrangler **4.102.0 以上** (`npx wrangler --version` で確認)
- Cloudflare アカウントへのログイン・API token は**不要**

## 使い方

### 1. 最小 Worker を書く

```js
// index.js
export default {
  async fetch(request) {
    const targets = [
      { name: "target A", url: "https://example.com/" },
    ];
    const results = [];
    for (const t of targets) {
      const start = Date.now();
      try {
        const resp = await fetch(t.url, {
          method: "GET",
          headers: { "User-Agent": "Mozilla/5.0 ..." },
          redirect: "manual",
        });
        const bodyText = await resp.text();
        results.push({
          name: t.name, url: t.url, status: resp.status,
          ms: Date.now() - start, cfRay: resp.headers.get("cf-ray"),
          bodyLen: bodyText.length,
          bodySnippet: bodyText.substring(0, 200).replace(/\s+/g, " "),
        });
      } catch (e) {
        results.push({ name: t.name, url: t.url, error: String(e) });
      }
    }
    return new Response(
      JSON.stringify({ results, workerColo: request.cf?.colo ?? null }, null, 2),
      { headers: { "content-type": "application/json; charset=utf-8" } }
    );
  },
};
```

```toml
# wrangler.toml
name = "egress-poc"
main = "index.js"
compatibility_date = "2026-06-01"
```

### 2. デプロイ

```bash
cd /path/to/poc-dir
npx wrangler deploy --temporary
```

初回は proof-of-work challenge を solve してから、一時アカウント名 (例
`Vintage Earthquake`)・claim URL・`https://<worker-name>.<random-account-name>.workers.dev`
が表示される。

### 3. 結果を取る — **curl では読めない点に注意**

未 claim の一時 workers.dev サブドメインには **Cloudflare の JS challenge
("Just a moment...") が標準でかかる**。`curl` は JS を実行できないので
チャレンジページの HTML しか返ってこない。

```bash
curl -sS "https://egress-poc.<random>.workers.dev"
# → "Just a moment..." challenge page (中身は読めない)
```

**実ブラウザ経由で読む** (`cdp-pair` skill 等):

```
mcp__cdp-relay__browser_navigate(session, "https://egress-poc.<random>.workers.dev")
# 2-3秒待つ (JS challenge 解決を待つ)
mcp__cdp-relay__browser_eval(session, "document.body.innerText")
```

### 4. 放置する (claim しない)

60分で Cloudflare が自動的にアカウントごと削除する。**claim URL を開いて
恒久化する操作はしない** — それは別の Cloudflare アカウントへの紐付けを
意味するユーザー判断の領域なので、無断で行わない。

## 実例 (2026-07、dtako-scraper#22 / browser-render-rust#14)

Rust + chromiumoxide (headless Chrome) スクレイパーを Cloudflare Worker に
移行する前段で、「Workers の egress (cron 実行 colo が不定 = 国外/共有IPになり
得る) から theearth-np.com / etc-meisai.jp に到達できるか」が設計を左右する
blocker だった (fable-advisor レビューで最優先指摘)。

`wrangler deploy --temporary` で4対象への GET を1つの Worker から fetch し実測:

```json
{
  "results": [
    { "name": "theearth-np login page", "status": 200, "bodyLen": 15713, ... },
    { "name": "theearth-np VenusBridgeService .svc", "status": 200, ... },
    { "name": "etc-meisai.jp top page", "status": 200, "bodyLen": 25357, ... },
    { "name": "etc-meisai.jp login router", "status": 200, "bodyLen": 9389, ... }
  ],
  "workerColo": "KIX"
}
```

全4件 `200 OK`、WAF拒否・bot challenge・geo-block 無し。実装着手前に
blocker を数分で潰せた。実装してから気づいていたら手戻りが大きかった。

## 実ログインフローの検証 (credential をブラウザ直接入力 + cookie state 往復)

**「secret を伴う検証はしない」の例外**: 疎通確認だけでなく `etcLogin()` の
ような**実 credential での POST ログインチェーン自体**を検証したい場合、
credential を worker の env/コードに埋め込むのではなく、**worker 自身が
返す HTML `<form>` にユーザーが手元ブラウザで直接入力**させれば安全に検証
できる (実例: ohishi-exp/nuxt-dtako-admin#134、etc-meisai.jp ログイン検証)。
credential は「ブラウザ → この worker (Cloudflare Workers 実行環境)」だけを
通り、CCoW / Claude のツール呼び出し (tool param・log・会話) には一切載らない
— `browser_cookies` の cookie 委譲パターンと同じ安全性の考え方。

### 毎回ログインさせない: cookie state をページの hidden field に往復させる

`wrangler deploy --temporary` は HMR ではない — コード変更のたびに
redeploy が必要で、かつ deploy ごとに worker のメモリ状態はリセットされる。
ロジックを試行錯誤する間 **毎回ユーザーに credential を再入力させるのは避ける
べき** (UX が悪いだけでなく、変更点の検証速度が落ちる)。

対策: ログイン成功後の cookie jar (`{name,value}[]`) と現在ページの
`{url, html}` を **JSON → UTF-8-safe base64** にして 1個の hidden field に
乗せ、次の一手 (`submitPage(...)`/`goOutput(...)` から抽出した遷移先 URL) を
选ぶボタンフォームと一緒にレンダリングする。ユーザーはボタンをクリックする
だけで良く、worker を redeploy してもこの state を使い回せる:

```ts
interface StateBlob { cookies: [string, string][]; url: string; html: string }

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary); // Latin1 前提の btoa に生バイトを渡す (UTF-8 安全)
}
function base64ToBytes(b64: string): Uint8Array {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}
function encodeState(cookies: Map<string, string>, url: string, html: string): string {
  const blob: StateBlob = { cookies: [...cookies.entries()], url, html };
  return bytesToBase64(new TextEncoder().encode(JSON.stringify(blob)));
}
function decodeState(token: string): StateBlob {
  return JSON.parse(new TextDecoder("utf-8").decode(base64ToBytes(token)));
}
```

`Buffer` (nodejs_compat) は型定義 (`@types/node`) が無いと `tsc` が
`Cannot find name 'Buffer'` で落ちる環境があるため、`btoa`/`atob` +
`TextEncoder`/`TextDecoder` で UTF-8 safe base64 を自前実装する方が依存が
少ない。日本語 HTML を含む cookie state でも文字化けしない。

ページ内の `onclick="submitPage('frm','<url>')"` / `onclick="goOutput(...,
'<url>', ...)"` を正規表現で抽出し、各遷移先を1つのボタン付き `<form
method=POST>` として列挙してレンダリングすれば、ユーザーは「次の一手」を
クリックで選ぶだけで遷移を進められる (`target=フォームhidden`、
`state=<上記トークン>` を次の worker endpoint に POST)。

**属性値の quote ネストに注意**: `onclick="submitPage('a','b')"` のように
**二重引用符属性の中に単引用符の JS 引数**が入るパターンでは、素朴な
`onclick=["']([^"']*)["']` は最初の内側単引用符で打ち切られ
`"submitPage("` までしか取れない。二重引用符区切りを優先し、無ければ
単引用符区切りにフォールバックする:

```ts
function extractOnclick(tag: string): string {
  return tag.match(/onclick="([^"]*)"/i)?.[1] ?? tag.match(/onclick='([^']*)'/i)?.[1] ?? "";
}
```

## アンチパターン

- **`curl` で一時 Worker の結果を読もうとして「動いてない」と誤判断する** —
  JS challenge に阻まれているだけ。実ブラウザ経由で読む
- **通常の `wrangler deploy` (アカウント紐付き) で PoC する** — 本番アカウントの
  deploy 履歴・Worker 一覧を汚す。使い捨て PoC には `--temporary` を使う
  (Wrangler 4.102.0 未満では使えないので `--version` を先に確認)
- **claim URL を勝手に開いて恒久化する** — 別 Cloudflare アカウントへの
  紐付けはユーザー判断。PoC 目的なら開かず自然失効させる
  (5) — セッション終了を待つだけでよく、明示的な削除操作は不要
- **credential を worker のコード/env/`--var` に埋め込む** — 一時アカウントは
  誰でも claim URL を知れば覗ける前提。credential が要る検証は上記の
  「ブラウザの HTML フォームに直接入力させる」方式を使い、worker のソース・
  ログ・response には一切出さない
- **cookie state の生 JSON を Claude のツール呼び出し (browser_eval の
  expression 文字列等) に直接埋め込む** — cookie はセッション capability。
  base64 トークンごと `<input type=hidden>` に乗せてブラウザ内で完結させ、
  Claude 側の tool call param には個々の cookie 値を書かない
