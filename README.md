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
- **next-session** — 次セッションへの引き継ぎを作成する。`.claude/handoff.md` に「次にやること」を保存 + commit し、CCoW ではコンテナが ephemeral なため引き継ぎ用 issue (`handoff` ラベル / `$ARGUMENTS` 指定) にも同内容をコメントして permalink を提示する。`Refs #N` / 秘密値は載せない。resume-session と対。
- **resume-session** — 前回の引き継ぎを読み込み即座に作業再開する。`$ARGUMENTS` の issue/comment URL → `.claude/handoff.md` → `handoff` ラベル issue の最新コメント、の順で復元 (CCoW で handoff.md が揮発しても可)。新セッション開始時 / compact 後に実行。next-session と対。
- **wt-direct-push** — worktree から直接 push するワークフロー。
- **worktree-cleanup** — 古い worktree を一括掃除する。
- **tag-release** — タグ/リリースを安全に切る。
- **ci-init** / **ci-cache-patterns** — CI のブートストラップ・キャッシュパターン補助。
- **gh-actions-phantom-permission** — `GITHUB_TOKEN` の無効な permission スコープ (例: `administration: write` は workflow-token ではなく fine-grained PAT のスコープ) が原因の GitHub Actions "phantom 0-job failure" run のデバッグ。
- **auto-merge-deploy-race** — CI 内蔵の auto-merge が deploy (staging cutover) を待たずに merge → branch 削除で cutover が cancel され、**deploy 失敗が無音化する** race の検知・復旧・予防 (rust-alc-api#391 で enforce が 2 回未適用になった実害から)。「merged なのに staging に反映されない」時に参照。
- **gh-actions-cross-org-secrets** — cross-org reusable workflow で secret が消える確定知識 (ci-workflows#125〜#127)。`secrets: inherit` の境界判定は **run の repo org 基準**で、ohishi-exp run では明示受領済み secret も nested inherit で落ちる → 全 hop 明示転送が修正。値を出さない可視性 probe と「re-run は reusable sha を pin する」罠も収録。
- **auth-client-consume** — @ippoan/auth-client を Nuxt app で consume する時の subpath 使い分け (root は #imports 連鎖 / `/server` は .mjs+h3 / `/jwt` は framework-free) と「Nitro は node_modules の .ts を transpile しない」「publish は auth-worker の v* tag gate (ETARGET パターン)」等の罠 (#257 consumer 移行 6 repo で確定)。
- **gcp-cloud-run-routing-traps** — Cloud Run「Ready なのに外から 404」系の実測リファレンス (ippoan/cf-flickr-proxy#1 cutover で確定)。Google フロントは外部からの `/healthz` をインターセプトして汎用 404 を返す (= health endpoint は `/health` 標準)、404 は Google 汎用 / Cloud Run インフラ / アプリの 3 種を body で鑑別、新規 service の run.app hostname の GFE 配布ムラ、domain mapping の managed cert が HTTP-01 challenge の 302 で CertificatePending を長引かせる罠、MCP/手動 deploy の digest pin + per-secret IAM grant。
- **ippoan-android-baseline** — ippoan org の Android アプリ標準 (ビルド / 署名 apksigner v1+v2 / gh-pages 一次配信 + QR / versionName(build.gradle)+versionCode=run_number / 更新通知は api.github.com ではなく gh-pages `latest.json` + tag 比較で REST レート制限を食わない / branch・PR 規約)。reference 実装は ippoan/HealthConnectReader。新規 Android repo を立てる時の SoT。
- **alcoholchecker-deploy** — ippoan/AlcoholChecker の deploy / 配信モデルの SoT。dev 端末は PR 時点で prerelease build を FCM OTA push (`trigger-update-dev` + `download_url`)、prod 端末は Release Wave / 管理画面トリガーで明示配信 (master merge は配信なし)。versionCode=run_number 単調増加・rollback 不可・alc.ippoan.org 移行の gotcha。
- **coverage-check** / **coverage-test-patterns** — カバレッジゲートとテストパターン。
- **migrate-test** — リポジトリ移行のテスト補助。
- **npm-supply-chain** — npm サプライチェーンチェック。
- **memory-prune** — 古い memory エントリを整理する。
- **large-codebase-setup** — Anthropic の "large codebases" ブログ記事の 3 本柱 (階層 CLAUDE.md / Stop hook による自己反省 / LSP 統合) をリポジトリに適用する。
- **ippoan-infra-map** — CCoW 基盤 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) の構造・役割・依存方向と「どの repo に何を足すか」を 1 枚にまとめた situational reference。
- **ccow-network-egress** — CCoW コンテナの outbound 制約の実測リファレンス + 60 秒 probe。UDP は全 block (STUN 往復が返らない)、TCP は 443 のみ到達かつ TLS は Anthropic egress gateway が MITM 終端、という確定事実から「WebRTC / P2P 直結 / TURN (Cloudflare Realtime TURN 含む) は CCoW から不成立」「transport 層暗号化は egress 再終端で中継からコンテナを守れない → 中継に中身を見せないにはアプリ層 E2E のみ」を導く。P2P / WebRTC / 直結 / UDP 可否を判断する前に参照。
- **knowledge** — CCoW セッション跨ぎで grep 参照できる「判断の記録」ベース。`decisions/` (経緯・却下案・調査結果。過去形) と `standards/` (推奨 lib / reusable workflow 等の規範。現在形・結論のみ) の二層。外部 DB (Notion / D1+FTS5 / Vectorize / R2 SQL) はローカル grep に乗らず棄却し、skill マウント経由で grep できる本 repo に同居 (索引・API・認証 不要)。規約は `knowledge/rules.json` が SoT (check.py が CI で機械検証)。map は対象外 (各 repo へ同居移行、Refs #59)。
- **ippoan-lib-catalog** — org の「この機能の canonical 実装はどこか」の capability 粒度カタログ。**本体は `knowledge/standards/libs/org-capability-catalog.md` へ移設済み** (このスキルはトリガー維持のポインタ)。util / helper / 横断ロジックを新規実装する前に参照し、既存 lib があれば consume する (lib-first)。rule of two / SOURCE-MIRROR 規約 / 監査記録 (ippoan/claude-md#76) への pointer も。
- **cross-repo-symbol-index** — 30+ repo を跨ぐ構造把握の結論。symbol が要る時はその場でローカル ctags (全 31 repo で 3.8 秒)、保存はしない。唯一永続的に要るのは手書き skill が code と乖離してないかの鮮度チェックで、SessionStart hook が `generated-from` の tree-sha 比較で行う。横断 index を D1/CI で持つ過剰設計は撤去した経緯も記録。
- **plan-with-fable** — コードを読んで詳細な実装計画と PR 分割を Fable に作らせる (`context: fork` + `fable-advisor` agent)。Issue の高レベル計画を実装可能なタスクに落とす段階で使う。使い方: `/plan-with-fable <課題 / Issue の内容>`。下記「Fable plan/review 開発ループ」参照。
- **review-with-fable** — 実装が終わった差分 (`git diff origin/main...HEAD` を skill 本文に注入) を Fable にレビューさせ、バグ・設計の綻び・テスト漏れを重大度順で返させる。下記「Fable plan/review 開発ループ」参照。
- **repo-map** — 1 つの repo の構造ナビゲーション skill (`<repo>-map`) を作る/更新するメタ skill。`session-start-skill-coverage` hook が「skill 無し」/「鮮度切れ」を警告した repo に対し、ローカル ctags + 構造調査で map を起こし `generated-from: <repo>:<tree-sha>` を付ける。
- **auth-worker-map** — → **移設済み** (claude-skills#59 Wave 2)。本体は [`ippoan/auth-worker/.claude/skills/auth-worker-map/`](https://github.com/ippoan/auth-worker/blob/main/.claude/skills/auth-worker-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。

### per-repo map (`<repo>-map`)

`repo-map` メタ skill の手順で各 repo を索引化した構造ナビゲーション skill 群。frontmatter に `generated-from: <repo>:<tree-sha>` を持ち、`session-start-skill-coverage` hook が coverage と鮮度を点検する。基盤 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) は `ippoan-infra-map` の `generated-from` で一括カバー。

- **HealthConnectReader-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/HealthConnectReader/.claude/skills/HealthConnectReader-map/`](https://github.com/ippoan/HealthConnectReader/blob/main/.claude/skills/HealthConnectReader-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **HealthConnectReaderWorker-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/HealthConnectReaderWorker/.claude/skills/HealthConnectReaderWorker-map/`](https://github.com/ippoan/HealthConnectReaderWorker/blob/main/.claude/skills/HealthConnectReaderWorker-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **alc-app-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/alc-app/.claude/skills/alc-app-map/`](https://github.com/ippoan/alc-app/blob/main/.claude/skills/alc-app-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **ci-dashboard-map** — → **移設済み** (claude-skills#59 Wave 2)。本体は [`ippoan/ci-dashboard/.claude/skills/ci-dashboard-map/`](https://github.com/ippoan/ci-dashboard/blob/main/.claude/skills/ci-dashboard-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **ci-workflows-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/ci-workflows/.claude/skills/ci-workflows-map/`](https://github.com/ippoan/ci-workflows/blob/main/.claude/skills/ci-workflows-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **claude-skills-map** — この repo 自身。skill ディレクトリ群を種別 (per-repo map / PR・CI 運用 / 構造把握メタ / secret・MCP / テスト / ドメイン) ごとにグループ索引化し、SKILL.md レイアウト規約・README 同期・scripts/.claude の位置。
- **dtako-scraper-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ohishi-exp/dtako-scraper/.claude/skills/dtako-scraper-map/`](https://github.com/ohishi-exp/dtako-scraper/blob/main/.claude/skills/dtako-scraper-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **egov-shinsei-sdk-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/egov-shinsei-sdk/.claude/skills/egov-shinsei-sdk-map/`](https://github.com/ippoan/egov-shinsei-sdk/blob/main/.claude/skills/egov-shinsei-sdk-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **freee-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`yhonda-ohishi/freee/.claude/skills/freee-map/`](https://github.com/yhonda-ohishi/freee/blob/master/.claude/skills/freee-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-dtako-admin-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ohishi-exp/nuxt-dtako-admin/.claude/skills/nuxt-dtako-admin-map/`](https://github.com/ohishi-exp/nuxt-dtako-admin/blob/main/.claude/skills/nuxt-dtako-admin-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-egov-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/nuxt-egov/.claude/skills/nuxt-egov-map/`](https://github.com/ippoan/nuxt-egov/blob/main/.claude/skills/nuxt-egov-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-ichibanboshi-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ohishi-exp/nuxt-ichibanboshi/.claude/skills/nuxt-ichibanboshi-map/`](https://github.com/ohishi-exp/nuxt-ichibanboshi/blob/main/.claude/skills/nuxt-ichibanboshi-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-items-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/nuxt-items/.claude/skills/nuxt-items-map/`](https://github.com/ippoan/nuxt-items/blob/main/.claude/skills/nuxt-items-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-notify-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/nuxt-notify/.claude/skills/nuxt-notify-map/`](https://github.com/ippoan/nuxt-notify/blob/main/.claude/skills/nuxt-notify-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-pwa-carins-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/nuxt-pwa-carins/.claude/skills/nuxt-pwa-carins-map/`](https://github.com/ippoan/nuxt-pwa-carins/blob/main/.claude/skills/nuxt-pwa-carins-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt-trouble-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/nuxt-trouble/.claude/skills/nuxt-trouble-map/`](https://github.com/ippoan/nuxt-trouble/blob/main/.claude/skills/nuxt-trouble-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **nuxt_dtako_logs-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ohishi-exp/nuxt_dtako_logs/.claude/skills/nuxt_dtako_logs-map/`](https://github.com/ohishi-exp/nuxt_dtako_logs/blob/main/.claude/skills/nuxt_dtako_logs-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **ref-files-worker-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/ref-files-worker/.claude/skills/ref-files-worker-map/`](https://github.com/ippoan/ref-files-worker/blob/main/.claude/skills/ref-files-worker-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **rust-flickr-map** — → **移設済み** (claude-skills#59 Wave 1)。本体は対象 repo の [`ippoan/rust-flickr/.claude/skills/rust-flickr-map/`](https://github.com/ippoan/rust-flickr/blob/main/.claude/skills/rust-flickr-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **cf-flickr-proxy-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/cf-flickr-proxy/.claude/skills/cf-flickr-proxy-map/`](https://github.com/ippoan/cf-flickr-proxy/blob/main/.claude/skills/cf-flickr-proxy-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **release-wave-gcp-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/release-wave-gcp/.claude/skills/release-wave-gcp-map/`](https://github.com/ippoan/release-wave-gcp/blob/main/.claude/skills/release-wave-gcp-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **rust-alc-api-map** — → **移設済み** (claude-skills#59 Wave 2)。本体は [`ippoan/rust-alc-api/.claude/skills/rust-alc-api-map/`](https://github.com/ippoan/rust-alc-api/blob/main/.claude/skills/rust-alc-api-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **rust-ichibanboshi-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ohishi-exp/rust-ichibanboshi/.claude/skills/rust-ichibanboshi-map/`](https://github.com/ohishi-exp/rust-ichibanboshi/blob/main/.claude/skills/rust-ichibanboshi-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **secrets-inventory-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/secrets-inventory/.claude/skills/secrets-inventory-map/`](https://github.com/ippoan/secrets-inventory/blob/main/.claude/skills/secrets-inventory-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **security-notification-app-map** — 本体は [`ippoan/security-notification-app/.claude/skills/security-notification-app-map/`](https://github.com/ippoan/security-notification-app/blob/main/.claude/skills/security-notification-app-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **secrets-inventory-gcp-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/secrets-inventory-gcp/.claude/skills/secrets-inventory-gcp-map/`](https://github.com/ippoan/secrets-inventory-gcp/blob/main/.claude/skills/secrets-inventory-gcp-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
- **ui-preview-map** — → **移設済み** (claude-skills#59 Wave 3)。本体は [`ippoan/ui-preview/.claude/skills/ui-preview-map/`](https://github.com/ippoan/ui-preview/blob/main/.claude/skills/ui-preview-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。

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

## Fable plan/review 開発ループ (opusplan pipeline)

Opus を司令塔に置きつつ、判断が効く「計画」と「レビュー」だけを上位モデル Fable に切り出す開発ループ (Refs [#68](https://github.com/ippoan/claude-skills/issues/68))。実装はコスト効率のため Sonnet (`opusplan` env が自動切替)。

| 段階 | 役割 | モデル | 手段 |
|---|---|---|---|
| 1. Plan (web) | 高レベル計画 → Issue 化 | 人 + web | issue-design |
| 2. 実装 Plan | コード読み → 詳細 plan + PR 分割 | **Fable** | `/plan-with-fable` |
| 3. 管理 + 実装 | タスク登録・管理 → 実装 | opusplan (Opus → Sonnet) | env 設定済 |
| 4. Review | 差分レビュー | **Fable** | `/review-with-fable` |

両 skill は共有エージェント [`fable-advisor`](.claude/agents/fable-advisor.md) (`model: fable`、read-only、実装しない) を `context: fork` で起動する。fork は会話文脈を見ないため、review は `` !`git diff` `` 注入、plan は `$ARGUMENTS` への課題の明示渡し + 自前のコード読みで補う。`opusplan` の plan フェーズは 200K context 固定なので、大規模リポジトリを読ませる実装 plan は Fable (1M context) 側に寄せる。

### 前提条件

- 組織の Fable アクセス + Claude Code **v2.1.170 以降**
- `CLAUDE_CODE_SUBAGENT_MODEL` が**未設定**であること (設定済だと agent の `model: fable` を上書きし、両 skill とも Fable が無効化される)
- 段階 3 の `opusplan` env (`ANTHROPIC_MODEL=opusplan` + pin) は別途設定済みであること
- CCoW では agent / skill ともリポジトリにコミットして使う (`~/.claude` は不可)
- コスト注意: 1 ループで Fable を最低 2 回 (plan + review) 呼ぶ。要所限定の運用前提

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
