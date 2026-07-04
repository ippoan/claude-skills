---
name: browser-cookie-borrow
description: >
  CCoW から credential を使う login を走らせると Anthropic egress gateway が TLS を
  MITM 終端して credential を平文復号してしまう (実測: 外部サイトの証明書 issuer が
  `O=Anthropic, CN=Egress Gateway SDS Issuing CA`)。これを回避し、**login (credential を
  使う部分) だけを手元ブラウザに委譲**し、login 後の cookie を cdp-relay の
  `browser_cookies` (CDP `Network.getCookies`、HttpOnly も取れる) で借りて、**検索/CSV
  取得等の認証後操作だけを CCoW 内で高速反復**するパターン。credential は手元ブラウザ →
  サイト (手元 egress) だけを通り CCoW / gateway を一切通らない。scraper の cookie jar が
  login と分離済み (login skip entry がある) ことが前提。ETC (etc-meisai) を worked
  example に同梱。bun-browser-verify (認証 IO 全体を cdp に肩代わり) の cookie 特化版。
  トリガー:「credential を CCoW に通したくない」「egress MITM で平文化」「login だけ手元で」
  「browser_cookies」「cookie 借りて検索」「Network.getCookies」「HttpOnly cookie 取得」
  「手元 login して CCoW で続き」「scrapeFromCookies」「session cookie を CCoW に」等。
---

# browser-cookie-borrow — login は手元ブラウザ、認証後操作は CCoW

## いつ使う

- CCoW 内でスクレイパー/API クライアントの **認証後ロジック (検索・一覧・CSV パース等)
  を実 credential 相当で反復開発したい**が、**credential を Claude の context / CCoW /
  egress に一切通したくない**とき。
- 対象が **cookie ベースのセッション認証** (ASP.NET / Java servlet の JSESSIONID 等) で、
  login さえ済めば以降は cookie だけで通るとき。

## なぜ必要か (egress MITM の実測)

CCoW コンテナの outbound HTTPS は Anthropic egress gateway を必ず通り、**gateway が
TLS を MITM 終端する**。実測で確認できる:

```sh
echo | openssl s_client -connect www.etc-meisai.jp:443 -servername www.etc-meisai.jp 2>/dev/null \
  | openssl x509 -noout -issuer -subject
# subject= CN = *.etc-meisai.jp
# issuer = O = Anthropic, CN = Egress Gateway SDS Issuing CA (production)   ← 本物の CA ではない
```

コンテナの CA bundle (`/root/.ccr/ca-bundle.crt`) に Anthropic CA が入っているのでこの
偽証明書を信頼する。つまり `CCoW → gateway(TLS復号=平文) → 本物のサイト` となり、**CCoW
から login POST すると credential が gateway 内で平文に戻る**。これは cdp-relay env /
temp worker `--var` / 直 fetch どの経路でも同じ =「CCoW から login する」選択に内在する
(詳細は `ccow-network-egress` skill)。

→ **credential を CCoW から送らない**のが唯一の回避。login を手元ブラウザに逃がす。

## 前提

- **cdp-relay 拡張が手元 Chrome に load 済み** (`cdp-pair` / `cdp-agent` skill)。
- **scraper の cookie jar が login と分離**されていること。`login(jar, creds)` が jar を
  作り、以降の操作が `jar` を引数で受ける構造なら、login を skip して手元 cookie を jar に
  注入する entry (`scrapeFromCookies(cookies, startUrl, …)`) を薄く足せる。無ければ先に
  リファクタする。
- cdp-relay に `browser_cookies` tool があること (ippoan/cdp-relay#69 以降)。

## 手順 (CCoW から)

```
1. browser_pair で session を発行 → 手元拡張に貼って接続 (cdp-pair skill)
2. 手元ブラウザで対象サイトに **手動 login** (credential は手元だけ。eval で form を
   埋めると credential が tool param に載るので必ず手動)
3. browser_cookies(session, ["https://<対象 origin>"]) → { cookies_url }
   - cookie 生値は context に載らない。urls で対象 origin に絞る (全 cookie を吸わない)
4. browser_eval(session, "location.href") → login 後 URL (startUrl)
5. bun/node の runner で: curl 相当で cookies_url を fetch → cookie 配列 →
   scrapeFromCookies(cookies, startUrl) で検索/CSV → **サニタイズ済み結果だけ出力**
```

runner は **cookie の value も取得データ (個人情報含み得る) も出力しない**。出すのは
cookie 名 / 件数 / ヘッダ行 / 成否だけ。

## worked example: ETC (etc-meisai)

`ohishi-exp/nuxt-dtako-admin` の実装 (Refs ohishi-exp/dtako-scraper#22):

- `workers/dtako-scraper-relay/src/etc-meisai-client.ts`
  - `etcLogin(jar, …)` が jar を返し `navigateToSearchPage/submitSearch/downloadMeisaiCsv`
    が jar を受ける = **cookie 注入の seam が実在**
  - `scrapeEtcFromCookies(cookies, startUrl, onProgress, …)` — login を skip し cookie を
    jar に注入、`startUrl` (login 後 URL) を cookie 付き GET してアカウント種別を確定し
    検索→CSV
- `workers/dtako-scraper-relay/scripts/verify-etc.ts` — bun 実行専用の runner:
  ```sh
  bun run scripts/verify-etc.ts <cookies_url> <startUrl>
  ```
  `cookies_url` から cookie を回収 → `scrapeEtcFromCookies` → `{ ok, accountType,
  filename, bytes, rows, header }` だけ stdout。cookie value / CSV 明細は出さない。

## 検証範囲の限界 (正直に扱う)

この方式で検証できるのは **cookie での認証後操作 (検索/一覧/CSV パース)** だけ。
**login 実装自体 (form/hidden/funccode/POST チェーン) は検証されない**。login は
この手のスクレイパーで最も壊れやすい箇所なので:

- 「認証後パース検証、login は未」と正確に report する (「スクレイパー検証完了」と書かない)
- login は **本番 cron** or **手元 run** (ソースを `git pull` して手元 `.env` で走らせる)
  or **手元ブラウザの devtools Network を観察して POST を突き合わせる**で別途検証する

## 使い分け

| やりたいこと | 手段 |
|---|---|
| 認証後ロジックを CCoW 内で速く反復 | **本 skill** (cookie 借用) |
| login 含む full flow を検証 | 手元 `git pull` + `bun run` (credential 手元 `.env`) |
| 実 CF colo egress / WAF IP ブロックの確認 | 手元 `wrangler deploy --temporary` (`wrangler-deploy-temporary` skill) — CCoW egress は Anthropic gateway IP なので本 skill では答えられない |
| 認証 IO 全体を cdp に肩代わり (署名 API 等) | `bun-browser-verify` skill |

## アンチパターン

- **cookie を tool 戻り値 / context に直載せする** — session hijack token を transcript に
  残す。必ず stash 経由 (`browser_cookies` は `cookies_url` を返し生値を載せない)。
- **eval で login form を埋める** — credential が tool param = context に載る。手動 login に倒す。
- **urls を渡さず全 cookie を吸う** — blast radius が無用に広い。対象 origin に絞る。
- **これを「full 検証」と report する** — login 未検証を隠さない。
