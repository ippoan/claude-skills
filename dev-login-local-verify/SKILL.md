---
name: dev-login-local-verify
description: ohishi-exp/nuxt-dtako-admin をローカルの wrangler dev で prod backend に対して起動し、dev-login (ippoan/auth-worker#423) を実機検証する手順。「wrangler dev」「dev-login」「dev token」「__dev/callback」「ローカルでprod確認」「localhost:8787」「issue_dev_login_url」等のキーワードや、このリポジトリをローカルで起動して本番相当のデータで動作確認したいという要求が出たら必ずこのskillを参照する。env.dev のような named environment を新設・改変する前に必ず読むこと — 過去に一度、遠回りな設計 (env.dev の書き換え、env.dev-prod の新設検討) を経てから、実は不要だと判明した経緯があるため。
---

# dev-login ローカル実機検証

## 結論から: named environment を触るな

`wrangler.toml` の **トップレベル (env 指定なし)** の設定が、実はそのまま prod の
全 binding・var (`AUTH_WORKER` service binding、`NUXT_PUBLIC_API_BASE` 等) を
持っている。これは `wrangler deploy` (タグリリース CI 経由) がデプロイする
「本番」そのものの設定だからだ。

dev-login を検証するのに足りないのは **`DEV_LOGIN="true"` という1つの var** だけ
(`server/routes/__dev/callback.get.ts` のガードがこれを見て、無ければ 404 を返す)。
これは wrangler CLI の `--var` フラグで注入できる — `wrangler.toml` に
宣言されていない新規 var でも問題なく渡せる (wrangler の `collectPlainTextVars()`
がそのまま bindings に spread するだけなので)。

つまり **named environment (`env.dev` を書き換える、`env.dev-prod` を新設する等) は
一切不要**。むしろ避けるべき: named environment は top-level の binding/secret/var
を継承しないため、prod と同じ内容を丸ごと複製することになり、二重メンテと
drift の元になる。加えて `DEV_LOGIN=true` を持つ **deploy 可能な environment
定義** が repo に恒久的に残ってしまう (誰かが誤って `wrangler deploy -e dev` 的な
ことをすれば本番にこのガードが露出しかねない) — `--var` 方式ならそもそも
そういう定義が repo に存在しないので、この懸念自体が構造的に消える。

## 手順

0. **起動前に port 8787 の先住プロセスを必ず確認する** (2026-07-24 実害):
   ```powershell
   Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue
   ```
   前セッションの wrangler dev (workerd + node ツリー) が残っていると、**新しい
   wrangler dev は「Ready on :8787」と表示するのに実際のリクエストは旧バンドルを
   アップロード済みの古いインスタンスが処理する** (コード修正が反映されない、
   ように見える)。残骸がいたら `Stop-Process` で workerd と親 node を止めてから
   起動する。検証セッションの終わりにも wrangler dev を止めておくこと。
1. **origin/main ベースの worktree で作業する** (CLAUDE.md の規範通り。メイン
   worktree ではソース編集しない)。`git worktree add .claude/worktrees/<name>
   origin/main` 等。
2. `node_modules` が無ければ、他の worktree からジャンクション/シンボリック
   リンクすると npm install の待ち時間を避けられる (Windows なら
   `New-Item -ItemType Junction`)。ソースが違っても node_modules の中身は
   基本同じなので使い回して問題ない。
3. **Nuxt をビルドする**:
   ```bash
   npx nuxt build
   ```
   注意: シェルの cwd が `.output/` 配下にあるとビルドが
   `EBUSY: resource busy or locked, rmdir .output/server/chunks` で落ちる
   (Windows はディレクトリを開いているプロセスがいると削除できない)。
4. **wrangler dev を起動する** — `[build]` (custom build = `npm run build`) を
   除いた派生 config を使うと **起動が 168秒 → 23秒** になる (wrangler は
   positional で entry を渡しても `[build]` を必ず実行するため、config から
   消すのが唯一のスキップ手段。2026-07-24 実測):
   ```bash
   sed '/^\[build\]$/,/^$/d' wrangler.toml > wrangler.prebuilt.toml
   npx wrangler dev -c wrangler.prebuilt.toml --remote --var DEV_LOGIN:true --port 8787
   ```
   - `wrangler.prebuilt.toml` は使い捨て生成物 (コミットしない)。wrangler.toml を
     変えたら sed から再生成する。
   - **ソース (app/server/auth-client) を変えたら手順3の `npx nuxt build` を
     再実行するだけでよい — wrangler dev の再起動は不要**。wrangler は bundle
     入力 (`.output/**`) を watch しており、`.output` の変化を検知して自動で
     再バンドル+再アップロードする (編集から ~20-30秒で反映、2026-07-24 実測)。
     イテレーション = nuxt build (~90秒) + 自動 reload のみ。
   - **reload の反映検知は同ディレクトリの `reload-watch.mjs`** — `.output` の
     nitro.mjs が持つ buildId (build ごとの UUID) と `:8787/login` が実際に配信
     している HTML 内の buildId を突き合わせ、一致した時刻を報告する (ground
     truth。ログの推測より確実):
     ```bash
     node .claude/skills/dev-login-local-verify/reload-watch.mjs <worktreeDir> 8787
     ```
     Claude Code の PostToolUse hook (matcher: `Bash`) に
     `node <このskillディレクトリの絶対パス>/reload-watch.mjs --hook` を登録すると、
     Claude が Bash で `nuxt build` を実行するたび自動で反映待ち → 反映時刻が
     additionalContext として報告される (`nuxt build` 以外のコマンドと
     wrangler dev 不在時は無音でスキップ、timeout 120 推奨)。
   - なお **従来構成 (`[build]` あり) でも hot reload は最初から効いていない**:
     wrangler の custom build 監視は `watch_dir` (既定 `./src`) を見るが、この
     repo に `src/` は無い。つまり従来は変更のたびフル再起動 (168秒) が必要
     だった。vite 級の即時 HMR が欲しくても `nuxt dev` は不可 — `/api/proxy` が
     cloudflare binding (AUTH_WORKER) 依存のためデータ経路が 503 になる。
   - `--remote` は service binding (`AUTH_WORKER` 等) や Secrets Store binding を
     実際にデプロイ済みの prod リソースに解決させるために必須。
   - `-e` オプションは付けない。port は次の MCP tool 呼び出しの `port` 引数と
     一致させること。
5. ログに `[wrangler:info] Ready on http://127.0.0.1:8787` が出れば起動完了。

## dev-login token の発行 (MCP 経由)

`issue_dev_login_url` / `issue_dev_token` は auth-worker 自身の Google IdP 専用
MCP surface (`https://auth.ippoan.org/mcp/google`、ippoan/auth-worker#438) の
tool。claude.ai のカスタムコネクタとしてこの URL を追加し、Google 認可を
済ませておけば呼べる (github flow のセッションでは `email` claim が無く
`google_login_required` で 403 になるので、必ず `/mcp/google` 経由で接続すること)。

- `issue_dev_login_url({ port: 8787 })` → `http://localhost:8787/__dev/callback?code=...`
  (60秒 TTL・単回使用) が返る。**port は手順4で wrangler dev が listen している
  port と一致させる**。このURLをブラウザで開くと cookie (`logi_auth_token_dev`、
  server route 用) がセットされ、`/#token=...` (fragment handoff、SPA の
  `consumeFragment` がクライアント側セッションを確立する) へ 302 → 認証済みで
  アプリに遷移する。
  - **fragment handoff は auth-worker#442 (`@ippoan/auth-client` の
    `buildDevRedirectLocation`) 以降の挙動**。それ以前の auth-client では
    cookie しか出ないため、SPA が未認証判定 → 通常ログイン →
    "Invalid or missing redirect_uri" で必ず失敗する (2026-07-24 に踏んだ)。
    node_modules の auth-client が古い場合は #442 の 4 ファイル
    (`devLogin.mjs` / `devLoginCore.mjs` / `index.mjs` / `index.d.mts`) を
    手で当ててから nuxt build する。
  - 既知の見た目上の残課題: `/` → `/operations` の `navigateTo` と Vue Router の
    hash 復元の相互作用で、URL バーに `#token=...` が残る (セッション確立と
    localStorage 保存は正常)。localhost 専用 + 30分 TTL のため受容。
- `issue_dev_token({})` → curl 等での直接検証用の Bearer JWT (30分 TTL)。

いずれも呼び出し元 (このMCPセッション) の Google アカウントが
`DEV_LOGIN_ALLOWED_SUBJECTS` (auth-worker側 KV) に事前登録されている必要がある
(issue #423 参照)。

## 実行環境の注意

- **`preview_start` (Claude Code の browser pane 起動ツール) はこの用途には使わない
  こと。** プロジェクトルート (このリポジトリの親ディレクトリ) からしかコマンドを
  起動できず、worktree 内の相対パス指定を無視してしまう既知の問題がある。
  `wrangler dev` は Bash ツールで worktree のルートから直接起動し、ブラウザでの
  確認だけ `preview_start` の `{url: "http://localhost:8787/..."}` 指定
  (サーバー起動を伴わない、既存サーバーへの単純なナビゲーション) を使うと安全。
- ビルドは数十秒かかる。ログに `Ready on http://127.0.0.1:8787` が出るまで待つこと。
  出る前に接続を試みると接続拒否になる。
