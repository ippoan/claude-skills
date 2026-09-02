---
name: kintai-ops
description: 勤怠 (kintai) まわりを 3 repo 横断で触るときの運用知識。rust-ichibanboshi / nuxt-dtako-admin / rust-alc-api の PR 作法・親子通信・オンプレの測定手段・カバレッジ 100% gate・踏み抜き済みの罠を 1 枚にまとめる。kintai / 勤怠 / 打刻 / 月ゲート / fold / unko_diff / day_summaries / dtako / デジタコ / alc / 運行NO / 拘束時間 / 乗務員 / 読取日 / スクレイプ を扱うタスク、およびこの領域の子タスクとして起動されたセッションは着手前に必ず読む。
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
`http://ohishi-data:3100` (§4) は tailscale 経由の内部アドレスなので、
**作業 PC 以外からは届きません。**

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

オンプレの**打刻**とデジタコ (**dtako**) を Supabase (GCP) に畳んで持ち、勤怠を再計算する
仕組み。3 repo にまたがる:

| repo | 役割 |
|---|---|
| `ohishi-exp/rust-ichibanboshi` | **勤怠の計算ロジック本体** (fold / 月ゲート / 突合)。オンプレと GCP で同じ binary |
| `ippoan/rust-alc-api` | デジタコの生データを渡す基盤 (運行の列挙 / R2 の CSV / etags) |
| `ohishi-exp/nuxt-dtako-admin` | 取り込み (スクレイプ / CSV 分割 / relay) と管理画面 |

**いまの数字と進捗はここに書きません** (上表のとおり memory と issue が持ちます)。

**★ 症状だけでは処方が決まりません。** 「行が N 行足りない」は原因が複数あり、処方が
全部違います (窓の外に落ちた / 乗務員が付いていない / オンプレの行が古い / 元データが
編集された)。**原因を確かめる前に処方 (取り直し等) を当てにいくのが、この領域で最も
時間を溶かす動きです。**「行が足りない」「値が違う」は症状であって診断ではありません。

## 1. ★ PR = 本番行き。子は branch push まで

| repo | 引き金 |
|---|---|
| `ohishi-exp/rust-ichibanboshi` | **PR 作成** (CI green → auto squash merge → GCP image) |
| `ippoan/rust-alc-api` | **PR 作成** (auto merge + auto tag + auto flip) |
| `ohishi-exp/nuxt-dtako-admin` | **PR 作成** (auto merge → auto flip) |

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

`rust-alc-api` は **main merge では出ません** (`v0.0.*` タグ + Release Wave)。
migration の本番適用は **CI のジョブが success になった時点**であって merge 時点では
ありません。

- **`gh pr create` を実行しないでください。** 子セッションでは classifier に拒否されます
- **branch push まで**やって親に報告 → **PR は親が作ります**。feature branch push でも CI は回るので、検証はそれで足ります
- 唯一のブレーキは CI です

repo 固有:

- **`ippoan/rust-alc-api` は同一作者の open PR が 1 本まで** (2 本目は PR Limit Check で落ちる)。
  **`crates/` / `src/` / `migrations/` を触ったら同じ PR で map 再生成** (map-check は enforce=fail)。
  **main merge では本番に出ません** — deploy は `v0.0.*` タグ + Release Wave
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

## 4. ★ 測定手段 — オンプレに直接届きます

```bash
curl -s http://ohishi-data:3100/health
curl -s "http://ohishi-data:3100/api/kintai/events?month=2026-06&driver=1078"   # driver 必須
curl -s "http://ohishi-data:3100/api/kintai/rest-diff?month=2026-06"            # driver 省略可
curl -s "http://ohishi-data:3100/api/kintai/reading-dates?month=2026-06"        # driver 省略可
curl -s "http://ohishi-data:3100/api/kintai/day-summaries?month=2026-06"
```

- **Cloudflare Access の 403 は edge (`rust-ichiban.mtamaramu.com` 経由) にだけ**効きます。
  tunnel を通らない直接続にサービストークンは要りません
- **新しい口を足したら、MCP tool の登録を待たずに deploy 後この `curl` で測れます**
- **★ `http://ohishi-data:3100` は tailscale 経由の内部アドレスです。commit message /
  PR 本文 / docs / コード内コメントに書かないでください** (ユーザー指示)。測定に使うのは可
- **`/health` の `backends` を 1 回読めば到達性が確定します。** config を読んで推論しない
  (`kintai_events: "mariadb"` の 1 行が「オンプレは alc を呼べない」を確定させ、
  親の設計案 2 つを同時に潰しました)

**★★ GCP 側の「拘束の内訳 (どの時刻からどの時刻までを拘束と見たか)」を覗く口は無い** (2026-08-04 確認)。

| 口 | 返るもの |
|---|---|
| `get_kosoku_events` | **オンプレの `dtako_events` だけ。** GCP 側は 1 行も返らない |
| `get_kintai_day_summaries` | **集計値のみ** (`restraint_minutes` 等)。区間レベルの内訳は無い |
| `get_kintai_diff` | 両側の集計値。内訳は無い |

**⇒ 「GCP が何を見てその数字を出したか」は現状わからない。** 両側の集計値が食い違う原因を
最後まで詰めるには、**`rust-ichibanboshi` に診断用の口を足すしかない**
(**ファイル名を `kintai` / `kosoku` で始めないこと** — `logic_version` が変わる。§5 参照)。

**★ `get_restraint_summary` を GCP のライブ値と混同しないこと。** これは**給与比較アーカイブ**で、

- **第三の値**を返す (実例: `1575/2026-02-06` が `day_summaries` 945 / オンプレ 626 に対して **657**)
- **`fetched_at` / `last_verified_at` が数週間前**のことがある (定期エクスポートのスナップショット)
- **暦日 (day5/day6) ベース**で、`day_summaries` の `乗務員CD|暦日|開始時刻` (シフト境界ベース) とは**軸が違う**

**⇒ 差の調査に使わない。** 使うと存在しない第三の乖離を追いかけることになる。

### ★★ `get_wage_report` (MCP) と 画面の「拘束×賃金」は**別ソース**。突き合わせるな (2026-08-04 実証)

**同じ会社・同じ月・同じ乗務員なのに値が違う。** どちらかが壊れているのではなく、読む先が違う:

| 経路 | 読む先 |
|---|---|
| **MCP `get_wage_report`** | **R2 の給与比較アーカイブ** (`loadMonthSummaries` → `restraint/{comp}/…`)。上の `get_restraint_summary` と同じスナップショット |
| **画面 `/restraint-api/wage-report`** | **relay 経由のライブ** (`loadWageReportSource` = ichiban への fetch + 打刻の live-build) |

**実例 (`1718/2026-06`)**: MCP は 実働 233h48m、画面は 244h42m。**MCP の値で画面の異常を否定してはいけない。**
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
スナップショットの中を検索するだけで、取り直しません。**自分で足した tool は自分では
呼べません。** 見えない tool があったらユーザーに connector 追加を頼むのが最短です
(走行中のセッションにも入ります)。

管理画面 `https://dtako.ippoan.org` — 運行一覧 / スクレイプ (読み取り日ベースのカレンダー) /
アップロード。ブラウザから `/api/proxy/api/operations/{22桁の運行NO}` で
`reading_date` / `operation_date` / `has_kudgivt` が引けます。

## 4.5 ★ 認証と到達性 — どこから何に届くか

**「サーバ側で自動化できるか」は、毎回ここで決まります。** 思いつく前に表を見ること。

| 相手 | 認証 | 誰が届くか |
|---|---|---|
| **オンプレ rust** (`ohishi-data:3100`) | 不要 (CF Access は edge だけ) | 作業 PC / オンプレ内 |
| **社内 nginx (CakePHP)** = 内部ホスト | **`view` / `autoload` など主要 action は `AppController::beforeFilter` の `addUnauthenticatedActions` で認証免除**。ただし **CakePHP の CSRF は別**で、フォームに `_csrfToken` があり **対の cookie は HttpOnly** | **オンプレからは届く。Cloudflare の worker からは届かない** (内部アドレス) |
| **`dtako.ippoan.org` (nuxt SPA)** | **要る。token は `localStorage`、サーバ側 DO の TTL 8h** (`useTheearthSession`)。`authHeaders()` が読む | **relay / kyuyo-mcp は自前で theearth にログインできる** (`DTAKO_ACCOUNTS` を KV に持つ) |

**⇒ 3 つを 1 か所から自動で繋ぐ経路は無い。**

- **社内 nginx の `pdf-json` (勤怠 PDF の元 JSON) はオンプレからだけ叩ける**:
  `ssh <オンプレ (§4 のホスト)>` → `curl 'http://127.0.0.1:120/time-card/pdf-json?month=2026-04&recalc=0'`。
  relay の `timecard-compare` の fixture (`workers/dtako-scraper-relay/test/fixtures/pdf-json-*.json`) は
  この応答を 3 名 × 数日に間引いたもの (repo 側のコメントからは nuxt-dtako-admin#1073 で手順を伏せ、ここが正本)
- **token を URL に載せる案は成立しません** — localStorage にあり 8 時間で失効し、履歴とログに残る
- **CSRF cookie が HttpOnly** なので、**フォーム投稿はそのページを開いたブラウザからしか通りません**。
  サーバ側から投げようとすると CSRF を迂回することになるので、やらない
- **ブラウザ操作 (claude-in-chrome) が使えるなら、それが最短**。認証も CSRF も
  ブラウザが持っているものをそのまま使えるので、資格情報をどこにも移さずに済む

**★ 「オンプレ rust から外部を fetch しない」は `dtako_day` (リンク組み立て) 限定の注意。**
一般則ではない — オンプレは既に auth-worker (`/auth/introspect`) を fetch している。

**★ ただしオンプレに secret を置くのは不可** (2026-08-01 オーナー判断)。
外へ出る必要があるときは **relay → オンプレの push 方向**にする
(`PUT /api/restraint/summaries` と同じ流儀。**資格情報は relay 側に既にある**)。

## 4.6 `unko_no` の桁がオンプレと GCP で違う

**オンプレ (MariaDB) は 23 桁、GCP (alc 由来) は 22 桁**で、突合は先頭 22 桁で当てています
(`unko_diff_trials` の `prefix22`)。**社内 nginx の URL キーは 23 桁**なので、
**リンクを作れるのはオンプレ側の値だけ**。22 桁を混ぜると存在しない運行を指します。

## 4.7 ★ ずれた値を直す導線 (3 段。どこが誰の担当かが毎回問題になる)

```
① csvdata.zip を取る    theearth        relay が DTAKO_ACCOUNTS で自前ログインできる
② 社内 nginx へ取り込む   autoload        オンプレ rust だけが内部アドレスに届く
③ 勤務時間再登録         resetbyUnkoNo   人がボタンを押す
```

### ② の口 (`POST <nginx>/dtako-events/autoload`)

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
  → relay が theearth から zip 取得 (自前ログイン) → 検証 → オンプレへ push
  → nginx へ取り込み → (任意で) 勤務時間再登録
```

**モデルは base64 を運ばない** (以前は書き写して壊れていた)。
**`uncertain: true` が返ったら同じ引数で再実行しない** — 取り込みは応答より前に走る。

### ★ `unko_no` は「取り込み先の鍵」ではない (2026-08-04 実コード確認・tool 説明が誤り)

**`reset_timecard: false` (既定) では、取り込む中身を決めるのは zip (`ope_no` + `start_ope`) で
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

**★ ②と③は書く先が違う (2026-08-04 追加)。ここを混同すると診断を外す。**

| | 書く先 | 効果 |
|---|---|---|
| **②** (`reset_timecard=false`) | **`dtako_events`** | 勤怠の値は動く (`kosoku-daily` は `dtako_events` の休息から計算するため) |
| **③** (`reset_timecard=true`) | **`time_card_dtako`** | 運行NO を持つ行を作り直す |

**取り込み漏れ候補の判定は `time_card_dtako` しか見ない** (`MONTH_OPERATIONS_SQL` の
`PUSHED_SOURCES = ["timecard","dtako"]`。`dtako_events` は入らない)。
⇒ **②だけを打っても候補一覧からは消えない。** 値が直っても候補に残るのは正常。

### ★★★ ② だけでは GCP に永久に届かない — ③ を呼ばないと反映されない (2026-08-04 実証)

**`rust-ichibanboshi` の `src/kintai_push.rs:84`:**

```rust
/// `dtako_events` (デジタコ生イベント) が入っていないのは決定 5 のとおり R2 に永続化済みだから。
pub const PUSHED_SOURCES: [&str; 2] = ["timecard", "dtako"];
```

`kintai_pg_repo.rs` の `fetch_all_events_between` がこれで絞って **GCP の fold の入力**を作る。

| | 読む先 | 更新するのは |
|---|---|---|
| **オンプレ** `kosoku-daily` | **`dtako_events`** | **② (`reset_timecard: false`)** |
| **GCP** の fold | **`time_card_dtako` 由来 (`dtako` source)** | **③ (`reset_timecard: true`) だけ** |

**⇒ `run_dtako_reimport` の既定 (`reset_timecard: false`) は `dtako_events` しか書かず、
勤務時間再構築 (③) を呼ばない。GCP 側の値は 1 ミリも動かない。**

**実証 (`1575 / 2026-02-06`、31 分の按分ずれ)**:

```
run_dtako_reimport   ×5 回   GCP の break 143 は 1 度も動かず
run_dtako_alc_upload ×4 回   同上 (drivers_written: 0 が毎回)
run_kintai_relay     ×1 回   同上
─────────────────────────────────────────
オーナーが画面から ③ (勤務時間再登録) を実行 → ② で取り込み直し → **差 0 件**
```

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

**`rest-diff` に出ない = ②も効かない、ではない。** `1536|06-29` は②だけで完全一致した。

**★ 2026-08-04、2026-07を測って分かったこと**: 対象月をまだ誰も手動で測っていない場合、`only_onprem_other` が数百〜千件規模で出ることがある。これは按分ずれではなく**単に fold (`run_kintai_recalc { apply: true }`) が一度も回っていないだけ**であることが多い。まず `stale_only: true` の dry-run で `stale.drivers` の比率を見て切り分けること (症状の桁が通常の按分ずれと違う場合は、まずこれを疑う)。fold後に残る少数の `only_onprem_other` のうち、**対象月の末日に集中するもの**は、翌月の打刻がまだGCPにpushされていないことによる構造的な未確定 (bug ではない) で、翌月分のデータが揃うまで待てば自然に解消する。

**★★ 2026-08-04 追記・訂正: 「月末日に集中 = push窓ずれ」も「GCP側ロジックのバグ」も
誤りだった。真因は単純な取り込み漏れ (取り込み対象の unko_no を間違えていただけ)。**

`1714/2026-07-29` (拘束 1451 分、始業 07-29 23:11:21 → 終業 07-30 23:23:57) を最初に
`get_kosoku_events` で見たとき、休憩イベント5件 (合計137分、オンプレ break_minutes と
完全一致) を見つけ、「GCP は打刻の枠内の休憩イベントを一切見ていない」と結論しかけた。
**この結論は誤りだった** (ユーザーの「他の運行にも起きているはずでは？」という指摘で
再検証して判明)。

**実際には、5件の休憩は全部 `26073005233300000045611` (07-30 05:23:33 開始) という
1つの運行の中にあり、この運行そのものが `run_kintai_recalc { stale_only: true }` の
`unko_diff` (取り込み漏れ候補、「dtako 入力欠け」警告の実体) に載っていた** —
つまり GCP の `time_card_dtako` にまだ届いていない運行だった。**「①②③を試しても
直らなかった」のは、その運行に対して打っていなかったから**: `day-events(driver,
date=07-29)` で日付だけを頼りに引くと、**同じ枠内に別の運行 (`26072900043500000045611`、
07-29 00:04 開始、GCP に既にある) が先に出てくる**ため、そちらに ①②③ を打っていた
(効果が無いのは当然、対象を間違えていたため)。

**⇒ 「打刻ベースのGCP計算ロジックが休憩を無視する」という一般化は早合点だった。**
1714 の他の 25 件 (2026-07、この1件以外は全部一致) が正常に計算できていることからも、
GCP 側に一律のロジック欠陥は無い。**教訓: 長時間シフトは複数の運行にまたがることがあり、
`day-events` を単一の日付だけで引くと、シフトの一部を構成する別日開始の運行を
見落とす。** 差の原因になっている `unko_no` を正しく特定するには、シフト全体の
開始〜終了の範囲で `day-events` を引き (または `run_kintai_recalc` の `unko_diff` /
「dtako 入力欠け」警告と突き合わせ)、**投入前にその運行が本当に対象日の差分と
一致するか確認**すること。「①②③すべて試しても直らない」という報告を鵜呑みにせず、
まず「本当に正しい運行に対して打ったか」を疑うのが安い。

**★ 正しい運行 (`26073005233300000045611`) に対してすら、`run_dtako_reimport
{ reset_timecard: true }` は no-op だった (`dtako_events_count` はあるのに数値が
動かない)。理由は「ツールの選び間違い」というもう一段別の罠**: `run_dtako_reimport`
は **theearth→オンプレ** (`/api/dtako/autoload`、`dtako_events`/`time_card_dtako` を
書く) 専用で、**theearth→alc/GCP** 経路には触らない。「dtako 入力欠け」警告 /
`unko_diff` が指しているのは **alc 側 (GCP が読む方) の欠け**なので、直すツールは
`run_dtako_alc_upload`。オンプレは既にデータを持っていた (だから reimport が
no-op になった) が、alc 側だけが空だった。**⇒ `unko_diff`/「dtako 入力欠け」型の
取り込み漏れは `run_dtako_alc_upload` で直す。`run_dtako_reimport` ではない**
(この節の冒頭「実働+休憩の和が両側一致」型と同じツールで、原因の絞り込みだけが
違う)。

### ★★★ 「実働+休憩の和が両側一致」= alc が古いだけ。上げ直せば直る (2026-08-04 実証)

**この案件で最も件数が多い型。** `get_kintai_diff` の `value_diff_restraint_match` に出て、

```
GCP     working 1076 / break   0     和 1076
オンプレ working  136 / break 940     和 1076   ← 和が一致、拘束も一致
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

**実証 (2026-08-04)**: 2026-05 は `KUDGIVT 取得失敗` 0 件・差 22 件。うち 1 件
(`1194 / 05-23`、`ope_no 2605230341010000004219`) だけを上げ直して畳み直したら
**22 → 21**。**対象の 1 件だけがピンポイントで消え、他 21 件・行数・`only_*` は
1 つも動かなかった。** `drivers_written: 2`。

**データ側の裏付け**: `get_operation_zip` で theearth の KUDGIVT.csv を読むと
**休憩合計がオンプレの `break_minutes` と 1 分の狂いもなく一致**する
(`1387/05-22` は 178=178、`1107/05-09` は 151=151)。**theearth == オンプレ、alc だけが古い。**

**★ 2マン特有ではない。** 3 件中 2 件が対象CD=1 (単独乗務)。2026-04 では 19 件中
13 運行が対象CD=1 だった。**「2マンの助手側に休憩がそっくり付く」は誤った一般化。**

### ★★★ 上げ直しでも取り直しでも直らない按分ずれ → **KUDGIVT の区分=2 に `対象乗務員CD` が入っているかを見る** (2026-08-04 確定)

**この型の中に、alc 上げ直しでもオンプレ取り直しでも 1 分も動かないものが混ざる。**
**そのとき原因は「古い」ではなく「材料に乗務員が入っていない」。**

**判別 (read-only、`get_operation_zip` で KUDGIVT.csv を読むだけ):**

```
直らない運行 (1697/04-08、2604080513090000006769)
  区分=1  対象乗務員CD="1697"   休憩+休息 2953 分
  区分=2  対象乗務員CD=""       休憩+休息 5572 分   ← ★空欄

直った運行 (1194/05-23、2605230341010000004219)
  区分=1  対象乗務員CD="1738"
  区分=2  対象乗務員CD="1194"   ← ★入っている
```

**KUDGIVT は同じ休息イベントを 区分=1 / 区分=2 の 2 行ずつ持つ。区分=2 が助手枠。**
**⇒ theearth 側で助手が登録されていないと、区分=2 の `対象乗務員CD` が空欄になる。**

**なぜ「和が一致、振り分けだけ違う」になるか (これが症状の説明そのもの):**

```
拘束 = 実働 + 休憩   ⇒  休憩だと分からない時間は実働に落ちる
GCP  : 乗務員CD の無い区分=2 を弾く  → 休憩が減り、同じ分だけ実働が増える
オンプレ: 手がかりが区分=1 の CD しか無いので、その乗務員に付ける → 休憩が多い
両側とも 拘束 (= 和) は動かない
```

**実測 (1697/2026-04 の 6 エントリ)**: オンプレ break 合計 4112 / GCP break 合計 1354。
**向きも大きさも上の説明と整合する。**

**⇒ 直し方は取り込みではない。** **theearth 側で助手の乗務員を登録してから取り直す**
(F-DES1011 の乗務員変更、または F-DES1013 の `btnMultiManEdit` 交代データ修正)。
**材料に乗務員が入っていないので、何度運んでも同じ値が入るだけ。**

**★ 「GCP の取り込みが構造的に 2マンの助手枠を落としている」と早合点しないこと。**
直った運行では区分=2 が正常に機能している (上記)。**別 repo のコード修正に向かう前に、
必ず「直った 2マン運行の KUDGIVT」と比べること。** 比較 1 件で棄却できる。

**★ diff のエントリ数 = 運行数ではない。** 長距離運行 1 本が複数の暦日に差を出す。
2026-04 は **19 エントリ = 13 運行** (`1697` は 6 エントリが 1 運行)。
**`ope_no` で重複を畳んでから投入すること。**

**★★ 2026-08-04 追記: 「取り直しでも直らない」と結論する前に `run_dtako_reimport
{ reset_timecard: true }` (③込み) まで試すこと。** 上の 1697 は単独乗務ではなく
KUDGIVT の区分=2 (助手枠) の `対象乗務員CD` が空欄という、材料そのものが欠けた型
だった。だが**別の型として、単独乗務 (区分=2 の行自体が存在しない) の運行で、
`run_dtako_alc_upload` (① alc側だけの上げ直し) では 1 分も動かないのに、
`run_dtako_reimport { reset_timecard: true }` (①②③をフルに通す) だと解消する
ケースが 4 件見つかっている** (2026-07、`1442/07-09` 等)。
`run_kintai_recalc` の `drivers_written` が `0` (畳み直しは何も変えていない) でも
解消したので、**②(`dtako_events`) または③(`time_card_dtako`) 側が古かった**ことに
なる。**⇒ 判別手順: ①だけ上げ直して動かない → すぐに『材料欠け』と結論せず、
`run_dtako_reimport { reset_timecard: true }` まで一段階進めてから、それでも
動かなければ KUDGIVT の区分=2 を見て 1697 型かどうかを判定する。**
(`reset_timecard: true` は #633-24-2 で MCP tool の既定になったので、
`run_dtako_reimport` を素で呼ぶだけで自動的にこの一段階を含む。)

**★ 2マンは 22 桁 1 本の投入で主・助手の両方が入る。** `1194/05-23` の投入応答が
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
2601060641510000003882: KUDGIVT 取得失敗
  (Upload failed: R2 download status 404: NoSuchKey)
dtako 入力欠け: R2 に CSV の無い運行 4 件
```

**KUDGIVT が読めないと GCP はイベント (休息) を 1 つも見られず、休息で分割できません。**
結果、打刻の 始業→終業 1 組だけで畳み、**長距離運行がまるごと 1 日**になります
(実例: 1104 / 2026-01-06 が **拘束 7887 分 / 残業 7410 分**。オンプレは 685 分)。

**★ これは「畳み方の欠陥」ではありません。取り込めば直ります。** 誤診しやすい 2 点:

| 誤診 | 実際 |
|---|---|
| 「GCP が日の区切りを見落として潰した」 | **打刻は元から 1 組。長距離運行は打刻が 始業/終業 2 個しかないのが正常**で、通常は休息で正しく分割できている (5月は 2 日以上またぐ運行が 416/1098 = 38% あって拘束差 0) |
| 「畳み直し (stale) が入っていないだけ」 | `stale.drivers: 0` / `fold.drivers_written: 0` なら**畳み直し済みで、再計算しても動かない**。stale かどうかは必ずこの応答で確認する |

⇒ **長距離運行そのものは差の原因ではない。** 「打刻が 1 組しかないから割れる」と考えたら、
**同じ形で割れていない運行を 1 本探して反証すること** (これで親の仮説が潰れた)。

**直し方**: 名指しされた 22 桁を `run_dtako_alc_upload` (運行 1 件) で上げ直す。
読取日スクレイプでも直るが全乗務員を巻き込む。

### ★ 切り分けの順序 (2026-08-04 に 5 件で確立)

**②を先に打って、動いたかを測る。これが最初の分岐。**

1. **②(`run_dtako_reimport`) を打つ** → オンプレの日別サマリを前後で比較
   - **動いた** → オンプレが古かった。終わり
   - **1 行も動かない** → **theearth の現在値 = オンプレの現在値。古いのは alc 側**
2. **alc を疑う** → `/api/proxy/api/operations/{22桁}` (ブラウザ、読むだけ) で
   `raw_data.対象乗務員CD` / `uploaded_at` を見て、`get_operation_zip` の
   `KUDGIVT.csv` の `対象乗務員CD` と突き合わせる。**食い違えば alc が古い**
3. **拘束そのものが桁違い** → 打刻を疑う。`day-events` で 始業/終業/運行開始/運行終了 を並べ、
   **始業→終業** と **始業→運行終了** をそれぞれ分で出すと、どちらが GCP・どちらがオンプレか一致する

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
営業所なら正常、本社なら欠落。**2026-08-04 に親がこれを取り違え、`1523` (本社) を
営業所と誤認して「余計な終業打刻を消せ」と誤った処方を書いた** (正しくは始業の欠落)。

**実例 (`1523 / 2026-04-23`、本社所属)**:

```
timecard 終業    2026-04-23 15:37:43   ← ★始業が欠けている
dtako   運行終了 2026-04-23 15:37:43
dtako   休息     2026-04-23 15:37:43
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

`/api/kintai/reading-dates?month=2026-05` (driver 省略 = 全乗務員) の実測:

```
総運行 1098 件
読取日 != 運行開始日                        580 件 (52.8%)
うち run_end_date == reading_date (日跨ぎ)   554 件
```

つまり**日跨ぎ勤務は翌日に読まれる**のが常態で、例外ではありません。

**実例 (1742 / 2026-05)** — 読取日 `05-30` に載っているのは **05-29 開始の運行**
(`2605290435180000001101`)。**1742 に 05-30 開始の運行は存在しません。**
さらに `04-30 / 05-06 / 05-19 / 05-25 / 05-29` は**読取日として 1 件も存在しない**ので、
その日を投入しようとしても何も起きません。

⇒ **「投入したのに差が残った」の第一容疑はこれ。** 効かなかったのではなく、
**狙った運行に当たっていない**。

**正しい順序:**

1. 差が出た暦日の勤務を作っている運行の `unko_no` を特定する
2. `/api/kintai/reading-dates?month=&driver=` の `items` で、**その `unko_no` の
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
  (`/kintai-relay/dtako-reimport` = オンプレ autoload 向けとの違い。あちらは 23 桁が要る)
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
(**時は 0 埋めなし**、`START_OPE_RE`)。オンプレの `unko_no` は 23 桁なので**末尾 1 桁を落とす**。

## 4.8 claude-in-chrome の使いどころと限界

- **小さい読み取り JS は即返る。fetch を含む大きい JS は 1 分半ハングして返らない**
  (2026-08-01 に 3 回再現)。**ブラウザで自動化を組むなら、fetch を JS 内で await しない**
- **`javascript_tool` は session/token を含む値の返却をブロックする** (`[BLOCKED: Sensitive key]`)。
  **ページ内で使うのは通る**ので、トークンを読み出さずに fetch させることはできる
- **オリジンをまたぐバイト列の受け渡しは URL fragment で運べる** (fragment はサーバに送られない)。
  ただし**ページが再読込されると消える**

## 5. rust-ichibanboshi の gate (踏むと確実に落ちます)

- **カバレッジ 100% gate**: `coverage_100.toml` に登録したファイルは 100% 行カバレッジ維持。
  CI が `scripts/check_coverage_100.sh` を回します。確認は `make cov-check` /
  `make cov-not100` / `make cov-file F=<名前>`。**テストは DB も環境変数も不要**
- **★ `tracing` マクロと `format!` を複数行にしないでください。** フォーマット文字列が
  独立行になると (手書きでも rustfmt の折り返しでも) その行が llvm-cov の行
  カバレッジに乗らず gate が落ちます。**このリポジトリで 4 回踏んでいます**
  - **★ 折り返しの閾値は 100 桁ではありません。実測で 81 文字程度から折れます**
    (2026-08-03、#620-1 で実測。「100 桁までなら 1 行に書ける」と見積もると踏みます)。
    **1 行に収める前提でメッセージを短くする**のが確実で、長い説明はコメントへ回してください
- **100% に到達したファイルは `coverage_100.toml` に足す。** ただし**実行行 0 のファイルは
  登録できません** (登録簿にあるのに計測データに現れないと fail)
- **`CLAUDE.md` は 50 行 / 2000 字が上限**。rust-ichibanboshi は既に 48 行 / 2800 字で
  **1 行足すだけで落ちます**。書き足したくなったら `.claude/skills/rust-ichibanboshi-map/`
  へ。詳細は `rust-ichibanboshi-map` skill 参照
- **`migrations/` の適用済み migration はコメント 1 文字でも変えない** (SHA-384 照合で loud fail)。
  適用 `make kintai-migrate` / 検証 `make kintai-rls-verify`。
  **新表の migration には `GRANT` を書く** (`GRANT ON ALL TABLES` は既存表だけのスナップショット。
  書き忘れて本番 502 になった。pg テストは所有者で繋ぐので権限を通りません)
- **★ `src/kosoku*` / `src/kintai*` / `src/routes/kintai*` を触ると `logic_version` が変わり、
  deploy で全乗務員が stale になります。** 収束に `run_kintai_recalc` を 3 ページ回す必要が
  出るので、触るファイル数は最小に。
  **`build.rs` の `KINTAI_OUTPUT_GLOBS` は `(ディレクトリ, ファイル名の接頭辞)`** で
  `("src","kosoku") / ("src","kintai") / ("src/routes","kintai")` の 3 つ。
  ⇒ **診断用の新しい口を足すときは `kintai`/`kosoku` で始まらない名前**
  (例 `src/routes/dtako_day.rs`) にすれば `logic_version` は動きません。
  抜け道ではなく正しい分類です — glob の目的は
  「`/api/kintai/{daily,kosoku-daily,version}` の**応答を形づくる**コード」なので。
  **既存ファイルを glob の外へ動かすのは `KINTAI_OUTPUT_REQUIRED` で落ちます**
- **ローカルで全体テストや `make cov-check` を回さないでください** (時間が溶けます)。
  **`cargo fmt --all` だけかけて push**。CI が postgres service 込みで回します
- `src/kintai_day_summaries.rs` が pg 無しで 57% に見えるのは**回帰ではありません**

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
