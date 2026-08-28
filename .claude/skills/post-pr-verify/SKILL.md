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
- **書込は防波堤あり**: 注入される dev JWT は `token_kind:"dev"` で、alc-proxy 側の
  read-only enforcement (auth-worker#433) により非 GET は allowlist 以外拒否される。
  expression でクリックしても破壊的操作にはなりにくいが、検証は read 前提で書く。
- **engine**: 既定 `chromium` (フルブラウザ)。`engine: "kitesurf"` で Cloudflare の
  agent-first browser (beta、軽量) — Access ログインページの JS を実行しないため
  `access_hops: 1` になるのが正常 (server 側が data-auto-redirect-url を明示 hop)。
  スクショがたまに失敗する等 beta の粗さがあるので、通常は chromium でよい。
- **本番反映の確認**: `curl -s https://auth.ippoan.org/api/health` の
  `auth_worker_version` (release tag) が対象 commit の tag か先に見る。auth-worker
  以外の repo の検証なら、その repo の deploy 完了 (release wave flip 含む) を待つ。
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
| tool 一覧に無い | MCP クライアントは接続時の tools/list をキャッシュする。deploy 直後は次の接続 (新セッション / 再接続) まで見えない |

## 実装の所在 (直すとき)

auth-worker の `src/lib/verify-shot.ts` (本体・SSRF 境界・Access hop) /
`src/handlers/mcp-tools.ts` (tool 定義) / `src/handlers/mcp-shot.ts`
(`GET /mcp/shot/:id`、PNG 配布)。PNG は `MCP_OAUTH_KV` に TTL 5 分の base64。
`@cloudflare/puppeteer` は `nodejs_compat` flag 必須 (無いと deploy が code 10021)。
経緯・実測の詳細は memory `post-pr-browser-verification` と auth-worker#494。
