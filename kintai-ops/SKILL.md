---
name: kintai-ops
description: 勤怠 (kintai) まわりを 3 repo 横断で触るときの運用知識。rust-ichibanboshi / nuxt-dtako-admin / rust-alc-api の PR 作法・親子通信・勤怠 Worker の測定手段・カバレッジ 100% gate・踏み抜き済みの罠を 1 枚にまとめる。kintai / 勤怠 / 打刻 / 月ゲート / fold / unko_diff / day_summaries / dtako / デジタコ / alc / 運行NO / 拘束時間 / 乗務員 / 読取日 / スクレイプ を扱うタスク、およびこの領域の子タスクとして起動されたセッションは着手前に必ず読む。
---

# kintai-ops — 勤怠まわりの運用知識 (3 repo 横断)

**子タスクの prompt から切り出した共通部分**です。起動 prompt には
「目的・受け入れ条件・座標 (どのファイルの何行)」が書かれます。**作法・測定手段・罠は
全部ここにあります。着手前に通して読んでください。**

**★ ここに issue 固有の数字や進捗を書かないこと。** issue が閉じた瞬間に腐り、
issue ごとに skill が増えていきます。**置くのは「その issue が終わっても生きる知識」だけ。**

| 種類 | 置き場所 |
|---|---|
| 作法・測定手段・罠 (恒久) | **ここ** |
| いまの数字・進捗・決着した事実 | memory (`~/.claude/projects/-home-claude-claude260730/memory/`) と GitHub issue のコメント |
| 走行中タスクの受け入れ条件 | §7 の台帳 |
| repo の内部構造 | 各 repo の `<repo>-map` skill |

## ★ 前提: 作業 PC (ローカル) 専用

**この skill もタスク台帳も、作業 PC のファイルシステムにしか存在しません。**
Cowork / remote / スケジュール実行のセッションからは**読めません**。また
§4 の測定口 (kyuyo-mcp の tool・ログイン済みブラウザから叩く relay の口) は、
**その connector やブラウザを持たないセッションからは届きません。**
勤怠 Worker の口そのものは Service Binding でしか呼べず、手元から直接は叩けません (§4)。

**★ フォルダが無いときの切り分け (これを間違えると静かに事故ります)**

`/home/claude/claude260730/tasks/` は「**決着したら親が消す**」運用なので、**無いことに
意味を持たせたくなります。持たせないでください。**

| 見えたもの | **正しい読み** |
|---|---|
| `tasks/` フォルダごと無い | **作業 PC ではない (Cowork / remote)。** 環境の問題であって、タスクの状態ではない |
| フォルダはあるが自分のファイルが無い | 親がまだ作っていないか、既に消した。**親に聞く** |

**「自分のファイルが無い ＝ このタスクは終わっている / 条件は無い」と解釈しないでください。**
`/home/claude/claude260730/` に 3 repo (`rust-ichibanboshi` / `nuxt-dtako-admin` /
`rust-alc-api`) が並んでいるかを見れば、作業 PC かどうかは 1 回で分かります。

- **受け入れ条件の正本は起動 prompt です。** 台帳 (§7) はその写しで、親が突合するための
  ものです。**台帳が読めないことは、条件が無いことを意味しません**
- **この skill や台帳が見当たらない環境で走っていると気づいたら、推測で埋めずに
  親へ `[質問]` を投げてください。** 「読めなかった」と言われる方が、読めていない
  作法で作られるより桁違いに安いです
- 測定が必要なタスクをリモート環境で受け取ったら、**そこで測れないことを先に報告**して
  ください。届かない口を叩いて「0 件だった」と結論するのが最悪の分岐です
  (§6 の「検索して 0 件」と同型)

## 0. この領域は何か

社内 MariaDB の**打刻**とデジタコ (**dtako**) を Supabase (GCP) に畳んで持ち、勤怠を再計算する
仕組み。3 repo にまたがる:

| repo | 役割 |
|---|---|
| `ohishi-exp/rust-ichibanboshi` | **勤怠の計算ロジック本体** (fold / 月ゲート / 突合) = `workers/kintai` の **勤怠 Worker** (Cloudflare Worker)。社内 MariaDB (読むだけ) と社内 CakePHP (取り込み・勤務時間再登録) へは勤怠 Worker が Workers VPC で届く。一番星は `workers/ichiban`、root はリモートデスクトップの中継 (rdp-relay) だけ |
| `ippoan/rust-alc-api` | デジタコの生データを渡す基盤 (運行の列挙 / R2 の CSV / etags) |
| `ohishi-exp/nuxt-dtako-admin` | 取り込み (スクレイプ / CSV 分割 / relay) と管理画面 |

**いまの数字と進捗はここに書きません** (上表のとおり memory と issue が持ちます)。

**★ 症状だけでは処方が決まりません。** 「行が N 行足りない」は原因が複数あり、処方が
全部違います (窓の外に落ちた / 乗務員が付いていない / MariaDB の行が古い / 元データが
編集された)。**原因を確かめる前に処方 (取り直し等) を当てにいくのが、この領域で最も
時間を溶かす動きです。**「行が足りない」「値が違う」は症状であって診断ではありません。

## 1. ★ PR = 本番行き。子は branch push まで

| repo | 引き金 |
|---|---|
| `ohishi-exp/rust-ichibanboshi` | **PR 作成** で CI green → auto squash merge (`ci.yml` の `auto-merge` job)。本番への出方は対象ごとに違う (下表) |
| `ippoan/rust-alc-api` | **PR 作成** (auto merge + auto tag + auto flip) |
| `ohishi-exp/nuxt-dtako-admin` | **PR 作成** (auto merge → auto flip) |

(`rust-alc-api` / `nuxt-dtako-admin` の行は下の実測時点の記述。今の `on:` は再確認していない — 要確認)

`ohishi-exp/rust-ichibanboshi` の中の分かれ方 (2026-10-15、`.github/workflows/` の `on:` で確認):

| 対象 | 本番に出る引き金 |
|---|---|
| `workers/kintai` (勤怠 Worker) | **tag `worker-kintai-v*` の push** (`worker-kintai.yml`)。**merge では本番に出ない** |
| `workers/ichiban` (一番星) | **tag `worker-ichiban-v*` の push** (`worker-ichiban.yml`) |
| root の rdp-relay | **main merge** で `ci.yml` の deploy job がオンプレへ |
| Supabase の勤怠 migration (`migrations/`) | **main merge** で `ci.yml` の `kintai-migrate` job が本物に当てる |

`tag-release.yml` は `workflow_dispatch` のみ。worker の tag は merge では打たれない
(打つのは人。自動で打つ経路が他に無いかは、タグを当てにする前に確かめること)。

**「PR を出してから merge するか考える」ができません。出す = 出る。**

**★ ただし merge = 本番反映ではありません。** 引き金は **repo ごと・同じ repo の中でも
worker ごと**に違い、tag や flip が要る系があります。**Actions の run 名と conclusion
だけで「deploy 成功」と判断しないこと** — 同じ workflow が staging にも prod にも
使われます。見るのは **「どの branch/tag の push で `wrangler deploy` に `--env` が
付いたか」**です。

実例 (`nuxt-dtako-admin`、2026-08-01):

| 対象 | 引き金 | 出先 |
|---|---|---|
| `dtako-scraper-relay` (DO worker) | main push / PR | **staging** (`--env staging`) |
| 同上 | **tag `v*` push** | **production** |
| `kyuyo-mcp` | main push | **production** (single-env) |
| app 本体 | Release Wave の flip | 切替で反映 |

### ★★ `nuxt-dtako-admin` は **タグが自動で打たれる** — 上の表を「マージは安全」と読まないこと

**2026-08-04 に親がこの表を読んで「マージは staging 止まりだから、走行中の取り込みがあってもマージしてよい」と判断し、誤った** (幸い実害ゼロ)。**実測:**

```
01:56:01Z  PR merged
01:56:04Z  main push        → relay deploy (--env staging)
01:56:21Z  v0.0.357 が自動生成   ← ★ 誰も手で打っていない (20 秒後)
01:56:21Z  タグ push        → relay deploy (本番)
```

`git log v0.0.356..v0.0.357` = そのマージ 1 コミットだけ。**`.github/workflows/tag-release.yml` は `workflow_dispatch` のみ**なので、自動タグを打っているのは **auto-merge の reusable workflow (`ippoan/ci-workflows`) 側**。

**⇒ この repo では実質「マージ = 本番 deploy」。** 上の表は「どの push がどこへ出るか」としては正しいが、**「その push を誰が起こすか」を書いていないので、マージの安全性の判断には使えない。**

**教訓 (一般形): deploy の安全性を判断するときは、workflow のトリガー条件だけでなく
「その push / tag を誰が起こすか」まで確かめること。** トリガーだけ読んで「安全」と
結論すると、読まなかった範囲で外す。

**★ `rust-alc-api` も実質「マージ = 本番」** (2026-08-29 実測で訂正)。
機構としては `v0.0.*` タグ + Release Wave だが、**そのタグをマージのたびに CI が自動で打つ**。
実測: `v0.0.137`→`e31d4c5` / `v0.0.136`→`5df8b03` / `v0.0.135`→`3c22224` /
`v0.0.134`→`2f9c3a1` と、**直近 4 タグが main の直近 4 commit に 1:1** で対応。
#600 のマージ (00:12) → `Tag Release` 自動実行 → タグ push → **`release-wave-flip` が
00:24 に success**。**「タグ待ちだからまだ本番に出ていない」は誤り。**

⇒ **上の nuxt-dtako-admin と同じ注意がここにも効く**: 機構 (どの push がどこへ出るか) を
読んでも、**その push を誰が起こすか**を確かめないと、マージの安全性は判断できない。
migration の本番適用は **CI のジョブが success になった時点**であって merge 時点では
ありません。

- **`gh pr create` を実行しないでください。** 子セッションでは classifier に拒否されます
- **branch push まで**やって親に報告 → **PR は親が作ります**。
  **★ ただし `ippoan/rust-alc-api` / `ippoan/alc-app` は feature branch の push で CI が
  1 本も回りません** (workflow が `on: push: branches: [main]` + `pull_request: branches: [main]`
  のみ。`alc-app` の `skills-check.yml` に至っては `pull_request` だけ。2026-09-04 実測)。
  **PR を出した時点が初検証**になるので、子は**「CI 未実施」と明記して**渡し、手元で回せるもの
  (`cargo test --test <bin> -- <filter>` / `cargo fmt` / `cargo clippy`) の結果を添えること。
  **coverage gate と skills-check も PR でしか動きません。**
  (`ohishi-exp/nuxt-dtako-admin` は別で、main 以外への push で preview が出る = §1 の repo 固有を参照。
  `ohishi-exp/rust-ichibanboshi` は `ci.yml` が `fix/**`・`feat/**`・`claude/**` 等の branch push でも走るが、
  `worker-kintai.yml` / `worker-ichiban.yml` (workers の test と 100% gate) は PR と main push だけ — 2026-10-15 確認)
- 唯一のブレーキは CI です

repo 固有:

- **`ippoan/rust-alc-api` は同一作者の open PR が 1 本まで** (2 本目は PR Limit Check で落ちる)。
  **`crates/` / `src/` / `migrations/` を触ったら同じ PR で map 再生成** (map-check は enforce=fail)。
  **マージ = 実質本番** — `v0.0.*` タグを CI が自動で打ち、Release Wave が flip する (上の訂正を参照)
- **`ohishi-exp/nuxt-dtako-admin` は root の `npm install` が通りません** (`@ippoan/*` が
  GitHub Packages)。front は CI が初検証、relay worker だけローカルで回ります
  - **★ front の実機確認は、まず preview を見てください。ローカル dev を立てる前に。**
    この repo は **main 以外への push で preview が自動デプロイ**されます
    (`.github/workflows/preview-deploy.yml` の `on: push: branches-ignore: [main]` →
    `wrangler.toml` の `[env.preview]` = **`https://dtako-preview.ippoan.org`**)。
    **push した時点で自分のコードが動いているので、npm install も dev 起動も要りません。**
  - ローカル dev (`setup-dev-env.sh --here --hybrid`) は **`read:packages` scope が要ります**。
    無いと `npm install` が `permission_denied` で止まり、`gh auth refresh -s read:packages`
    は**分類器に弾かれることがあります** (2026-08-03、#615-7 で子が完全に停止した)。
    ⇒ **preview で足りる用件にローカル dev を使わせないこと。**
  - **ただし preview は Cloudflare Access の背後**なので、**入るには人の手が要ります**
    (エージェントはログインを代行できません)。**画面を見る人を確保してから頼むこと。**

## 2. 親子通信

親のタイトルが宛先です。`mcp__ccd_session_mgmt__list_sessions` でタイトル一致から
sessionId を引き、`mcp__ccd_session_mgmt__send_message` で送ります。
**sessionId を prompt に埋めてはいけません** (scratchpad の UUID も
`~/.claude/sessions/*.json` の `sessionId` も別物で `not found` が返る)。

送るタイミング:

1. **着手時** — 何をどう進めるか
2. **仮説が固まったら** — 実装前に必ず
3. **設計判断に迷ったら `[質問]` を付けて** — 前提が崩れたら**止まって聞く**。無理に作らない
4. **branch push 完了時** — branch / commit SHA / 触ったファイル / 実データで叩いた結果 /
   **受け入れ条件に 1 対 1 で答えた形**

**★ `isRunning: false` は当てになりません。** 親が停止中に見えても諦めず送ってください。
`lastActivityAt` も遅れます。

作法の本体は `~/.claude/skills/report-to-parent` にあります。

## 3. ★ 子への行動規範 (これが一番効いています)

**この issue では、子が親の誤りを 2 日で 12 回止めました。** うち 2 回は、そのまま作って
いれば「常に嘘をつく診断」と「キー正規化問題の再生産」が本番に出ていました。
**12 回とも「言われたとおりに作らなかった」から止まりました。**

- **結論を親に寄せないでください。** 一致しないなら「一致しない」と書く。合わない結果こそ価値がある
- **前提が成り立たないなら、親の指示でも作らないでください。** 止まって `[質問]` を投げる
- **仮説は falsifiable な形で先に宣言してください。** 予想を書かずに作ると、外れたときに
  「壊した」のか「元からそうだった」のかが区別できません。直近は 5/5 的中しました

**親の推測も間違います。** prompt に書かれた親の作業仮説は、疑ってよい対象です。

## 4. ★ 測定手段 — 勤怠 Worker の口と kyuyo-mcp の tool

**勤怠 Worker (`ichibanboshi-kintai`) の口は Service Binding を持つ Worker からだけ呼べます。**
手元から `curl` で直接叩く経路はありません。測るときは **kyuyo-mcp の tool** か、
**ログイン済みブラウザから relay の口** (`dtako.ippoan.org` の `/restraint-api/kintai/*` 等) を使います。
口の一覧と応答の形の正本は `rust-ichibanboshi` の `workers/kintai/README.md` です。

| 勤怠 Worker の口 | 読む / 書く先 | kyuyo-mcp の tool | 経路 |
|---|---|---|---|
| `GET /api/kintai/events` (driver 必須) | 社内 MariaDB | `get_kosoku_events` | kyuyo-mcp → 勤怠 Worker (直) |
| `GET /api/kintai/rest-diff` | 社内 MariaDB | `get_rest_diff` | 直 |
| `GET /api/kintai/kosoku-daily` (+ CakePHP 中継の `pdf-json`) | 社内 MariaDB / 社内 CakePHP | `get_timecard_diff` (紙 = `pdf-json` との比較) | 直 |
| `GET /api/kintai/kosoku-daily` ↔ Supabase の `day_summaries` | 両側 | `get_kintai_diff` | MariaDB 側は直、GCP 側は relay (`/kintai-relay/{day-summaries,shift-overlaps}`) |
| Supabase の `day_summaries` | Supabase | `get_kintai_day_summaries` | relay (`/kintai-relay/day-summaries`) |
| `GET`/`POST /api/kintai/recalc` (fold) | Supabase + auth-worker | `run_kintai_recalc` | relay (`/kintai-relay/recalc`) |
| `POST /api/dtako/autoload` (② と ③) | 社内 CakePHP (+ ③の材料は MariaDB で数える) | `run_dtako_reimport` | relay (`/kintai-relay/dtako-reimport`) |
| `PUT /api/restraint/summaries`・`GET /api/restraint/{wage-source,synced-months}` | D1 | `run_kintai_restraint_sync` 等 | relay |
| `GET /api/kintai/reading-dates` | 社内 MariaDB | **tool なし** | relay が内部で使う (画面の読取日まわり)。直接測るには新しい tool が要る |
| `GET /api/kintai/tail-gap-probe` | 社内 MariaDB | **tool なし** | 新しい tool が要る |
| `GET /api/kintai/day-events`・`GET /api/dtako/worktime` | 社内 MariaDB | **tool なし** | relay の `/restraint-api/kintai/day-events-lookup` (画面の「day-events で23桁を引く」) |
| `GET /api/kintai/unko-gaps` | Supabase + alc etags | **tool なし** | relay の `/restraint-api/kintai/unko-gaps` (画面) |
| `GET /api/kintai/version`・`timecard/*`・`stale-months` ほか | — | **tool なし** | relay / 画面 / 新しい tool |

(2026-10-15 時点の `nuxt-dtako-admin/workers/kyuyo-mcp/src/mcp/tools.ts` で確認。tool の増減は
そちらが正。`get_wage_report`・`get_restraint_summary` は勤怠 Worker を読まない — 下記)

- **「tool なし」の口を「0 件だった」と読まないこと。** 叩けていないだけです。届かない口で
  0 件と結論するのは §6 の「検索して 0 件」と同型の失敗です
- **新しい口を足しても、tool が無ければ測れません。** 測る手段 (tool か relay の口) まで同じ
  作業に含めるか、先に親へ `[質問]` で「測れない」ことを伝えること
- **到達性は応答で確かめる。** 勤怠 Worker が社内 MariaDB / CakePHP に届かないときは 502 / 503 に
  段と種別 (`stage` / `kind`、`MariaDB query failed: <段>:<種別>` 等) が出ます。config を読んで推論しない

**★★ GCP 側の「拘束の内訳 (どの時刻からどの時刻までを拘束と見たか)」を覗く口は無い** (2026-08-04 確認)。

| 口 | 返るもの |
|---|---|
| `get_kosoku_events` | **社内 MariaDB の `dtako_events` だけ** (勤怠 Worker の `events`)。GCP 側は 1 行も返らない |
| `get_kintai_day_summaries` | **集計値のみ** (`restraint_minutes` 等)。区間レベルの内訳は無い |
| `get_kintai_diff` | 両側の集計値。内訳は無い |

**⇒ 「GCP が何を見てその数字を出したか」は現状わからない。** 両側の集計値が食い違う原因を
最後まで詰めるには、**勤怠 Worker (`rust-ichibanboshi/workers/kintai`) に診断用の口と、それを測る tool を足すしかない**
(ファイル名・ソースを触っても勤怠の版 `logic_version` は変わらない (etag は変わる)。§5 参照)。

**★ `get_restraint_summary` を GCP のライブ値と混同しないこと。** これは**給与比較アーカイブ**で、

- **第三の値**を返す (`day_summaries` とも MariaDB 由来の値とも違う数字が出ることがある)
- **`fetched_at` / `last_verified_at` が数週間前**のことがある (定期エクスポートのスナップショット)
- **暦日 (day5/day6) ベース**で、`day_summaries` の `乗務員CD|暦日|開始時刻` (シフト境界ベース) とは**軸が違う**

**⇒ 差の調査に使わない。** 使うと存在しない第三の乖離を追いかけることになる。

### ★★ `get_wage_report` (MCP) と 画面の「拘束×賃金」は**別ソース**。突き合わせるな (2026-08-04 実証)

**同じ会社・同じ月・同じ乗務員なのに値が違う。** どちらかが壊れているのではなく、読む先が違う:

| 経路 | 読む先 |
|---|---|
| **MCP `get_wage_report`** | **R2 の給与比較アーカイブ** (`loadMonthSummaries` → `restraint/{comp}/…`)。上の `get_restraint_summary` と同じスナップショット |
| **画面 `/restraint-api/wage-report`** | **relay 経由のライブ** (`loadWageReportSource` = 勤怠 Worker の `GET /api/restraint/wage-source` (D1) + 打刻の live-build) |

同じ乗務員の実働が数時間ずれることがある。**MCP の値で画面の異常を否定してはいけない。**
`get_restraint_summary` への注意 (アーカイブでありライブではない) は **`get_wage_report` にもそのまま当てはまる。**

**⇒ 画面の数字を検証したいなら、画面と同じ口を叩く。** ブラウザから直に取れる (下記)。

### ★ 画面と同じライブ値をブラウザから取る (認証込み、2026-08-04 確立)

`claude-in-chrome` でログイン済みタブから叩く。**認証は `localStorage.logi_auth` の Google JWT** —
`theearth-session` の token は**期限切れでも画面は動く** (401 になるのはこちら) ので、
`theearth-session` を使うと 401 で詰まる。`authHeaders()` (`restraint-wage.vue`) の実装が正:

```
X-Theearth-Comp-Id: <compId>
X-Theearth-User-B64: base64url("viewer")
Authorization: Bearer <logi_auth の accessToken>
```

**fetch を含む JS は 1 分半ハングして返らないことがある** (§4.8) ので、
**`window.__x` に結果を置いて即 return → 別呼び出しで読む**の 2 段にする。

**表の実値は DOM から直接読むのが確実** (集計済みの表示値がそのまま取れる):

```js
[...document.querySelectorAll('tr')]
  .find(tr => tr.querySelector('td')?.textContent.trim() === '<乗務員CD>')
  ?.querySelectorAll('td')  // → [CD, 氏名, 実働, 基本給, …, 差分, …]
```

### ★★ 最低賃金チェックの「差分 (実働 − 表合計)」は **0 が恒久的な不変条件** (ユーザー明言)

0 でなければ**本物の不整合**。「別ソースだから」「まだ畳んでいないから」で流さないこと。

**★ 2026-08-04 の実例**: 「拘束時間ソース」を **`GCP (day_summaries)` に切り替えた時だけ**
差分が -10h〜-28h になった (現行ソースでは 0)。真因は `overlayGcpDayTimes`
(`gcp-day-summaries.ts`) が `summary.days` の**同じ暦日の重複行すべてに同じ GCP 値を割り当て**、
1 日ぶんが二重計上されていたこと (月合計は暦日ユニークな `inMonth` から出すので重複しない = 非対称)。
**見つけ方**: 過大分を区分ごとに出す → その和と一致する 1 日を GCP の日別から探す →
`summary.days.length` が月の日数を超えていないか見る (実例: 2026年6月なのに 31)。

**★ MCP tool の登録はセッション開始時のスナップショットです。** `ToolSearch` は
スナップショットの中を検索するだけですが、**セッション開始時から設定済みの connector は
接続が終わると遅れて一覧に現れます (実測 2026-09-12)。1 回見えないだけで「無い」と決めない**
([[parent-fanout]] の罠)。**自分で足した tool は自分では呼べません。** 見えない tool が
あったらユーザーに connector 追加を頼むのが最短です (走行中のセッションにも入ります)。

管理画面 `https://dtako.ippoan.org` — 運行一覧 / スクレイプ (読み取り日ベースのカレンダー) /
アップロード。ブラウザから `/api/proxy/api/operations/{22桁の運行NO}` で
`reading_date` / `operation_date` / `has_kudgivt` が引けます。

## 4.5 ★ 認証と到達性 — どこから何に届くか

**「サーバ側で自動化できるか」は、毎回ここで決まります。** 思いつく前に表を見ること。

| 相手 | 認証 | 誰が届くか |
|---|---|---|
| **勤怠 Worker** (`ichibanboshi-kintai`) | Service Binding (呼び手の Worker が binding を持つこと)。書き込みの口 (`POST /api/dtako/autoload` 等) は **`X-Kintai-Write-Token`** も要る | relay / kyuyo-mcp (binding 経由)。手元からは直接届かない |
| **社内 CakePHP (nginx)** | **`view` / `autoload` など主要 action は `AppController::beforeFilter` の `addUnauthenticatedActions` で認証免除**。ただし **CakePHP の CSRF は別**で、フォームに `_csrfToken` があり **対の cookie は HttpOnly** | **勤怠 Worker が Workers VPC で届く** (`KINTAI_CAKEPHP_VPC`)。他の Worker からは勤怠 Worker を通す |
| **社内 MariaDB** | 勤怠 Worker の資格情報 (secret) | **勤怠 Worker が Workers VPC で届く (SELECT だけ)** |
| **`dtako.ippoan.org` (nuxt SPA)** | **要る。token は `localStorage`、サーバ側 DO の TTL 8h** (`useTheearthSession`)。`authHeaders()` が読む | **relay / kyuyo-mcp は自前で theearth にログインできる** (`DTAKO_ACCOUNTS` を KV に持つ) |

**⇒ 社内側 (MariaDB・CakePHP) へ届く主体は勤怠 Worker だけ。** relay / kyuyo-mcp はそこを通す。

- **社内 CakePHP の `pdf-json` (勤怠 PDF の元 JSON) は勤怠 Worker の `GET /api/kintai/pdf-json` が中継する**
  (kyuyo-mcp の `get_timecard_diff` が読む。画面からは relay の `/restraint-api/kintai/pdf-json`)。
  relay の `timecard-compare` の fixture (`workers/dtako-scraper-relay/test/fixtures/pdf-json-*.json`) は
  この応答を 3 名 × 数日に間引いたもの (repo 側のコメントからは nuxt-dtako-admin#1073 で手順を伏せ、ここが正本)
- **token を URL に載せる案は成立しません** — localStorage にあり 8 時間で失効し、履歴とログに残る
- **CSRF cookie が HttpOnly** なので、**フォーム投稿はそのページを開いたブラウザからしか通りません**。
  サーバ側から投げようとすると CSRF を迂回することになるので、やらない
- **ブラウザ操作 (claude-in-chrome) が使えるなら、それが最短**。認証も CSRF も
  ブラウザが持っているものをそのまま使えるので、資格情報をどこにも移さずに済む

**★ 社内側に secret を置くのは不可** (2026-08-01 オーナー判断)。
資格情報は Cloudflare 側 (relay・勤怠 Worker) に持ち、社内側へは **Worker から VPC で届く方向**にする
(拘束サマリの `PUT /api/restraint/summaries` も relay → 勤怠 Worker (D1) の push)。

## 4.6 `unko_no` の桁が MariaDB 由来と GCP で違う

**社内 MariaDB 由来は 23 桁、GCP (alc 由来) は 22 桁**で、突合は先頭 22 桁で当てています
(`unko_diff_trials` の `prefix22`)。**社内 CakePHP の URL キーは 23 桁**なので、
**リンクを作れるのは MariaDB 由来の値だけ**。22 桁を混ぜると存在しない運行を指します。

## 4.7 ★ ずれた値を直す導線 (3 段。どこが誰の担当かが毎回問題になる)

```
① csvdata.zip を取る       theearth        relay が DTAKO_ACCOUNTS で自前ログインできる
② 社内 CakePHP へ取り込む   autoload        勤怠 Worker が VPC で中継 (POST /api/dtako/autoload)
③ 勤務時間再登録            resetbyUnkoNo   勤怠 Worker が②の後に打つ (reset_timecard=true) / 人が画面のボタンを押す
```

### ② の口 (`POST <社内 CakePHP>/dtako-events/autoload`)

勤怠 Worker の `POST /api/dtako/autoload` がこの口を中継する (`X-Kintai-Write-Token` 必須)。
以下は CakePHP 側の挙動。

- **認証もCSRFも免除済み。** `AppController::beforeFilter` の
  `addUnauthenticatedActions` に `autoload`、**`Application.php` の CSRF ホワイトリストにも
  `['controller' => 'DtakoEvents', 'action' => 'autoload']`** がある。
  **⇒ 迂回ではなく、正規にサーバから POST できる**
- **★ MIME 決め打ち。** `getClientMediaType() === "application/x-zip-compressed"` でしか
  受けない。**`application/zip` で送ると展開もエラーも出ず黙って無視される**
- **★「1 回の POST で最大 18 回走る」は誤り (2026-08-03 訂正、実コードで確認)。**
  `for ($i=1;$i<10;$i++)` は 2 箇所あり**ループ自体は 9 回ずつ回る**が、
  **実際に取り込むのは最初の 1 回だけ**。`_autoload` は先頭で対象 CSV を
  `dtako_csv/tmp/` へ `rename` するので、2 回目以降は `$vv->isWritable()` が
  false になり foreach の中身ごと skip される (= 実質 no-op)。
  `usleep(3000)` は zip 展開待ちの `do..while` にあるもので、取り込みの繰り返しではない。
  **timeout 120 秒は安全側の余裕であって、期待所要時間ではない。**
  ⇒ 所要時間を「18 × 1 回の取り込み」で見積もらないこと (この誤読で
  「同期ボタンは成立しない」と誤って設計しかけた)
- **前ループ (zip 展開前) は 0 回か 9 回のどちらか。** `$ddir` がループの外で 1 回だけ
  `glob` され、中で更新されないため条件が不変。ディレクトリが空なら 0 回
- **zip 無しで叩くとディレクトリに残った CSV を再取り込みする** (`$file` を見る前に
  `glob` して取り込む)。**local 前提の意図的な許容**であって欠陥ではない (オーナー判断)

### ③ は POST + CSRF でリンクにできない

`resetbyUnkoNo` は `$this->Form->postLink(...)` で、**CSRF ホワイトリストに入っていない**。
**GET リンクにはできない。** `Flash` と `?redirect=` は実装済みなので、押せば index へ戻る。

### ★ 2026-08-01 完成: `run_dtako_reimport` (MCP) 1 本で①②③が通る

```
run_dtako_reimport { comp_id, ope_no_22, start_ope, unko_no, reset_timecard? }
  → relay が theearth から zip 取得 (自前ログイン) → 検証
  → 勤怠 Worker の POST /api/dtako/autoload へ → 社内 CakePHP へ取り込み (②)
  → (reset_timecard=true なら) 勤怠 Worker が MariaDB で材料を数えてから勤務時間再登録 (③)
```

**モデルは base64 を運ばない** (以前は書き写して壊れていた)。
**`uncertain: true` が返ったら同じ引数で再実行しない** — 取り込みは応答より前に走る。

### ★ `unko_no` は「取り込み先の鍵」ではない (2026-08-04 実コード確認・tool 説明が誤り)

**`reset_timecard: false` では、取り込む中身を決めるのは zip (`ope_no` + `start_ope`) で
あって `unko_no` ではない。** `unko_no` は「1 件に紐付ける歯止めと監査ラベル」でしかない
(`dtako-reimport.ts` の `UNKO_NO_RE` の doc comment)。**23 桁目 (対象CD) が意味を持つのは
`reset_timecard: true` (③ `resetby-unko-no/{unko_no}`) のときだけ。**

**⇒ 2マンの運行でも 22 桁 1 本の投入で主・助手の両方が入る。`…1` と `…2` を 2 回呼ぶ必要は無い**
(`run_dtako_alc_upload` の応答 `operations_count: 2` で実証)。**これは `run_dtako_reimport` /
`run_dtako_alc_upload` の両方に当てはまる。**

**★ `kyuyo-mcp` の `run_dtako_reimport` の tool 説明「`unko_no` は取り込み先を名指しする鍵で、
間違えると別の運行に取り込む」は `reset_timecard: false` には当てはまらない。**
`true` についてだけ正しい説明が、両方に効くかのように書かれている。**これで実作業が 1 回止まった。**
tool 説明を読んで迷ったら、この節と `dtako-reimport.ts` の実コードが正。

### ★ 応答の `theearth_logins` / `theearth_kicked` を見る (2026-08-04 追加)

`run_dtako_reimport` / `run_dtako_alc_upload` / `get_operation_zip` の応答に載る。

- **`theearth_logins`** — その呼び出しで theearth にログインした回数。**DO インスタンス内で
  セッションを使い回すので、間を空けずに続けて叩けば 2 回目以降は `0` になる** (実測確認済み)
- **`theearth_kicked`** — 誰かのセッションを蹴ったか。theearth は同一アカウントの同時ログインを
  許さないので、ログインは常に誰かを蹴りうる。**`true` が続くなら人が使っている可能性を疑う**

**`run_dtako_alc_upload_driver` の応答には `theearth_logins` も `theearth_kicked` も
無い** (実測)。この節は上の 3 tool 限定。

**★ ②と③は書く先が違う (2026-08-04 追加)。ここを混同すると診断を外す。**

| | 書く先 | 効果 |
|---|---|---|
| **②** (`reset_timecard=false`) | **`dtako_events`** | 勤怠の値は動く (`kosoku-daily` は `dtako_events` の休息から計算するため) |
| **③** (`reset_timecard=true`) | **`time_card_dtako`** | 運行NO を持つ行を作り直す |

**取り込み漏れ候補の判定は `time_card_dtako` しか見ない** (`MONTH_OPERATIONS_SQL` の
`PUSHED_SOURCES = ["timecard","dtako"]`。`dtako_events` は入らない)。
⇒ **②だけを打っても候補一覧からは消えない。** 値が直っても候補に残るのは正常。

### ★★★ ② だけでは GCP に届かない — ③ を呼ばないと反映されない (2026-08-04 実証)

`PUSHED_SOURCES` (`timecard` / `dtako`。今の定義は `rust-ichibanboshi` の
`workers/kintai/kosoku/src/kintai_push.rs`) が **GCP の fold の入力**を絞る。
`dtako_events` (デジタコ生イベント) はここに入らない。

| | 読む先 | 更新するのは |
|---|---|---|
| **MariaDB 由来** (勤怠 Worker の `kosoku-daily`) | **`dtako_events`** | **② (`reset_timecard: false`)** |
| **GCP** の fold | **`time_card_dtako` 由来 (`dtako` source)** | **③ (`reset_timecard: true`) だけ** |

**⇒ `reset_timecard: false` の取り込みは `dtako_events` しか書かず、
勤務時間再構築 (③) を呼ばない。GCP 側の値は 1 ミリも動かない。**
②を何回打っても、alc の上げ直しや畳み直しを重ねても動かず、③ → ② で初めて差が消えた実例がある。

**⇒ 「② を何回打っても GCP が動かない」ときは、③ を打っていないことを疑う。**
**`bytes` が同じでも直ることがある** — theearth の中身ではなく、**どのテーブルを書いたか**が効くため。

**★ ③ は `time_card_dtako` を削除して作り直す。材料 (`dtako_events` の
運行開始/休息/運行終了) が無いと消えて戻らない** (`rust-ichibanboshi#281`)。
**必ず ② を先に打って材料を入れてから ③**、の順にすること。
「消えないから効いていない」と読まないこと。

**★ ③のガードは「材料」を数えてから打つ。** 材料 0 件のまま③を打つと**削除だけが走って
`time_card_dtako` が消えて戻らない** (2026-08-01 の実害、`rust-ichibanboshi#281`)。
材料の定義は `dtako_events` を **`運行NO IN (先頭22桁+"1", 先頭22桁+"2")` かつ
`イベント名 IN ('休息','運行開始','運行終了')`**。
**旧実装は `休息` だけを数えていて、`運行開始`/`運行終了` しか無い運行を
`reset_skip_reason: "no_dtako_events"` で誤ってスキップしていた**
(2026-08-04 に本番で実害。`rust-ichibanboshi#290` で 3 種とも数えるよう修正済み)。
今は勤怠 Worker が `POST /api/dtako/autoload` の中で、②が 2xx のあと社内 MariaDB で材料を数え
(`RESET_MATERIAL_SQL`)、1 件以上のときだけ③を打つ。
**`休憩` は材料ではない — `休息` とは別のイベント。**

### ★ 値ずれの型 (実データで確定、2026-08-01)

| 型 | 直し方 | 見分け方 |
|---|---|---|
| 読取日が古い | ①読取日を取り直す | 10 行がこれで解消 |
| `dtako_events` が古い + `time_card_dtako` に残骸 | ①②③ | **`get_rest_diff` に出る** |
| `dtako_events` が古い (残骸なし) | **②だけで直る** | `rest-diff` に出ないが②が効く |
| **alc が古い** | **`run_dtako_scrape` で読取日を取り直す** | **②を打っても 1 行も動かない** (2026-08-04 追加) |
| **打刻と運行終了がずれる** | **打刻を直す** → ①運び直し → 畳み直し | 拘束が両側で桁違い。始業→終業 と 始業→運行終了 の差に一致する |
| 実働 > 拘束 | 未解決 | 運行間の空白を実働に数えている |
| `over_24h` | 未解決 | 拘束が極端に違う |
| **月の fold が未実行** | **`run_kintai_recalc { apply: true }` を回すだけ** | `only_onprem_other` が数百件規模 (通常の按分ずれは数件〜十数件)。`stale_only: true` の dry-run で `stale.drivers` が大半を占める |
| **月末の月跨ぎ勤務 (終業が翌月扱い)** | **待つ (翌月の打刻が push されるまで畳めない)** | `run_kintai_recalc` の warnings に「push 窓ずれ: 対象月の fold が読む翌月1日に打刻が0行」。差が月末日 (07-31等) に偏る |

**`rest-diff` に出ない = ②も効かない、ではない。** ②だけで完全一致した実例がある。

**★ 誰もまだ測っていない月**は、`only_onprem_other` が数百〜千件規模で出ることがある。
按分ずれではなく**単に fold (`run_kintai_recalc { apply: true }`) が一度も回っていないだけ**であることが多い。
まず `stale_only: true` の dry-run で `stale.drivers` の比率を見て切り分けること
(症状の桁が通常の按分ずれと違う場合は、まずこれを疑う)。

**★★ fold 後に残る少数の差を「月末日に集中 = push 窓ずれ」「GCP 側ロジックのバグ」と一般化しないこと。**
実例では真因は単純な取り込み漏れ (対象の `unko_no` の取り違え) だった。教訓は 3 つ:

- **長時間シフトは複数の運行にまたがる。** `day-events` を単一の日付だけで引くと、
  シフトを構成する別日開始の運行を見落とし、**同じ枠内の別の運行 (GCP に既にある方) に ①②③ を打つ**。
  シフト全体の開始〜終了の範囲で引くか、`run_kintai_recalc` の `unko_diff` /
  「dtako 入力欠け」警告と突き合わせ、**投入前にその運行が本当に対象日の差分と一致するか確認**する。
  「①②③すべて試しても直らない」という報告は、まず「本当に正しい運行に打ったか」を疑うのが安い
- **同じ乗務員の他の日が全部一致しているなら、GCP 側に一律のロジック欠陥は無い。** 一般化の前に反証を 1 本探す
- **ツールの選び間違い。** `run_dtako_reimport` は **theearth → 社内 MariaDB** (勤怠 Worker の
  `/api/dtako/autoload`、`dtako_events`/`time_card_dtako` を書く) 専用で、**theearth → alc/GCP** 経路には触らない。
  「dtako 入力欠け」警告 / `unko_diff` が指すのは **alc 側 (GCP が読む方) の欠け**なので、
  MariaDB 側が既にデータを持っていれば reimport は no-op になる。
  **⇒ `unko_diff`/「dtako 入力欠け」型の取り込み漏れは `run_dtako_alc_upload` で直す。`run_dtako_reimport` ではない**

### ★★★ 「実働+休憩の和が両側一致」= alc が古いだけ。上げ直せば直る (2026-08-04 実証)

**この案件で最も件数が多い型。** `get_kintai_diff` の `value_diff_restraint_match` に出て、

```
GCP          working 多 / break 少     和 = X
MariaDB 由来  working 少 / break 多     和 = X   ← 和が一致、拘束も一致
```

のように **`working_minutes + break_minutes` が両側でぴったり一致**する。
**「同じ拘束時間の中を、実働と数えるか休憩と数えるか」の振り分けだけが違う。**

**★ warnings には出ない。ここが罠。**

```
R2 に CSV が無い (404)   → warnings の「KUDGIVT 取得失敗」に出る
R2 に CSV は在るが古い    → warnings に一切出ない        ← この型
```

⇒ **`KUDGIVT 取得失敗` が 0 件でも、按分ずれ型は残っている。**
「warnings が 0 だから R2 は健全」と読まないこと。

**直し方は R2 欠けと同じ — `run_dtako_alc_upload` で運行 1 件を上げ直す。**

**実証 (2026-08-04)**: `KUDGIVT 取得失敗` 0 件の月で、差のうち 1 運行だけを上げ直して畳み直したら
**対象の 1 件だけがピンポイントで消え、他の差・行数・`only_*` は 1 つも動かなかった。**

**データ側の裏付け**: `get_operation_zip` で theearth の KUDGIVT.csv を読むと
**休憩合計が MariaDB 由来の `break_minutes` と 1 分の狂いもなく一致**する。
**theearth == MariaDB 由来、alc だけが古い。**

**★ 2マン特有ではない。** 実測では対象CD=1 (単独乗務) の運行が過半だった。
**「2マンの助手側に休憩がそっくり付く」は誤った一般化。**

### ★★★ 上げ直しでも取り直しでも直らない按分ずれ → **KUDGIVT の区分=2 に `対象乗務員CD` が入っているかを見る** (2026-08-04 確定)

**この型の中に、alc 上げ直しでも MariaDB 側の取り直しでも 1 分も動かないものが混ざる。**
**そのとき原因は「古い」ではなく「材料に乗務員が入っていない」。**

**判別 (read-only、`get_operation_zip` で KUDGIVT.csv を読むだけ):**

```
直らない運行
  区分=1  対象乗務員CD="<主>"   休憩+休息 …
  区分=2  対象乗務員CD=""       休憩+休息 …   ← ★空欄

直った運行
  区分=1  対象乗務員CD="<主>"
  区分=2  対象乗務員CD="<助手>"   ← ★入っている
```

**KUDGIVT は同じ休息イベントを 区分=1 / 区分=2 の 2 行ずつ持つ。区分=2 が助手枠。**
**⇒ theearth 側で助手が登録されていないと、区分=2 の `対象乗務員CD` が空欄になる。**

**なぜ「和が一致、振り分けだけ違う」になるか (これが症状の説明そのもの):**

```
拘束 = 実働 + 休憩   ⇒  休憩だと分からない時間は実働に落ちる
GCP  : 乗務員CD の無い区分=2 を弾く  → 休憩が減り、同じ分だけ実働が増える
MariaDB 由来: 手がかりが区分=1 の CD しか無いので、その乗務員に付ける → 休憩が多い
両側とも 拘束 (= 和) は動かない
```

実測でも MariaDB 由来の break 合計が GCP の数倍あり、**向きも大きさも上の説明と整合した。**

**⇒ 直し方は取り込みではない。** **theearth 側で助手の乗務員を登録してから取り直す**
(F-DES1011 の乗務員変更、または F-DES1013 の `btnMultiManEdit` 交代データ修正)。
**材料に乗務員が入っていないので、何度運んでも同じ値が入るだけ。**

**★ 「GCP の取り込みが構造的に 2マンの助手枠を落としている」と早合点しないこと。**
直った運行では区分=2 が正常に機能している (上記)。**別 repo のコード修正に向かう前に、
必ず「直った 2マン運行の KUDGIVT」と比べること。** 比較 1 件で棄却できる。

**★ diff のエントリ数 = 運行数ではない。** 長距離運行 1 本が複数の暦日に差を出す
(実測で 1 運行が 6 エントリ)。**`ope_no` で重複を畳んでから投入すること。**

**★★ 「取り直しでも直らない」と結論する前に `run_dtako_reimport
{ reset_timecard: true }` (③込み) まで試すこと。** 上の区分=2 空欄は材料そのものが欠けた型だが、
**別の型として、単独乗務 (区分=2 の行自体が無い) の運行で、`run_dtako_alc_upload`
(alc 側だけの上げ直し) では 1 分も動かないのに、`run_dtako_reimport { reset_timecard: true }`
(①②③をフルに通す) だと解消するケースがある。** `run_kintai_recalc` の `drivers_written` が `0` でも
解消したので、**②(`dtako_events`) または③(`time_card_dtako`) 側が古かった**ことになる。
**⇒ 判別手順: alc だけ上げ直して動かない → すぐに『材料欠け』と結論せず、
`run_dtako_reimport { reset_timecard: true }` まで一段階進めてから、それでも
動かなければ KUDGIVT の区分=2 を見て空欄型かどうかを判定する。**
(`reset_timecard: true` は MCP tool の既定になったので、
`run_dtako_reimport` を素で呼ぶだけで自動的にこの一段階を含む。)

**★ 2マンは 22 桁 1 本の投入で主・助手の両方が入る。** 2マン運行の投入応答だけが
`operations_count: 2` (他は全部 1) で確認。**23 桁を 2 本 (`…1` と `…2`) 投入する必要は無い。**

### ★ 画面の「③ に入れる」は③を打てない (22桁/23桁の噛み合わせ)

`restraint-wage` の取り込み漏れ候補にある「**③ に入れる**」は、**③ を実行しない。**
**22 桁を欄に入れてスクロールするだけ。** そして ③ (勤務時間再登録) は
**23 桁でないと拒否する**:

```
勤務時間再登録 (reset_timecard=true) は unko_no が23桁の数値である必要があります
```

**画面が持っているのは GCP 側の 22 桁で、23 桁目 (対象CD) を知らない。**
コードは**意図的に 23 桁目を捏造しない** (別の乗務員の行を消しかねないため)。

**正しい手順:**

```
1. 「③ に入れる」で 22 桁が欄に入る
2. 「勤務時間再登録まで行う (③)」のチェックを外して ①② だけ実行  ← 22桁で通る
3. 「day-events で23桁を引く」ボタンで実物の 23 桁を引く          ← 乗務員CD が要る
4. 引けた 23 桁を欄に入れ直す
5. 改めて③のチェックを入れて実行
```

**②の反映は非同期なので、3 は時間をおいて何度でも押し直す。**

### ★★ 拘束が桁違いに大きい (数千分) → **まず `run_kintai_recalc` の `warnings` を見る**

**2026-08-04 に、これを飛ばして親が 2 回連続で誤診しました。**

`run_kintai_recalc { month, stale_only: true }` は **`apply` を省けば 1 行も書きません**。
その `warnings` に **alc の R2 に CSV が無い運行が名指しで出ます**:

```
<22 桁の運行NO>: KUDGIVT 取得失敗
  (Upload failed: R2 download status 404: NoSuchKey)
dtako 入力欠け: R2 に CSV の無い運行 N 件
```

**KUDGIVT が読めないと GCP はイベント (休息) を 1 つも見られず、休息で分割できません。**
結果、打刻の 始業→終業 1 組だけで畳み、**長距離運行がまるごと 1 日**になります
(実例では拘束・残業が数千分になり、MariaDB 由来の値の 10 倍を超えた)。

**★ これは「畳み方の欠陥」ではありません。取り込めば直ります。** 誤診しやすい 2 点:

| 誤診 | 実際 |
|---|---|
| 「GCP が日の区切りを見落として潰した」 | **打刻は元から 1 組。長距離運行は打刻が 始業/終業 2 個しかないのが正常**で、通常は休息で正しく分割できている (5月は 2 日以上またぐ運行が 416/1098 = 38% あって拘束差 0) |
| 「畳み直し (stale) が入っていないだけ」 | `stale.drivers: 0` / `fold.drivers_written: 0` なら**畳み直し済みで、再計算しても動かない**。stale かどうかは必ずこの応答で確認する |

⇒ **長距離運行そのものは差の原因ではない。** 「打刻が 1 組しかないから割れる」と考えたら、
**同じ形で割れていない運行を 1 本探して反証すること** (これで親の仮説が潰れた)。

**直し方**: 名指しされた 22 桁を `run_dtako_alc_upload` (運行 1 件) で上げ直す。
読取日スクレイプでも直るが全乗務員を巻き込む。

**★ `run_kintai_recalc` の dry-run が返す `fold.shifts` / `day_summaries` / `day_parts` は
「この回に新しく書く数」で、その月に在る総数ではない。** 0 を「畳むものが無い」と
読むと必要な工程を落とす。**総数を知りたいなら `get_kintai_day_summaries` を読む**
(読むだけの口)。

### ★ 切り分けの順序 (2026-08-04 に 5 件で確立)

**②を先に打って、動いたかを測る。これが最初の分岐。**

1. **②(`run_dtako_reimport`) を打つ** → MariaDB 由来の日別サマリ (勤怠 Worker の `kosoku-daily`) を前後で比較
   - **動いた** → MariaDB 側が古かった。終わり
   - **1 行も動かない** → **theearth の現在値 = MariaDB 側の現在値。古いのは alc 側**
2. **alc を疑う** → `/api/proxy/api/operations/{22桁}` (ブラウザ、読むだけ) で
   `raw_data.対象乗務員CD` / `uploaded_at` を見て、`get_operation_zip` の
   `KUDGIVT.csv` の `対象乗務員CD` と突き合わせる。**食い違えば alc が古い**
3. **拘束そのものが桁違い** → 打刻を疑う。`day-events` で 始業/終業/運行開始/運行終了 を並べ、
   **始業→終業** と **始業→運行終了** をそれぞれ分で出すと、どちらが GCP・どちらが MariaDB 由来か一致する

**★ alc が古くなる原因は 2 つとも「後からの編集」** — **乗務員の付け替え**と
**イベント分類 (休憩⇄運転) の編集**。どちらも theearth 側だけが新しくなり、alc は
`uploaded_at` の時点で止まる。**同じ運行が両側で別の乗務員に付くと、休憩がそっくり
別人に計上され、2 人ぶんの差になって現れる** (向きが逆で同じ分数、が目印)。

**★ 打刻の有無は差の原因ではない。** 打刻ゼロの乗務員が 41 名居ても差が出たのは 1 名だけ
(2026-05 実測)。「打刻が無いから `time_card_dtako` が空 → 休憩 0」は成り立たない
(`shift_source: rest` で回る乗務員は打刻無しでも休憩が入る)。

**★★ 理由が判明 (2026-08-04、オーナー): 営業所所属の乗務員は打刻しないのが正常。**
上の「41 名居ても 1 名だけ」はこれで説明が付く。**⇒ 打刻ゼロを異常と読まないこと。**

**⇒ 打刻ゼロを見たら、まず所属を確認する。**

| 所属 | 打刻 | 打刻ゼロは |
|---|---|---|
| **営業所** | **打たないのが正常** | **正常。異常と読まない** |
| **本社** | **打つのが正常** | **異常。欠けている** |

**★ 所属を確かめずに「打刻が無い/ある」を異常と決めないこと。** 同じ「打刻ゼロ」でも
営業所なら正常、本社なら欠落。**2026-08-04 に親がこれを取り違え、本社所属の乗務員を
営業所と誤認して「余計な終業打刻を消せ」と誤った処方を書いた** (正しくは始業の欠落)。

**実例の形 (本社所属)**:

```
timecard 終業    <時刻 T>   ← ★始業が欠けている
dtako   運行終了 <時刻 T>
dtako   休息     <時刻 T>
```

`shift_source: "timecard"` が終業 1 点だけを拾い、**開始 = 終了 の 0 分シフト
(DegenerateShift)** になる。**本社所属なので、直し方は「欠けている始業を入れる」。**

**⇒ `DegenerateShift` / 0 分シフトを見たら、`day-events` で打刻を並べ、
「始業・終業が対で揃っているか」と「その乗務員の所属」の両方を見る。**

### ★ スクレイプの進捗は `get_dtako_scrape_progress` で見る

**`get_dtako_scrape_status` ではありません。** あちらは alc 側の履歴で、**画面から実行した
ぶんしか載らず、`run_dtako_scrape` や日次 cron の実行は 1 件も載らない**
(実測では alc が 403 を返して読めないこともある)。

**★★ 取り直し中に relay を deploy しない (= PR をマージしない)。**
`run_dtako_scrape` は DO の中で走るので、**relay worker の deploy で DO が evict されると
走行中の job が落ちます**:

```
state: failed
error: "DO 再起動 (deploy / evict) で中断しました。取り込み (has_kudgivt リセット)
        済みかどうか不明なため自動リトライしません。手動で状態を確認してください。"
```

**2026-08-04 に実際に踏みました** — nuxt#638 のマージ → `v0.0.352` タグ →
`dtako-scraper-relay DO worker` の deploy が 20:27 に走り、**同じ時刻に `started_at` を
迎えた `2026-06-01` の取り直しが中断**しました。**`upload_id` すら記録されない**ので、
skill の復旧手順 (管理画面の「CSV分割」= `POST /api/split-csv/{id}`) も使えません。

⇒ **キューが空でないことを `get_dtako_scrape_progress` で確認してから PR をマージする。**
親が PR のマージ順を采配するときの前提条件に入れること。

`get_dtako_scrape_progress` は **DO 自身が持つ `scrapeQueue`** を返すので無人実行でも見える。
`pending / running / done / failed` と、**取り込み後の畳み直し (`fold_state` /
`fold_drivers_written`) まで入る** — **`run_kintai_recalc` を手で打つ必要は無い**。
**1 読取日あたり約 3 分** (2026-08-04 実測、9 日で約 30 分)。

### ★★ 読取日 ≠ 運行日。半分ずれる (2026-08-04 実測)

**「差が出た暦日」を読取日として `run_dtako_scrape` に投入するのは誤り。**
約半分の運行で**別の日を触ります**。

勤怠 Worker の `GET /api/kintai/reading-dates?month=` (driver 省略 = 全乗務員) で測ると、
**読取日 != 運行開始日 の運行が半数を超え、その大半が `run_end_date == reading_date` (日跨ぎ)** だった。
(この口を叩く kyuyo-mcp の tool は無い — §4 の表。測るなら relay 経由か新しい tool が要る)

つまり**日跨ぎ勤務は翌日に読まれる**のが常態で、例外ではありません。
ある読取日に載っているのは前日開始の運行で、その日開始の運行は存在しない、ということが普通に起きる。
**読取日として 1 件も存在しない日**もあり、その日を投入しようとしても何も起きません。

⇒ **「投入したのに差が残った」の第一容疑はこれ。** 効かなかったのではなく、
**狙った運行に当たっていない**。

**正しい順序:**

1. 差が出た暦日の勤務を作っている運行の `unko_no` を特定する
2. 勤怠 Worker の `/api/kintai/reading-dates?month=&driver=` の `items` で、**その `unko_no` の
   `reading_date`** を引く (`reading_date` / `run_start_date` / `run_end_date` が
   1 行に並んでいる)
3. **その読取日**を投入する

**★ そもそも読取日を介さない方が安全** — 下の `dtako-alc-upload` は運行 1 件を
直接指定するので、このずれを構造的に回避します。

### ★ 読取日スクレイプは運行 1 件を直すには過剰 → `dtako-alc-upload` で解決済み

`run_dtako_scrape` は**読取日単位で、その日の全乗務員を巻き込む**。取り込み中は
`has_kudgivt` が FALSE に戻り、その日の運行が読み取り側から一時的に消える。

**2026-08-04 に運行 1 件の口が入りました** (nuxt#638、`v0.0.352` で本番稼働):

```
POST /kintai-relay/dtako-alc-upload
body: {ope_no, start_ope, comp_id?}     header: X-Alc-Proxy-Secret
```

- **`unko_no` は不要** — alc の `/api/upload` は zip 内 KUDGURI.csv から読む
  (`/kintai-relay/dtako-reimport` = 勤怠 Worker の autoload 向けとの違い。あちらは 23 桁が要る)
- **`ope_no` / `start_ope` は `kintai-diff.ts` の `deriveOpeNoFromUnkoNo(unkoNo)` で機械導出できる**
  (`ope_no22 = unkoNo.slice(0,22)`、`start_ope` は先頭 12 桁 `YYMMDDHHmmss` →
  `"YYYY/MM/DD H:mm:ss"`、**時は 0 埋めなし**)。`handleKintaiRefreshMysql` が同じ導出をしている
- **投入前に read-only の `/cron/dtako/operation-zip` (`get_operation_zip`) を同じ引数で叩く** —
  KUDGURI/KUDGIVT が entries に居るかを見てから投げる
- **応答の `split_confirmed` は常に `false`。`split_failed: 0` を「分割済み」と読まない**
  (`try_split_csv` は non-blocking。skill の「1 回の測定で結論を出さない」と同型)
- **`has_kudgivt` は `DEFAULT FALSE` に戻る** — split が通るまで読み取り側から一時的に消える
- **並列に叩かない。** 同一 comp_id の theearth セッションロックで hang / 500 になり得る

**なぜ運行 1 件の zip で足りるか** (`rust-alc-api` の
`crates/alc-dtako/src/dtako_upload.rs` 実コード確認): `process_zip` は zip 内
KUDGURI.csv の**行数ぶんだけ** `insert_operation` する。日次 zip 前提ではない。
`run_dtako_scrape` が読取日ぶん全部を巻き込むのは **theearth 側の取得単位が日次だから**
であって、alc の受け口の制約ではない。

**運行数 (22 桁) と突き合わせたいなら `run_kintai_recalc` の
`unko_diff_gcp_only_in_month_by_driver[].gcp_only` を見る (= その月の 22 桁運行数)。
`operations_count` と期待値を直接比べると、2マンのぶんだけ上振れして
「絞込が効いていない」と誤診する。**

### ★ 幽霊行 (2マン登録を削った残骸)

2マンで登録して後から削ると、**対象CD=2 の派生行が `time_card_dtako` に残る**
(`_setbyUnkoNo` は INSERT しかしない)。

**★ 2026-08-04 訂正: 「③を打てば消える (`dtako_rows` に運行レコードが無くても動く)」は誤り。**
実コード (`yhonda-ohishi/nginx` の `TimeCardDtakoController::_setbyUnkoNo`) は

```php
$dd_dr = $this->TimeCardDtako->DtakoRows->find()->where(['id' => $id])
    ->first()->対象乗務員CD;
```

と **`dtako_rows` を 23 桁で引いて `->first()->対象乗務員CD` を読む**ので、**運行レコードが
無ければここで落ちる**。⇒ **運行ごと消してある残骸に③は使えない。SQL で消すことになる。**

**★ 要確認: この SQL を誰がどこから打つか (書き込み経路) は未調査です** (2026-10-15)。
勤怠 Worker は社内 MariaDB を SELECT しかしないので、Worker の口からは消せません。
打つ前に親へ `[質問]` で経路を確かめること。下の座標 (列名・条件) は CakePHP の実コードで確認済み。

消すときの座標 (実コードで確認済み):

- `time_card_dtako` の運行NO 列は **`unko_no`** (③ は `deleteAll(['unko_no' => $id])`)
- **`dtako_events` の運行NO 列は日本語の `運行NO`** — テーブルごとに列名が違う
- **`driver_id` を必ず条件に入れる。** 同じ 23 桁に複数の乗務員の行がぶら下がることがあり
  (片方は実データを持つ正当な行)、`unko_no` だけで消すと巻き添えになる
- `_setbyUnkoNo` は `dtako_events` を **`運行NO IN (先頭22桁+"1", 先頭22桁+"2")`** で読むので、
  **`dtako_events` 側に対象CD=2 が残っていると、相方に③を打った瞬間に復活する**

### ① の zip は 2 系統ある

| | 認証 |
|---|---|
| `GET /daily-report-api/zip` (画面用) | **ブラウザ由来のセッション**。`Authorization: Bearer` + `X-Theearth-Comp-Id` + `X-Theearth-User-B64` の**3 つ全部**が要る。素のリンクでは開けない |
| relay の自前ログイン (無人用) | `DTAKO_ACCOUNTS` (KV)。**ブラウザ不要** |

**★ localStorage のキーは `theearth-session`。** `daily-report-edit-session` も同じ形で
存在するが**中身が別**で、そちらでは 401 になる (2026-08-01 に踏んだ)。

**`opeNo` は 22 桁** (`OPE_NO_RE = /^\d{22}$/`)、**`startOpe` は `"YYYY/MM/DD H:mm:ss"`**
(**時は 0 埋めなし**、`START_OPE_RE`)。MariaDB 由来の `unko_no` は 23 桁なので**末尾 1 桁を落とす**。

## 4.8 claude-in-chrome の使いどころと限界

- **小さい読み取り JS は即返る。fetch を含む大きい JS は 1 分半ハングして返らない**
  (2026-08-01 に 3 回再現)。**ブラウザで自動化を組むなら、fetch を JS 内で await しない**
- **`javascript_tool` は session/token を含む値の返却をブロックする** (`[BLOCKED: Sensitive key]`)。
  **ページ内で使うのは通る**ので、トークンを読み出さずに fetch させることはできる
- **オリジンをまたぐバイト列の受け渡しは URL fragment で運べる** (fragment はサーバに送られない)。
  ただし**ページが再読込されると消える**

## 5. rust-ichibanboshi の gate (踏むと確実に落ちます)

**詳細 (座標・コマンド・各 workflow の job) は `rust-ichibanboshi` の `rust-ichibanboshi-map` skill
(`.claude/skills/rust-ichibanboshi-map/`) が正本です。** ここには踏みやすい要点だけ置きます。

- **カバレッジ 100% gate**: `coverage_100.toml` は **root (rdp-relay) と `workers/` の各 Worker
  (`workers/kintai/`・`workers/ichiban/` ほか) に 1 本ずつ**あり、登録したファイルは 100% 行カバレッジ維持。
  root は `make cov-check`、workers は各 workflow (`worker-kintai.yml` 等) が回す
- **★ `tracing` マクロと `format!` を複数行にしないでください。** フォーマット文字列が
  独立行になると (手書きでも rustfmt の折り返しでも) その行が llvm-cov の行
  カバレッジに乗らず gate が落ちます。**このリポジトリで 4 回踏んでいます**
  - **★ 折り返しの閾値は 100 桁ではありません。実測で 81 文字程度から折れます**。
    **1 行に収める前提でメッセージを短くする**のが確実で、長い説明はコメントへ回してください
- **100% に到達したファイルは `coverage_100.toml` に足す。** ただし**実行行 0 のファイルは
  登録できません** (登録簿にあるのに計測データに現れないと fail)
- **`CLAUDE.md` は 50 行 / 2000 字が上限**。書き足したくなったら `rust-ichibanboshi-map` skill へ
- **`migrations/` の適用済み migration はコメント 1 文字でも変えない** (SHA-384 照合で loud fail)。
  **新表の migration には `GRANT` を書く** (`GRANT ON ALL TABLES` は既存表だけのスナップショット。
  書き忘れて本番 502 になった。pg テストは所有者で繋ぐので権限を通りません)
- **★ 勤怠の版 `logic_version` は、`LOGIC_BASE` (`workers/kintai/kosoku/src/kintai_fold.rs`) と
  TOML (KosokuParams) だけで決まります。** ファイル名やソースを触っても版は変わらず、
  deploy で全乗務員が stale になることも畳み直しも要りません (etag は変わる)。
  **計算結果を変える変更では `LOGIC_BASE` を手で上げ**、
  `KINTAI_GOLDEN_APPEND=1 cargo test -p kintai-kosoku --test logic_golden` で golden の表
  (`workers/kintai/kosoku/tests/golden/logic_outputs.tsv`) に 1 行足す →
  本番に出してから (§1: tag `worker-kintai-v*`) `run_kintai_recalc` で畳み直す。上げ忘れは golden テスト
  (`workers/kintai/kosoku/tests/logic_golden.rs`) が CI で落とす。
  **ただし固定入力が通らない分岐は検知できない**ので、分岐を足したら入力も足すこと
- **ローカルで全体テストや `make cov-check` を回さないでください** (時間が溶けます)。
  **`cargo fmt --all` だけかけて push**。CI が回します

## 6. 踏み抜き済みの罠

- **★「検索して 0 件」を「無い」の根拠にしない。** GitHub の code search はこの org で
  `total=0` を返します (自分の repo の既知のヒットすら 0 件)。**clone して `git grep` が
  唯一信用できます。** 範囲を絞った検索で「無い」と結論するのも同じ失敗です
  (「運行が alc に無い」と誤報し、実際は 6 月で絞っていて運行日が 05-31 だっただけ)
- **★ 1 回の測定で結論を出さない。** split は非同期です。取り直し直後に
  `unsplit_total = 42` を見て「42 件壊れた」と報告しかけ、1 分後に測り直したら 0 でした
- **★ 取り込み (再アップロード) は `has_kudgivt` を `DEFAULT FALSE` に戻します。**
  split が失敗すると運行が読み取り側 3 クエリ全部から消えます。
  **復旧は管理画面 `dtako.ippoan.org/upload` の「CSV分割」ボタン** (`POST /api/split-csv/{id}`)
- **運行NO は桁に情報を持っています** — 23 桁 = 開始日時 12 桁 + 車輌CD 10 桁 + 対象CD 1 桁。
  **末尾の長さは可変** (22 桁の実物も居る) ので**先頭だけを見て後ろは見ない**。
  「列が無いから出せない」の前に桁を数えてください
- **応答が大きい tool 結果はファイルに落ちます。** python で必要な部分だけ抜いてください
- **`git reset --hard` は分類器に弾かれます** (stash → ff-merge → drop で回す)
- **★ 「分類器に弾かれた」理由を断定しないこと。** 拒否メッセージは
  `Permission for this action was denied by the Claude Code auto mode classifier` の
  ように **auto mode を名指しすることがありますが、セッションが実際に auto mode か
  どうかを子が知る手段はありません** (権限モードを問い合わせる tool は無い)。
  **文言をそのまま引用して報告し、「auto mode だから弾かれた」と書かないこと。**
  親も同じで、**prompt に「auto mode の classifier に弾かれます」と断定して書かない**
  (2026-08-01 に親が書き、ユーザーから「すでに auto じゃない」と指摘された)。
  正しい書き方は「**弾かれたら文言をそのまま報告して止まる。迂回路を探さない**」

## 7. タスクフォルダ

走行中のタスクは **`/home/claude/claude260730/tasks/<番号>-<slug>.md`** で管理されています
(git の外・3 repo 共通・**作業 PC 限定**)。**自分のファイルがあれば読んでください** —
受け入れ条件の表と、親からの指示の変更履歴がそこにあります。**無ければ起動 prompt の
受け入れ条件が正本です** (上の「前提」参照)。

- **子は「子からの報告」節に追記します** (親への `send_message` と同じ内容で構いません)
- **受け入れ条件の表は親が書き、親が突き合わせます。** 子が編集しないでください
- **完了したファイルは親が消します。** 子は消さないでください

書式と運用は `/home/claude/claude260730/tasks/README.md` にあります。
