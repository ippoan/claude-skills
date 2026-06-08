# claude-skills

`ippoan` プロジェクト向けの共有 Claude Code スキル集。

> `yhonda-ohishi/claude-skills` から移行。secret 値や内部インフラの詳細を埋め込んでいたスキル (`secrets.md`, `supabase-r2`, `incus-sandbox`, `wt-quick`, `secret-rotate-pipe`, `dev-proxy-debug`) は移行時に意図的に除外した。

各スキルは `SKILL.md` を含むディレクトリ単位で配置されている。このリポジトリをプロジェクトとして開くと、全スキルが `/<skill-name>` で利用可能になる。

## 閲覧用サイト (GitHub Pages)

`<repo>-map` スキル群を人間向けに整形した閲覧サイトを GitHub Pages で配信する: **<https://ippoan.github.io/claude-skills/>**

- 各ページの Source of Truth は repo 内の `<repo>-map/SKILL.md` (+ `.claude/skills/ippoan-infra-map`)。`main` への push で [`pages.yml`](.github/workflows/pages.yml) が [`scripts/build_docs.py`](scripts/build_docs.py) → `mkdocs build` を回して自動再デプロイする (二重メンテ不要)。
- 自動再デプロイは [`auto-merge.yml`](.github/workflows/auto-merge.yml) が **org PAT (`TAG_RELEASE_PAT`)** で PR を merge することに依存する。`GITHUB_TOKEN` で merge すると GitHub の再帰防止 (GITHUB_TOKEN 起因イベントは `workflow_dispatch` / `repository_dispatch` 以外 run を作らない) で merge の push が `pages.yml` を起動しないため、実ユーザー帰属の PAT で merge して `on: push` を発火させている。PAT 不在時は手動 `workflow_dispatch` で再デプロイする。
- frontmatter の `generated-from` を「対象 repo + 追従コミット」バッジに、`description` (トリガー語) は折りたたみに変換する。
- ローカルプレビュー: `pip install -r requirements-docs.txt && python scripts/build_docs.py && mkdocs serve`

## スキル一覧

- **open-multirepo** — 複数リポジトリと任意のプロンプトを事前アタッチした `claude.ai/code` の起動 URL を生成する。使い方: `/open-multirepo <repo1>, <repo2>, ... — <optional prompt>`
- **check-issue** — GitHub issue を確認してトリアージ用のコンテキストを抽出する。
- **pr-push** — リポジトリの規約に従って PR を作成・push する。
- **pr-subscribe** — `subscribe_pr_activity` 経由で、現在の CCoW セッションを PR の活動 (CI 失敗 / コメント / レビュー) に購読させる。PR イベントでセッションが再起動される (cc-relay #69)。PR URL / `owner/repo#N` を渡す。未指定時は user に確認する。使い方: `/pr-subscribe <PR URL>`
- **wt-direct-push** — worktree から直接 push するワークフロー。
- **worktree-cleanup** — 古い worktree を一括掃除する。
- **tag-release** — タグ/リリースを安全に切る。
- **ci-init** / **ci-cache-patterns** — CI のブートストラップ・キャッシュパターン補助。
- **gh-actions-phantom-permission** — `GITHUB_TOKEN` の無効な permission スコープ (例: `administration: write` は workflow-token ではなく fine-grained PAT のスコープ) が原因の GitHub Actions "phantom 0-job failure" run のデバッグ。
- **ippoan-android-baseline** — ippoan org の Android アプリ標準 (ビルド / 署名 apksigner v1+v2 / gh-pages 一次配信 + QR / versionName(build.gradle)+versionCode=run_number / 更新通知は api.github.com ではなく gh-pages `latest.json` + tag 比較で REST レート制限を食わない / branch・PR 規約)。reference 実装は ippoan/HealthConnectReader。新規 Android repo を立てる時の SoT。
- **coverage-check** / **coverage-test-patterns** — カバレッジゲートとテストパターン。
- **migrate-test** — リポジトリ移行のテスト補助。
- **npm-supply-chain** — npm サプライチェーンチェック。
- **memory-prune** — 古い memory エントリを整理する。
- **large-codebase-setup** — Anthropic の "large codebases" ブログ記事の 3 本柱 (階層 CLAUDE.md / Stop hook による自己反省 / LSP 統合) をリポジトリに適用する。
- **ippoan-infra-map** — CCoW 基盤 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) の構造・役割・依存方向と「どの repo に何を足すか」を 1 枚にまとめた situational reference。
- **ccow-network-egress** — CCoW コンテナの outbound 制約の実測リファレンス + 60 秒 probe。UDP は全 block (STUN 往復が返らない)、TCP は 443 のみ到達かつ TLS は Anthropic egress gateway が MITM 終端、という確定事実から「WebRTC / P2P 直結 / TURN (Cloudflare Realtime TURN 含む) は CCoW から不成立」「transport 層暗号化は egress 再終端で中継からコンテナを守れない → 中継に中身を見せないにはアプリ層 E2E のみ」を導く。P2P / WebRTC / 直結 / UDP 可否を判断する前に参照。
- **cross-repo-symbol-index** — 30+ repo を跨ぐ構造把握の結論。symbol が要る時はその場でローカル ctags (全 31 repo で 3.8 秒)、保存はしない。唯一永続的に要るのは手書き skill が code と乖離してないかの鮮度チェックで、SessionStart hook が `generated-from` の tree-sha 比較で行う。横断 index を D1/CI で持つ過剰設計は撤去した経緯も記録。
- **repo-map** — 1 つの repo の構造ナビゲーション skill (`<repo>-map`) を作る/更新するメタ skill。`session-start-skill-coverage` hook が「skill 無し」/「鮮度切れ」を警告した repo に対し、ローカル ctags + 構造調査で map を起こし `generated-from: <repo>:<tree-sha>` を付ける。
- **auth-worker-map** — ippoan/auth-worker の構造ナビゲーション (MCP OAuth Provider / 各 SSO provider / admin・api / DO / packages / wrangler prod-staging 構成と gotcha)。`repo-map` で作った第一号の実例・雛形。

### per-repo map (`<repo>-map`)

`repo-map` メタ skill の手順で各 repo を索引化した構造ナビゲーション skill 群。frontmatter に `generated-from: <repo>:<tree-sha>` を持ち、`session-start-skill-coverage` hook が coverage と鮮度を点検する。基盤 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) は `ippoan-infra-map` の `generated-from` で一括カバー。

- **HealthConnectReader-map** — ippoan/HealthConnectReader (Kotlin/Android) — Health Connect の運動データ (ExerciseSession/Distance/Speed) を読んで worker に upload する自分用アプリ。MainActivity 権限フロー / WebView JS bridge / 日次 UploadWorker と Manifest 権限・署名・dataOriginFilter の gotcha。
- **HealthConnectReaderWorker-map** — Android HealthConnectReader の WebView UI + R2/D1 backend Worker。HC・Zones・manual・ghapi 4 source の upload/merge/突合経路・Google Health 連携 DO・auth 3 経路・single-env (staging=prod) gotcha。
- **alc-app-map** — yhonda-ohishi-alc/alc-app (業務用アルコールチェッカー / 複合 public repo)。`web/` (Nuxt 4 PWA on Workers) / `cf-alc-signaling/` (WebRTC signaling DO) / `fc1200-wasm` (秘匿) の区画、WebSerial/WebRTC/顔認証 composable、テスト方針 (v8 ignore 禁止 / mock-live 統一) の gotcha。
- **ci-dashboard-map** — CI 状況 SSR ダッシュボード + GitHub MCP server (~46 tool) + Release Wave (canary flip/compatibility 突合) を 1 worker に同居。CIDashboardHub/ReleaseWaveHub DO・webhook 経路・close 確認フロー・KV エイリアス罠。
- **ci-workflows-map** — org 共通 GitHub Actions reusable workflow 集。frontend/go/lib/rust-ci・cloud-run-deploy・auto-merge・branch-protection・release-wave-handler・tag-release を種別索引化し、caller 必須 permissions・auto-merge dual-step・coverage 100% gate の gotcha。
- **claude-skills-map** — この repo 自身。skill ディレクトリ群を種別 (per-repo map / PR・CI 運用 / 構造把握メタ / secret・MCP / テスト / ドメイン) ごとにグループ索引化し、SKILL.md レイアウト規約・README 同期・scripts/.claude の位置。
- **dtako-scraper-map** — ohishi-exp/dtako-scraper (Rust/Axum + chromiumoxide)。theearth-np.com から csvdata.zip を取得し daiun-salary へ upload する Cloud Run スクレイパー。SSE 進捗・comp_id 直列化・手動 deploy の gotcha。
- **egov-shinsei-sdk-map** — e-Gov 電子申請API v2 の TypeScript npm ライブラリ。EgovClient (全33エンドポイント)・OAuth2 PKCE・XML署名 (xmldsig)・型定義と unit(msw)/手動 integration test の CI 方針。
- **freee-map** — ippoan/freee (法人会計を Claude Code + freee MCP で回す薄い運用 repo)。CLAUDE.md + hook scripts + 同梱 freee-* skill を索引化し、MCP tool prefix の環境差・自動ログ hook・勘定科目検索・銀行同期明細の消込制約。
- **nuxt-dtako-admin-map** — dtako デジタコ運行データ管理画面 (Nuxt 4 + Workers)。rust-alc-api 直 fetch frontend と R2 binding が要る Excel export server route の配置、sync HTTP 維持 (async 化 revert) 等の gotcha。
- **nuxt-egov-map** — e-Gov 電子申請 検証ツール (Nuxt 4 + Workers)。OAuth2 (egov-shinsei-sdk) / 申請送信 / kousei.xml 構築 / xmldsig 署名 / e-Gov API プロキシ・別 Worker の配置と個別署名形式の gotcha。
- **nuxt-ichibanboshi-map** — 一番星 売上分析ダッシュボード (Nuxt 4 SPA + Workers)。ECharts 売上チャート群 / sales API プロキシ / CF Access Service Token + auth-worker tenant gate 集約の配置。
- **nuxt-items-map** — 物品管理 PWA (Nuxt 4 + Workers、`app/` 無し旧構成)。バーコード/NFC スキャン・画像・別 Worker (sync.mtamaramu.com DO) への WS マルチデバイス同期・LINE WORKS 自動ログインの配置。
- **nuxt-notify-map** — 文書配信・メール受信・墨消し通知 (Nuxt 4 + Workers)。frontend pages と 2 補助 Worker (email-receiver / realtime-bus RedactBus DO) の 3 独立 deploy 単位・墨消し WS 通知の配置。
- **nuxt-pwa-carins-map** — 自動車保険管理 PWA (Nuxt 4 + Workers)。`/api/proxy/*` → rust-alc-api carins REST proxy・auth middleware の配置。
- **nuxt-trouble-map** — トラブル報告 PWA (Nuxt 4 + Workers)。報告フォーム / 一覧 / rust-alc-api trouble proxy・auth の配置。
- **nuxt_dtako_logs-map** — デジタコ運行ログ表示 Nuxt 4 PWA / Workers。地図+テーブルのログビューア、`/api/proxy/*` → rust-alc-api REST proxy の配置と、CLAUDE.md の gRPC-proxy 大幅 drift (実コードは carins 同型 REST proxy)・worker 名ハイフン `nuxt-dtako-logs`・domain `ohishi2.mtamaramu.com` の gotcha。
- **ref-files-worker-map** — 参照ファイル/spec 保管庫の HTTP+MCP facade。D1(Drizzle)+R2 blob・pre-signed upload/download・bulk-upload Workflow・durable `/mcp`(DO+WS)・`/v1`↔MCP tool 1:1・aud="*"/staging AS pin の gotcha。
- **release-wave-gcp-map** — ippoan/release-wave-gcp (Go/Cloud Run)。Release Wave の canary flip / no-traffic deploy 切替を司る handler の構造。
- **rust-alc-api-map** — アルコールチェッカー基盤の Rust/Axum Cargo workspace (13 domain crate + gateway/tenko/carins/dtako/trouble の複数バイナリ、PostgreSQL+RLS、Cloud Run)。crate 別ルート・monolith/per-domain 二系統・RLS/migration/Release Wave deploy 分離の gotcha。
- **rust-ichibanboshi-map** — 一番星 SQL Server CAPE#01 の売上を tiberius で読む Rust/Axum API。sales 集計エンドポイント・売上集計ロジック (税抜カラム/請求K)・musl deploy + Cloudflare Tunnel の gotcha。
- **secrets-inventory-map** — secret/SA 監査 + 投入/rotate MCP server (Worker)。GCP=SoT・メタのみ read・proxy 集約・CF Access(人間)/binding_jwt(MCP, mcp.write scope) 二重認証・stateless `/mcp` と stateful `/mcp-do` dual-path。
- **secrets-inventory-gcp-map** — ippoan/secrets-inventory-gcp (Go/Cloud Run)。`secrets-inventory` Worker から GCP Secret Manager/IAM/CF・GitHub secret を代行する proxy の read endpoint と最小 write 例外・GCP key 0 個運用・rotate guardrail。
- **ui-preview-map** — 静的 UI 成果物の ephemeral プレビュー配信基盤 (tar.gz 直 PUT→展開ガード→SQLite→別オリジン配信→WS live→TTL 削除)。PreviewDO・control/配信オリジン分離・iframe sandbox 隔離・MCP tool。
- **ippoan-drift-map** — ippoan/ippoan-drift。現時点で commit ゼロの空 repo のためプレースホルダ (generated-from に empty tree SHA)。最初の commit が入ると hook が鮮度切れを検出し `repo-map` で実体化する。

- **wrangler-logs** — Cloudflare Workers のログを tail・検索する。
- **cdp-browser** — CDP 経由でブラウザを操作する (Tailscale 直結 port 9223 + Playwright)。
- **cdp-pair** — CCoW から手元 Chrome を cdp-relay (DO+WS リレー) 経由で操作するための pairing フローを Claude が主導するスキル。`browser_pair` で短命 pairing code を発行 → relay_url/session/pair_code を MV3 拡張 popup に貼ってもらって WS 合流 → `browser_screenshot` で疎通確認 → navigate/screenshot で操作。UDP 封鎖 + NAT 越えが要る CCoW 向け (Tailscale 直結が通る環境は cdp-browser を使う)。`RELAY_TOKEN` は会話に出さず短命 pair_code だけ渡す。
- **cdp-agent** — 手元 Windows に MSI で入れた `cdp-agent` (quick tunnel + MCP server + 拡張 long-poll、self-host 構成) 経由で CCoW から手元 Chrome を操作するスキル。拡張 popup の「接続用プロンプトをコピー」で渡された MCP URL (`https://<rnd>.trycloudflare.com/mcp`) に `scripts/cdp-call.sh` で curl tools/call し、`browser_navigate` / `browser_screenshot` を実行 (screenshot は /tmp に保存 → Read tool で確認)。cdp-pair (Worker+DO/WS) や cdp-browser (Tailscale 直) とは別経路。quick tunnel URL 揮発・extension not connected の gotcha 付き。実装: ippoan/cdp-relay#12。
- **egov-api** / **egov-spec** — e-Gov API ヘルパー。
- **ref-files-bulk** — ref-files MCP の `folder_download_url` で folder 配下を tar.gz で一括取得 → `/tmp/` に展開して通常の Read で読むスキル。`file_get` を 1 つずつ呼ぶ token 浪費を避ける。
- **ui-preview** — ビルド済み静的 UI 成果物を `ui-preview.ippoan.org` の DO へ publish し、別オリジン (workers.dev) の iframe で目視確認する preview URL を発行するスキル。tar.gz を直 PUT (MCP `create_preview` / `get_preview_stats` または直 curl)。親ページは WebSocket で publish を検知して自動更新、版は最後の publish から 10 分で自動削除 (ephemeral)。Nuxt/Vite は deep path 用に base 調整が要る (skill 参照)。「見た目を確認したい」「この画面どう見える？」等で使う。
- **mcp-user-setup** — Cloudflare Worker-native MCP server (`ref-files-worker /mcp` 等) を `~/.claude.json` の user-scope `.mcpServers` に手動 attach するスキル。CCoW では `session-start-write-mcp-user-scope.sh` hook が自動実行するため、ローカル dev / 別環境 / hook skip 時の手動 fallback。
- **create-cr-mcp** — Cloudflare Workers 上に新しい MCP server を `@ippoan/mcp-cf-workers` factory (`createWorkerMcp` stateless `/mcp`) を consume して新規構築する手順。binding_jwt 認証 (auth-worker introspect) + wrangler + CI/deploy + vitest 一式に加え、**claude.ai connector で実際に繋がる**ために必須の OAuth discovery 配線 (origin に `/.well-known/oauth-authorization-server` + `/register` + protected-resource を auth-staging へ proxy) まで含む。雛形は `mcp-cf-workers/examples/cf-access-mcp`。mcp-cf-workers#26 の接続解決知見を codify。
- **eml-read** — `.eml` (RFC822 メール) を人間可読化するスキル。MIME ヘッダ (RFC2047 `=?UTF-8?B?...?=`) を decode し本文を charset 解決、添付を保存。PPAP (パスワード付き zip + パスワード別メール) の受領にも対応。`ref-files-bulk` で落とした `.eml` をそのまま Read すると読めないため、その前段で使う (相補的)。
- **nuxt-vitest** / **worker-vitest** — Nuxt / Workers 向け Vitest ハーネス。
- **type-safe-pipeline** — 型安全なデータパイプラインの足場を作る。
- **verify-env** — 環境変数を検証する。
- **repo-migrate** / **package-publish-debug** — リポジトリ・パッケージ関連のその他ツール。
- **secret-inject** — secret を GCP(SoT)/Cloudflare Secrets Store/GitHub Actions org secret に **no-leak** で投入・rotate する。値を LLM context / tool-call / log に一切載せず、CCoW の OAT から mcp.write の binding_jwt を mint して `security-inventory` の `/mcp/secret-upload` に `--data-binary` で直送する。`create_secret` MCP tool は value が tool param に載る (context leak) ので、生成系 secret はこちらを使う。
- **secret-naming** — CF Secrets Store ↔ GCP Secret Manager の secret 命名規約 (SoT)。CF Secrets Store binding `secret_name` は kebab-case、GCP Secret Manager 名は SCREAMING_SNAKE_CASE。両者 rename 不可 + alias は rotation 2 重 bump で drift するため名前は揃えず規約で固定し、同一 value の pair は GCP を先に rotate → CF/GH へ片方向 propagate する。違反は claude-hooks `secret-naming-guard.sh` が Write/Edit 時に非ブロッキング警告 (Refs ippoan/secrets-inventory#23)。

- **copy-paste-friendly** — Claude が直接 push できず (スコープ外 / アクセス不可 / ローカル専用 worker 等) ユーザーが手元でコピペ適用する時、コピー操作が複数の ``` ブロックに分割されて何度もコピペさせる事態を防ぐルール。同一ファイルの複数箇所の置換を別ブロックに割らず、**1 回コピー & 実行で全変更が入る単一スクリプト** (python 一括置換 / `git apply` diff) にまとめる。コードブロック内に説明文を混ぜない。

スキルではない単独の markdown ノート: `backend-check.md`, `bazel-rust.md`, `compare-pdf.md`, `smart-read.md`。

## ディレクトリ構成

```
.claude/skills/<name>/SKILL.md   # プロジェクトレベルのスキル (推奨パス)
<name>/SKILL.md                  # 旧来の top-level レイアウト (引き続きサポート)
```

新しいスキルは `.claude/skills/<name>/SKILL.md` を使うこと。

## 別リポジトリからスキルを使う

これらのスキルがプロジェクトレベルで使えるのは、このリポジトリで Claude Code セッションを起動した時だけ。別リポジトリ (例: `ippoan/auth-worker`) から使う場合は以下のいずれかを選ぶ。

- **(推奨) SessionStart hook で自動インストール** — `yhonda-ohishi/claude-hooks` の [`session-start-install-skills.sh`](https://github.com/yhonda-ohishi/claude-hooks/blob/master/session-start-install-skills.sh) を `~/.claude/settings.json` に登録する。`claude-skills` と `claude-hooks` を `~/.claude/sources/` に shallow clone し、各 `SKILL.md` を `~/.claude/skills/<name>` にシンボリックリンクする (冪等、TTL 1 時間)。一度実行すれば、以降の全セッションで上記スキルが利用可能になる。

  ```jsonc
  {
    "hooks": {
      "SessionStart": [
        {
          "hooks": [
            { "type": "command", "command": "/home/<you>/.claude/hooks/session-start-install-skills.sh", "timeout": 30 }
          ]
        }
      ]
    }
  }
  ```

  環境変数とテストの詳細は [claude-hooks README](https://github.com/yhonda-ohishi/claude-hooks#session-start-install-skillssh-詳細) を参照。

- 対象の `SKILL.md` を別リポジトリの `.claude/skills/<name>/` にコピーする
- `claude-skills` をプラグインとして公開し、`.claude/settings.json` で有効化する
