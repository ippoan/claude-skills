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
- **pr-subscribe** — `subscribe_pr_activity` 経由で、現在の CCoW セッションを PR の活動 (CI 失敗 / コメント / レビュー) に購読させる。PR イベントでセッションが再起動される (cc-relay #69)。PR URL / `owner/repo#N` を渡す。未指定時は user に確認する。使い方: `/pr-subscribe <PR URL>`。**desktop/CLI セッションでは push が届かないので代わりに pr-watch を使う**。
- **pr-watch** — desktop/CLI の Claude Code から PR/Issue を「CI 失敗・新規コメント・merge/close」まで監視する。CCoW の webhook push (pr-subscribe) が届かない環境向けに、ユーザー端末で回す `gh` delta/ETag ポーリングスクリプト (`scripts/watch-pr.ps1` / `.sh`) を渡す。LLM トークン消費ゼロ・GitHub API rate はアイドル時実質0・セッションを閉じても生存。sticky (edit-in-place) コメント bot の検知や GraphQL/REST rate 枠の違いなど実装上の罠を回避済み。
- **next-session** — 次セッションへの引き継ぎ。**local Claude Code では task チップとして次を起動し、起動確認まで見届けてから自分を archive する**のが既定 (監督役の交代手順・宛先のタイトル逆引きもここ)。CCoW ではコンテナが ephemeral なため引き継ぎ用 issue (`handoff` ラベル / `$ARGUMENTS` 指定) が唯一の正本で handoff.md は作らない。どちらも使えない環境は `.claude/handoff.md` / memory。`Refs #N` / 秘密値・内部アドレスは載せない。resume-session と対。
- **task-split** — 大きな作業を PR サイズの独立タスクに分割し、spawn_task チップで worktree 別セッションとして並行起動する**親側**の運用。親子通信プロトコルの埋め込み、起動後の交通整理、マージ順の采配まで。**命名規約 (親 `#p<issue>` / 子 `#c<親issue>-<番号>`、子が自分の issue を持つなら `#p<親issue>-c<子issue>`) の正本**もここ。next-session / report-to-parent と対。
- **report-to-parent** — spawn_task で起動された**子側**が、起動元 (親) へ `send_message` で報告する運用。着手時 / 設計判断に迷ったとき / branch push 完了時。親の見つけ方 (タイトル逆引き) を含む。
- **gh-actions-live** — GitHub Actions の run 状態変化を Windows Chrome 拡張 (ippoan/gh-actions-live) → Linux の ws-bridge → Monitor で **push で受け取る**。`gh run list` の sleep ループの代替。Claude から github.com タブ経由で拡張の設定を入れ、bridge 経由でウィンドウ起動 / set-config / update / status。非管理 Windows の導入手順 (MSI perUser + unpacked 読み込み) と踏み抜き済みの罠 (BOM / byte[] / host_permissions / alive Origin / 再接続ストーム)。
- **kintai-ops** — 勤怠 (kintai) まわりを 3 repo 横断 (rust-ichibanboshi / nuxt-dtako-admin / rust-alc-api) で触るときの運用知識。**merge = 本番反映ではない** (repo・worker ごとに main=staging / tag=prod / flip)、子は branch push まで PR は親、カバレッジ 100% gate と `tracing` 1 行の罠、オンプレ測定口、踏み抜き済みの罠。
- **resume-session** — 前回の引き継ぎを読み込み即座に作業再開する。`$ARGUMENTS` の issue/comment URL → `.claude/handoff.md` → `handoff` ラベル issue の最新コメント、の順で復元 (CCoW で handoff.md が揮発しても可)。新セッション開始時 / compact 後に実行。next-session と対。
- **wt-direct-push** — worktree から直接 push するワークフロー。
- **worktree-cleanup** — 古い worktree を一括掃除する。
- **tag-release** — タグ/リリースを安全に切る。
- **ci-init** / **ci-cache-patterns** — CI のブートストラップ・キャッシュパターン補助。
- **create-preview** — Cloudflare Workers front repo に「push だけで更新される軽量プレビュー環境」を追加する (`wrangler.toml` の `[env.preview]` + `ci-workflows` の軽量 `preview-deploy.yml` caller + CLAUDE.md URL 表)。CF Token・dashboard 手動設定は不要、既存 CI の credential と `*-preview.ippoan.org` の CF Access wildcard app をそのまま使う。ippoan/nuxt-trouble が reference 実装 (Refs ippoan/secrets-inventory#85)。
- **gh-actions-phantom-permission** — `GITHUB_TOKEN` の無効な permission スコープ (例: `administration: write` は workflow-token ではなく fine-grained PAT のスコープ) が原因の GitHub Actions "phantom 0-job failure" run のデバッグ。
- **auto-merge-deploy-race** — CI 内蔵の auto-merge が deploy (staging cutover) を待たずに merge → branch 削除で cutover が cancel され、**deploy 失敗が無音化する** race の検知・復旧・予防 (rust-alc-api#391 で enforce が 2 回未適用になった実害から)。「merged なのに staging に反映されない」時に参照。
- **gh-actions-cross-org-secrets** — cross-org reusable workflow で secret が消える確定知識 (ci-workflows#125〜#127)。`secrets: inherit` の境界判定は **run の repo org 基準**で、ohishi-exp run では明示受領済み secret も nested inherit で落ちる → 全 hop 明示転送が修正。値を出さない可視性 probe と「re-run は reusable sha を pin する」罠も収録。
- **auth-client-consume** — @ippoan/auth-client を Nuxt app で consume する時の subpath 使い分け (root は #imports 連鎖 / `/server` は .mjs+h3 / `/jwt` は framework-free) と「Nitro は node_modules の .ts を transpile しない」「publish は auth-worker の v* tag gate (ETARGET パターン)」等の罠 (#257 consumer 移行 6 repo で確定)。
- **identity-proxy-rollout** — ippoan Nuxt/Workers consumer を rust-alc-api#434 の dumb backend + proxy identity 注入モデルへ移行する playbook。createIdentityProxyHandler の 4 点セット (proxy route / wrangler AUTH_WORKER+INTERNAL_SHARED_SECRET binding / runtimeConfig / **test.yml use_auth_client_dev:true**) + frontend 移行。最重要 gotcha は「createIdentityProxyHandler が dev dist-tag のみ + committed lockfile で npm が tag 再評価せず古い版 (npm/cli#7562) → use_auth_client_dev で PR 時 overlay」。carins#38 / nuxt_dtako_logs#27 / alc-app#51 で検証済み。
- **gcp-cloud-run-routing-traps** — Cloud Run「Ready なのに外から 404」系の実測リファレンス (ippoan/cf-flickr-proxy#1 cutover で確定)。Google フロントは外部からの `/healthz` をインターセプトして汎用 404 を返す (= health endpoint は `/health` 標準)、404 は Google 汎用 / Cloud Run インフラ / アプリの 3 種を body で鑑別、新規 service の run.app hostname の GFE 配布ムラ、domain mapping の managed cert が HTTP-01 challenge の 302 で CertificatePending を長引かせる罠、MCP/手動 deploy の digest pin + per-secret IAM grant。
- **cores3-crash-triage** — alc-app-s3 (CoreS3 ハブ) の「画面が切れる/消える・落ちた」切り分け手順 + クラッシュログ基盤 (panic 前ログ .noinit リング → 復帰後 kind=crash_log → cf-alc-recorder が R2 `alc-crash-logs` 直書き + メール通知、backend へは流さない) のリファレンス。画面消失 A/B/C/D 切り分け表・R2/Observability 確認クエリ・dev ビルド (mem-hud) 配信・既知の罠 (nodejs_compat / ゾンビ WS 照会タイムアウト) を収録 (ippoan/alc-app-s3#43/#44)。
- **cf-access-staging-public-paths** — `*-staging.ippoan.org` を覆う CF Access app「staging-wildcard (allow me)」が明示 bypass 以外を全 gate するため「公開ページ (LINE/LINE WORKS webview の viewer 等) が recipient だけ読み込み中で止まる / 自分のブラウザでは見れる」非対称バグの特定+修正。ページ本体だけでなく `/_nuxt/*`・公開 API・backend が server→server で叩く internal path も bypass が要る。**reqwest 等が 302→cloudflareaccess login→200 を success 誤認する silent fail** (register-view が KV を書けてないのに warn も出ない) と `redirect(none)` ハードニングも収録。検証は必ず no-cookie curl。rust-alc-api#434 notify viewer で確定。
- **cf-builds-trigger-dns-loss** — production custom domain (trouble.ippoan.org 等) の DNS/証明書が突然消える事象の調査。`list_audit_logs` (cf-access-mcp) で Cloudflare Audit Log v2 API (`/logs/audit`) を引く実機の罠 3 点 (旧 v1 path は使えない、v1→v2 でクエリパラメータ名変更 `actor.email`→`actor_email` 等、**`since`/`before` が実は必須**で公式ドキュメントの「全 optional」と食い違う) と、「dashboard での Workers Builds trigger 付け外し操作 → 30〜60分後の別 worker deploy → 無関係な本番 custom domain が system actor に巻き込まれて削除される」というパターン (nuxt-trouble#185 と 2026-07-04 で 2 回観測) を収録。
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
- **claude-md-audit** — CLAUDE.md ダイエット (ippoan/claude-md#90) の監査ツール。`scripts/audit.sh` が org 全 repo の CLAUDE.md サイズを一斉検出し ≤50 行 / ≤2000 字 の超過を降順で列挙 (超過があれば exit 1 = CI gate 兼用)。閾値・exempt marker (`claude-md-size-exempt`) は claude-hooks の PreToolUse guard と ci-workflows の CI gate と共有。超過 repo は詳細を `<repo>-map` skill へ退避してダイエットする。
- **plan-with-fable** — コードを読んで詳細な実装計画と PR 分割を Fable に作らせる (`context: fork` + `fable-advisor` agent)。Issue の高レベル計画を実装可能なタスクに落とす段階で使う。使い方: `/plan-with-fable <課題 / Issue の内容>`。下記「Fable plan/review 開発ループ」参照。
- **review-with-fable** — 実装が終わった差分 (`git diff origin/main...HEAD` を skill 本文に注入) を Fable にレビューさせ、バグ・設計の綻び・テスト漏れを重大度順で返させる。下記「Fable plan/review 開発ループ」参照。
- **plan-with-opus** — Fable へのアクセスが無い環境向けの代替。`/plan-with-fable` と同じ実装計画タスクを `opus-advisor` agent (`model: opus`、`context: fork`) で行う。使い方: `/plan-with-opus <課題 / Issue の内容>`。下記「Sonnet→Opus 開発ループ」参照。
- **review-with-opus** — 同じく `/review-with-fable` の Opus 版。`git diff origin/main...HEAD` を `opus-advisor` agent に渡して重大度順のレビューを返させる。下記「Sonnet→Opus 開発ループ」参照。
- **subagent-orchestration** — CCoW の重コンテキストで sonnet サブエージェントを thrash させずに回す運用書 (親=Opus 向け)。再利用 agent 定義 6 種 (`.claude/agents/`: `planner`/`plan-reviewer`/`coder`/`code-reviewer`/`diet-worker`/`diet-reviewer`、全 sonnet・tools 限定・短ターン手順を焼き込み) を `agentType` で起動し、planner→coder→review の開発ループと diet-worker→diet-reviewer の CLAUDE.md ダイエットループを回す。「注入はセッション開始スナップショット=途中削除は空振り／短ターンなら full context でも survive」の実測知見と、wave 構成・親の検証チェックリストを持つ (設計: fable-advisor、ippoan/claude-md#90)。
- **repo-map** — 1 つの repo の構造ナビゲーション skill (`<repo>-map`) を作る/更新するメタ skill。`session-start-skill-coverage` hook が「skill 無し」/「鮮度切れ」を警告した repo に対し、ローカル ctags + 構造調査で map を起こし `generated-from: <repo>:<tree-sha>` を付ける。
- **auth-worker-map** — → **移設済み** (claude-skills#59 Wave 2)。本体は [`ippoan/auth-worker/.claude/skills/auth-worker-map/`](https://github.com/ippoan/auth-worker/blob/main/.claude/skills/auth-worker-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。

### per-repo map (`<repo>-map`)

`repo-map` メタ skill の手順で各 repo を索引化した構造ナビゲーション skill 群。frontmatter に `generated-from: <repo>:<tree-sha>` を持ち、`session-start-skill-coverage` hook が coverage と鮮度を点検する。基盤 5 repo (claude-md / claude-hooks / mcp-relay-rs / cc-relay / mcp-cf-workers) は `ippoan-infra-map` の `generated-from` で一括カバー。

- **AlcoholChecker-map** — 本体は [`ippoan/AlcoholChecker/.claude/skills/AlcoholChecker-map/`](https://github.com/ippoan/AlcoholChecker/blob/master/.claude/skills/AlcoholChecker-map/SKILL.md)。コードと同じ PR で更新され、skills-check CI が鮮度を見る。
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
- **dev-login-local-verify** — nuxt-dtako-admin をローカル `wrangler dev --remote` で prod backend に対して起動し、dev-login (auth-worker#423) を実機検証する手順。`setup-dev-env.sh` で worktree 作成〜起動を1コマンド化 (node_modules は junction 0秒 / gh auth token で npm install フォールバック)、`--hybrid` で nuxt dev 並走 = 編集→反映 0.1秒 (devProxy で binding 依存経路のみ wrangler へ転送)。named environment 不要 (`--var DEV_LOGIN:true` 一発)、`[build]` を除いた派生 config で起動 168秒→23秒、buildId 比較による hot reload 反映検知 (`reload-watch.mjs`、PostToolUse hook 登録可)、port 先住 workerd が旧バンドルで応答する罠、fragment handoff (auth-worker#442) 前提の SPA セッション確立、#token 残留の解消経緯 (auth-worker#445/#447、isReady では早すぎ afterEach が正解) まで収録。
- **wrangler-deploy-temporary** — `wrangler deploy --temporary` (Wrangler 4.102.0+) で認証不要の一時 Cloudflare アカウントに実 Workers edge へ即デプロイし、60分で自動失効する PoC ハーネス。外部サイトへの Workers egress 到達性検証 (WAF/datacenter IP ブロックの有無、実 colo 確認) に使う。デプロイ結果 URL は Cloudflare の JS challenge に守られるため curl では読めず、cdp-relay 等の実ブラウザ経由で読む。実 credential でのログインフロー検証は worker の HTML フォームに直接入力させ、cookie state を hidden field に往復させて再ログイン不要の探索 UI にするパターンも収録。
- **cdp-browser** — CDP 経由でブラウザを操作する (Tailscale 直結 port 9223 + Playwright)。
- **cdp-pair** — CCoW から手元 Chrome を cdp-relay (DO+WS リレー) 経由で操作するための pairing スキル。2 経路: **(A 推奨) chrome-devtools-mcp passthrough** — `browser_cdp_endpoint` の `pair_string` (mode=cdp) を popup に貼って手元 Chrome の browser-level 生 CDP を中継し、CCoW の `chrome-devtools-mcp` を `--wsEndpoint` で合流させて **全ツール** (network/perf/DOM/console) を効かせる (手元 Chrome を `--remote-debugging-port=9222 --remote-allow-origins=chrome-extension://<id>` で起動、`*` は使わない = デバッグポート乗っ取り対策)。**(B 軽量) curated** — `browser_pair` の pair_string で /ext 合流 → `browser_screenshot`/`navigate`/`eval` を直接呼ぶ (追加セットアップ不要)。UDP 封鎖 + NAT 越えが要る CCoW 向け (Tailscale 直結が通る環境は cdp-browser)。`RELAY_TOKEN` は会話に出さず短命 pair_code だけ渡す。`remote error`/1006 はまず token 失効を疑い再発行。
- **cdp-agent** — 手元 Windows に MSI で入れた `cdp-agent` (quick tunnel + MCP server + 拡張 long-poll、self-host 構成) 経由で CCoW から手元 Chrome を操作するスキル。拡張 popup の「接続用プロンプトをコピー」で渡された MCP URL (`https://<rnd>.trycloudflare.com/mcp`) に `scripts/cdp-call.sh` で curl tools/call し、`browser_navigate` / `browser_screenshot` を実行 (screenshot は /tmp に保存 → Read tool で確認)。cdp-pair (Worker+DO/WS) や cdp-browser (Tailscale 直) とは別経路。quick tunnel URL 揮発・extension not connected の gotcha 付き。実装: ippoan/cdp-relay#12。
- **web-review-flow** — draft PR レビューの統一フロー (SoT)。draft PR 作成 → cc-webreview-ext (手元 Chrome side panel + claude -p) で Web Review → `<!-- web-review -->` コメント → 購読中の CCoW が webhook 起床して「CCoW への引き継ぎ」チェックリストを処理 → **user が ready 化** → CI → auto-merge、の一本道。**draft か non-draft かは repo 単位で分ける: コード / 実行物 repo は draft 既定、ドキュメント配布 repo (claude-skills / claude-md) は non-draft 直行** (user 明示指示は常に優先)。draft の副作用 3 点 (staging deploy されない / prerelease は repo の draft gate 次第 — cc-webreview-ext は draft でも MSI を出す / draft 変換で auto-merge enable 解除)、受ける側の処理規約 (marker 検出・frugal reply・勝手に ready 化しない)、pr-chat-bridge / review-with-* との使い分けと PR コメント marker 一覧を収録。書式の SoT は cc-webreview-ext `host/prompts/review.md`。Refs #105。
- **pr-chat-bridge** — PR コメントを transport に CCoW セッションと Claude chat (Cowork / Desktop + Claude in Chrome) を連携させるブリッジ。CCoW がチェックリスト付き依頼コメントを投稿 → user が permalink を **Cowork (web 可) / Desktop に貼る** (通常 web chat には拡張ツールが生えないため `claude.ai/new?q=` プリフィルは不可、#196 trial で実証) → chat がブラウザ検証して結果コメント → webhook で CCoW が起床して処理。**auto-merge 既定の org なので draft PR (preview 導入 repo 限定、staging は draft で deploy されない) / merge 後 issue + send_later 回収の分岐**が肝。end-to-end 実証済み (ohishi-exp/nuxt-dtako-admin#196、2 往復成立 + preview ログイン全滅バグ発見)。Refs #102。
- **claude-in-chrome** — Claude in Chrome (Anthropic 公式 Chrome 拡張) の capability 棚卸しと cdp-pair / cdp-agent / cdp-browser との使い分けガイド。通常の UI 動作確認 (画面遷移・表示・クリック・コンソールログ・CF Access 配下の目視) は公式拡張 (Desktop / Cowork 経由) が pairing 不要で最速。cdp-relay が必要なのは httpOnly Cookie ログイン委譲 (`browser_cookies`)・ヘッダ/ボディ込み network 解析・生 CDP (perf trace 等) の 3 領域のみ。CCoW セッション自身は拡張を操作できない (ツール未 provision) ため「user に Desktop/Cowork でやってもらう」提案の判断基準も収録。実機検証: ohishi-exp/nuxt-dtako-admin#196。
- **egov-api** / **egov-spec** — e-Gov API ヘルパー。
- **bun-browser-verify** — CCoW で lib/SDK を deploy/publish せず **bun で実行**し、browser-only 認証 (CF Access cookie / SPA が握る短命 token / egress WAF で CCoW から直叩き不可) な API への**送受信だけ cdp 経由で手元ブラウザに肩代わり**させて、本番相当の構造/挙動検証を非破壊・高速に回す手法。「ビルド/署名は bun・認証付き IO はブラウザ」の分業ハーネス。token は `browser_eval` 内の `window` から読むだけで会話に出さない。`scripts/browser-eval.sh` (汎用 fetch 代理) + e-Gov 個別署名 Trial の worked example (`examples/egov/`、署名も `linkedom` global 注入で bun 再現) 同梱。`cdp-agent`/`cdp-pair` と組み合わせる。
- **ref-files-bulk** — ref-files MCP の `folder_download_url` で folder 配下を tar.gz で一括取得 → `/tmp/` に展開して通常の Read で読むスキル。`file_get` を 1 つずつ呼ぶ token 浪費を避ける。
- **ui-preview** — ビルド済み静的 UI 成果物を `ui-preview.ippoan.org` の DO へ publish し、別オリジン (workers.dev) の iframe で目視確認する preview URL を発行するスキル。tar.gz を直 PUT (MCP `create_preview` / `get_preview_stats` または直 curl)。親ページは WebSocket で publish を検知して自動更新、版は最後の publish から 10 分で自動削除 (ephemeral)。Nuxt/Vite は deep path 用に base 調整が要る (skill 参照)。「見た目を確認したい」「この画面どう見える？」等で使う。
- **mcp-user-setup** — Cloudflare Worker-native MCP server (`ref-files-worker /mcp` 等) を `~/.claude.json` の user-scope `.mcpServers` に手動 attach するスキル。CCoW では `session-start-write-mcp-user-scope.sh` hook が自動実行するため、ローカル dev / 別環境 / hook skip 時の手動 fallback。
- **create-cr-mcp** — Cloudflare Workers 上に新しい MCP server を `@ippoan/mcp-cf-workers` factory (`createWorkerMcp` stateless `/mcp`) を consume して新規構築する手順。binding_jwt 認証 (auth-worker introspect) + wrangler + CI/deploy + vitest 一式に加え、**claude.ai connector で実際に繋がる**ために必須の OAuth discovery 配線 (origin に `/.well-known/oauth-authorization-server` + `/register` + protected-resource を auth-staging へ proxy) まで含む。雛形は `mcp-cf-workers/examples/cf-access-mcp`。mcp-cf-workers#26 の接続解決知見を codify。
- **gmail-mcp** — gmail-mcp コネクタ (送信不可・下書きまでの Gmail remote MCP、ippoan/gmail-mcp) の使い方。Gmail の検索・本文取得・返信下書き・ラベル/アーカイブ操作をツール経由で行い、**送信は構造的に不可** (send 系ツール不在、TRASH/SPAM も拒否)。7 日失効 (テストモード) の再認証誘導 (`/oauth/start?alias=`)、マルチアカウント (`account` 引数)、メール本文の prompt injection への構えを収録。
- **eml-read** — `.eml` (RFC822 メール) を人間可読化するスキル。MIME ヘッダ (RFC2047 `=?UTF-8?B?...?=`) を decode し本文を charset 解決、添付を保存。PPAP (パスワード付き zip + パスワード別メール) の受領にも対応。`ref-files-bulk` で落とした `.eml` をそのまま Read すると読めないため、その前段で使う (相補的)。
- **nuxt-vitest** / **worker-vitest** — Nuxt / Workers 向け Vitest ハーネス。
- **local-first-testing** — org 共通テスト方針 (ippoan/claude-md#102) の実装レシピ。共有 fixture + golden テスト / 本番同種エミュレータ + seed (wrangler dev local = miniflare sqlite 永続化、docker-compose+migrate+seed.sql) / fixture→test→local目視→PR フロー。期待値の手計算と本番乖離 mock DB スキーマを禁止。
- **durable-object-worker** — Cloudflare Durable Object を no-traffic `versions upload` + Release Wave 運用で作る／切り出す手順。DO migration は versions upload を壊す (error 10211) ため、DO を別 worker に分離し app から **service binding** (external DO binding ではなく) で叩き、専用の `wrangler deploy` workflow で出す。class 削除の catch-22 (10061/10064)・deploy ordering・Node 22・coverage 100% gate・WS 検証を収録。reference: `ippoan/nuxt-items` + `nuxt-items-sync` (#290)。
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

## Sonnet→Opus 開発ループ (Fable 非アクセス環境向け代替)

Fable 開発ループと同じ「実装は安いモデルに任せ、判断が効く plan/review だけ上位モデルに切り出す」構成を、組織の Fable アクセスが無い環境向けに Opus で再現したもの。

| 段階 | 役割 | モデル | 手段 |
|---|---|---|---|
| 1. Plan (web) | 高レベル計画 → Issue 化 | 人 + web | issue-design |
| 2. 実装 Plan | コード読み → 詳細 plan + PR 分割 | **Opus** | `/plan-with-opus` |
| 3. 管理 + 実装 | タスク登録・管理 → 実装 | Sonnet (セッションのデフォルトモデル) | — |
| 4. Review | 差分レビュー | **Opus** | `/review-with-opus` |

両 skill は共有エージェント [`opus-advisor`](.claude/agents/opus-advisor.md) (`model: opus`、read-only、実装しない) を `context: fork` で起動する。fork は会話文脈を見ないため、review は `` !`git diff` `` 注入、plan は `$ARGUMENTS` への課題の明示渡し + 自前のコード読みで補う。`fable-advisor` との違いは `model:` フィールドのみで、SKILL.md の構造・呼び出し方は完全に対称。

### Fable 版との使い分け

- 組織に Fable アクセスがある場合は `plan-with-fable` / `review-with-fable` を優先する (1M context で大規模リポジトリの実装 plan を読ませやすい)。
- Fable アクセスが無い、または `opusplan` env を別途設定していないセッションでは `plan-with-opus` / `review-with-opus` を使う。段階 3 の実装は `opusplan` のような自動切替を前提とせず、セッションのデフォルトモデル (Sonnet) でそのまま進める。

### 前提条件

- Claude Code から Opus が利用可能であること (Opus 4.8 等)
- `CLAUDE_CODE_SUBAGENT_MODEL` が**未設定**であること (設定済だと agent の `model: opus` を上書きする)
- CCoW では agent / skill ともリポジトリにコミットして使う (`~/.claude` は不可)
- コスト注意: 1 ループで Opus を最低 2 回 (plan + review) 呼ぶ。要所限定の運用前提

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
