---
name: wrangler-deploy-temporary
description: >
  `wrangler deploy --temporary` (Wrangler 4.102.0+、2026-06 導入) で認証不要の一時
  Cloudflare アカウントに実 Workers edge へ即デプロイし、60分で自動失効する PoC
  ハーネス。**外部サイトへの Workers egress 到達性検証** (WAF/datacenter IP
  ブロックの有無、実 colo の確認) に最適。CCoW のような Cloudflare アカウント
  未接続の環境でも動く。デプロイ結果 URL 自体が Cloudflare の JS challenge に
  守られるため curl では読めず、cdp-relay 等の実ブラウザ経由で読む必要がある点に
  注意。
  トリガー: 「wrangler deploy --temporary」「一時 Worker」「ephemeral worker」
  「egress 疎通確認」「Workers から到達できるか」「WAF ブロックされるか PoC」
  「datacenter IP ブロック確認」「一時アカウント」「claim URL」「60分で失効」等。
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

## アンチパターン

- **`curl` で一時 Worker の結果を読もうとして「動いてない」と誤判断する** —
  JS challenge に阻まれているだけ。実ブラウザ経由で読む
- **通常の `wrangler deploy` (アカウント紐付き) で PoC する** — 本番アカウントの
  deploy 履歴・Worker 一覧を汚す。使い捨て PoC には `--temporary` を使う
  (Wrangler 4.102.0 未満では使えないので `--version` を先に確認)
- **claim URL を勝手に開いて恒久化する** — 別 Cloudflare アカウントへの
  紐付けはユーザー判断。PoC 目的なら開かず自然失効させる
  (5) — セッション終了を待つだけでよく、明示的な削除操作は不要
- **本番 secret や認証情報を PoC Worker に埋め込む** — 一時アカウントは
  誰でも claim URL を知れば覗ける前提で、疎通確認 (GET/ステータスコード) に
  留める。ログイン POST 等 secret を伴う検証はしない
