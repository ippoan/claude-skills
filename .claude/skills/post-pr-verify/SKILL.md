---
name: post-pr-verify
description: PR merge 後 (= 本番反映後) の検証を auth-worker MCP の verify_screenshot / verify_eval で 1〜2 コールで済ませる運用。ログイン済み状態の本番ページのスクショと、ページ内 JavaScript 評価による値アサーションが、dev JWT の受け渡しなし・wrangler dev なしでできる。トリガー: 「PR 後の検証」「merge 後の確認」「本番で確かめて」「デプロイ確認」「ログイン済みでスクショ」「画面を見て」「verify_screenshot」「verify_eval」「Browser Run」「kitesurf」「dtako の画面」「*.ippoan.org の表示確認」等。ippoan / ohishi-exp 系 repo の PR が merge された後の動作確認タスクでは、curl 単発や手元ブラウザ誘導の前に必ずこの skill を読む。
---

# post-pr-verify — merge 後の本番検証を MCP 1〜2 コールで

auth-worker (#494, PR #495/#496, 2026-08-28) が提供する MCP tool 2 つで、
**ログイン済み状態の本番ページ**を検証する。認証は server 側で完結する
(dev JWT を mint して cookie 注入まで auth-worker 内で行う) ので、
token を Claude が運ぶ必要も、wrangler dev やローカルブラウザも不要。

## 基本レシピ

1. **見た目**: `verify_screenshot { urls: ["https://dtako.ippoan.org/"] }`
   → 返る `shot_url` (TTL 5 分) を `curl -o shot.png <shot_url>` → Read で目視。
2. **値アサーション**: `verify_eval { url, expression }`
   → 例 `expression: "document.querySelectorAll('tbody tr').length"` が行数を返す。
   オブジェクトで複数まとめて取るのが効率的:
   `"({ rows: document.querySelectorAll('tbody tr').length, heading: document.querySelector('h1,h2')?.innerText })"`
   `screenshot: true` を足すと**評価後** (クリック等の副作用込み) のスクショも付く。

どちらも auth-worker MCP (dev-login connector) の tool。`urls` は 1〜5 件、
対象は **https://*.ippoan.org のみ** (SSRF 境界、fail-closed)。CF Access 配下の
ホストも auth-worker 自身が Access の OIDC IdP なので cookie だけで無言通過する。

## 知っておくこと

- **navigate は url 引数**。毎コール新品のブラウザを起動する stateless モデルで、
  コールを跨ぐセッション保持 (開く→クリック→また評価) は無い。必要になったら
  Browser Run session reuse + DO の別 issue (auth-worker#494 の残タスク)。
- **★ 書込の防波堤は `/alc-proxy` を通る経路にだけ効く。** 注入される dev JWT は
  `token_kind:"dev"` で、read-only enforcement (auth-worker#433) が非 GET を
  allowlist 以外拒否する。**ただしその判定は `alc-proxy.ts` の中にある** ので、
  **consumer が自前で `/auth/introspect` する server route には効かない** —
  `verify_eval` からそこを非 GET で叩くと**本番が変わる** (2026-09-04 実測)。
  - **見分け方**: その口が `/api/proxy/...` (= alc-proxy 経由) か、consumer 自前の
    server route か。後者は `grep -rl buildIntrospectForward server/api/` で列挙できる
    (nuxt 系 consumer の慣用。auth-client の `request()` を通らないものが該当)
  - **`/auth/introspect` の応答に `token_kind` は無い** (`active / tenant_id / role /
    email / sub / exp / org_wide` のみ)。consumer 側で弾くには JWT payload を自前で
    base64 デコードする。**introspect が `active:true` を返した後なら署名は検証済み**
    なので、その claim を信じてよい (JWT_SECRET は不要)
  - alc-app の実例: `/api/timecard/punch` は塞いだ (alc-app#163) が、
    **`/api/driver-master/run` (employees を書く) と `/api/print/:deviceId`
    (実物のプリンターに印字) は素通しのまま** (alc-app#162)
- **⇒ 非 GET を評価する前に「その route の副作用は何か」を確かめる。** 防波堤があるから
  安全、と一般化しない。**検証が本番を変えたことに誰も気づかない**のが最悪の形で、
  「書けてしまう」と気づいたら**実行せずに報告して指示を仰ぐ**こと。
- **engine**: 既定 `chromium` (フルブラウザ)。`engine: "kitesurf"` で Cloudflare の
  agent-first browser (beta、軽量) — Access ログインページの JS を実行しないため
  `access_hops: 1` になるのが正常 (server 側が data-auto-redirect-url を明示 hop)。
  スクショがたまに失敗する等 beta の粗さがあるので、通常は chromium でよい。
- **本番反映の確認**: `curl -s https://auth.ippoan.org/api/health` の
  `auth_worker_version` (release tag) が対象 commit の tag か先に見る。auth-worker
  以外の repo の検証なら、その repo の deploy 完了 (release wave flip 含む) を待つ。
- **WS の口を curl で確かめるときは `--http1.1` を付ける。** HTTP/2 は `Upgrade`
  ヘッダを運べないので、付けないと **worker まで届かず 426 が返る** —
  「本番の WS が壊れている」と誤診しかける (2026-09-04 に 3 回踏んだ)。
  `-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Key: <base64>'
  -H 'Sec-WebSocket-Version: 13'` も揃えて初めて 401/101 が返る。
  **ブラウザ側の実際の挙動 (subprotocol にトークンを載せる等) を見たいなら、
  curl より `verify_eval` の中で `new WebSocket(...)` を張る方が正確**
  (ページの cookie/token をそのまま使えるので、本番の認証込みで確かめられる)。
- **★★ この 2 tool は本番スコープ。staging の検証には使えません。**
  dev JWT を発行するのは**本番の auth-worker (`auth.ippoan.org`)** なので、
  `*-staging.ippoan.org` を開いても **本番の `tenant_id` を持った cookie が入ります**。
  staging の API は **200 を返すのに 0 件**になり、「データが無い」と誤読します。
  - **実測 (2026-09-04)**: 同じ dev セッションで `tenant_id` が
    prod (`alc.ippoan.org`) / staging (`alc-staging.ippoan.org`) とも
    **`536859de-…` で完全一致**。host を変えても token は変わりません
  - ⇒ **staging で「出ているはずのものが出ない」を見ても、それは検証結果ではありません。**
    staging を確かめるには**ユーザーの実ブラウザ**が要ります
  - この skill が「merge されて deploy された後」= **prod 専用**なのは、この制約とも整合します
  - **※ 道具側を直す案が検討中** (ippoan/auth-worker): staging の URL を明示的に拒否する
    案が入れば、**静かに誤った結果が返る**代わりに**弾かれる**ので、誤読が構造的に
    起きなくなります。入ったらこの項目を「拒否されるので誤読しようがない」に書き換えること
- **★ スクショの「空」は 2 つの意味がある。** 「認証が通っていなくて空」と
  「データが無くて空」は、**`verify_screenshot` では区別できません**。
  画面にメールアドレスやユーザー名が出ていても、それは**フロントが cookie を
  デコードして表示しているだけ**で、**API が認可されている証拠になりません**。
  - 区別するには `verify_eval` で **API の status と body を取る**:
    `200` + 空配列 = 認可は通っている (中身が無い) / `401` `403` = 認可の問題
  - **2026-09-04 の実例**: staging の打刻一覧が「打刻記録なし」→「本番の不具合か」と
    誤警報 → eval で **`200` + `{"punches":[],"total":0}`** と分かり不具合説は消えたが、
    **その 0 件自体が上の「本番スコープ」による見かけ**だった (ユーザーの実ブラウザには
    3 件出ていた)。**スクショだけで判断して結論が 3 回ぶれました**
- **叩く URL は画面から拾う。** consumer の proxy path は自明ではありません
  (alc-app は `/api/foo` → **`/api/proxy/foo`**。`/api/proxy/api/foo` は 404 で、
  空 body が返るので「壊れている」と誤読しやすい)。**推測せず、画面が実際に叩いた
  URL を取る**のが確実:
  `performance.getEntriesByType('resource').map(e=>e.name).filter(n=>n.includes('<path片>'))`
  → その URL の `searchParams` を差し替えて再 fetch する
- **値の上限**: eval の戻りは 64KB で切り詰め (`value_truncated: true`)。大きな
  データは expression 側で絞る (`.slice()`, 件数だけ返す等)。expression は 8192 字まで。
- **merge 前の検証はこの skill の範囲外**: ローカル実機 (wrangler dev + dev-login) は
  `dev-login-local-verify` skill が対。こちらは「merge されて deploy された後」専用。

## エラーの読み方

| 応答 | 原因と対処 |
|---|---|
| `not_in_allowlist` (403) | MCP subject が `MCP_OAUTH_KV` の `dev_login_allowed_subjects` に無い。`wrangler kv key put --binding=MCP_OAUTH_KV dev_login_allowed_subjects '["google:<email>"]'` (staging/prod 各 namespace) |
| `google_sub_not_cached` (403) | `google_sub:<email>` cache (30 日) が切れた。claude.ai の dev-login connector (`https://auth.ippoan.org/mcp/google`) を再認可すると callback が再 cache する |
| `browser_binding_not_configured` (503) | その env に `[browser]` binding が無い (wrangler.toml 確認) |
| `url not allowed` (400) | 対象が https://*.ippoan.org 外。これは仕様 (SSRF 境界)。外部サイトは検証対象にしない |
| tool 一覧に無い | MCP クライアントは接続時の tools/list をキャッシュする。deploy 直後は次の接続 (新セッション / 再接続) まで見えない。**ただしセッション中に登録が更新されて後から現れることがある** (2026-09-04 実測: 「無い」と報告した後、同じセッションで `verify_screenshot` が使えるようになった)。**一度 0 件でも、必要になったら引き直すこと**。報告済みなら「その時点では無かった / いま現れた」と**いつの話かを明示して**訂正する |

## 実装の所在 (直すとき)

auth-worker の `src/lib/verify-shot.ts` (本体・SSRF 境界・Access hop) /
`src/handlers/mcp-tools.ts` (tool 定義) / `src/handlers/mcp-shot.ts`
(`GET /mcp/shot/:id`、PNG 配布)。PNG は `MCP_OAUTH_KV` に TTL 5 分の base64。
`@cloudflare/puppeteer` は `nodejs_compat` flag 必須 (無いと deploy が code 10021)。
経緯・実測の詳細は memory `post-pr-browser-verification` と auth-worker#494。
