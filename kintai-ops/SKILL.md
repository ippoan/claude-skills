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
§4 の測定口は tailscale 経由の内部アドレスなので、**作業 PC 以外からは届きません。**

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

**`${ONPREM_KINTAI_API}` の実アドレスは、この repo には書きません** (社内 DNS /
tailscale の内部アドレスを docs に残さないため)。**値は memory の
`onprem-http-api-reachable-directly` にあります。** 無ければユーザーに聞いてください。

```bash
curl -s ${ONPREM_KINTAI_API}/health
curl -s "${ONPREM_KINTAI_API}/api/kintai/events?month=2026-06&driver=1078"   # driver 必須
curl -s "${ONPREM_KINTAI_API}/api/kintai/rest-diff?month=2026-06"            # driver 省略可
curl -s "${ONPREM_KINTAI_API}/api/kintai/reading-dates?month=2026-06"        # driver 省略可
curl -s "${ONPREM_KINTAI_API}/api/kintai/day-summaries?month=2026-06"
```

- **Cloudflare Access の 403 は edge (`rust-ichiban.mtamaramu.com` 経由) にだけ**効きます。
  tunnel を通らない直接続にサービストークンは要りません
- **新しい口を足したら、MCP tool の登録を待たずに deploy 後この `curl` で測れます**
- **★ 実アドレスを commit message / PR 本文 / docs / コード内コメントに書かないで
  ください** (ユーザー指示)。測定に使うのは可。**この skill 自身が repo に入るので、
  ここにも書きません**
- **`/health` の `backends` を 1 回読めば到達性が確定します。** config を読んで推論しない
  (`kintai_events: "mariadb"` の 1 行が「オンプレは alc を呼べない」を確定させ、
  親の設計案 2 つを同時に潰しました)

**★ MCP tool の登録はセッション開始時のスナップショットです。** `ToolSearch` は
スナップショットの中を検索するだけで、取り直しません。**自分で足した tool は自分では
呼べません。** 見えない tool があったらユーザーに connector 追加を頼むのが最短です
(走行中のセッションにも入ります)。

管理画面 `https://dtako.ippoan.org` — 運行一覧 / スクレイプ (読み取り日ベースのカレンダー) /
アップロード。ブラウザから `/api/proxy/api/operations/{22桁の運行NO}` で
`reading_date` / `operation_date` / `has_kudgivt` が引けます。

## 5. rust-ichibanboshi の gate (踏むと確実に落ちます)

- **カバレッジ 100% gate**: `coverage_100.toml` に登録したファイルは 100% 行カバレッジ維持。
  CI が `scripts/check_coverage_100.sh` を回します。確認は `make cov-check` /
  `make cov-not100` / `make cov-file F=<名前>`。**テストは DB も環境変数も不要**
- **★ `tracing` マクロと `format!` を複数行にしないでください。** フォーマット文字列が
  独立行になると (手書きでも rustfmt の 100 桁折り返しでも) その行が llvm-cov の行
  カバレッジに乗らず gate が落ちます。**このリポジトリで 4 回踏んでいます**
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
  出るので、触るファイル数は最小に
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

## 7. タスクフォルダ

走行中のタスクは **`/home/claude/claude260730/tasks/<番号>-<slug>.md`** で管理されています
(git の外・3 repo 共通・**作業 PC 限定**)。**自分のファイルがあれば読んでください** —
受け入れ条件の表と、親からの指示の変更履歴がそこにあります。**無ければ起動 prompt の
受け入れ条件が正本です** (上の「前提」参照)。

- **子は「子からの報告」節に追記します** (親への `send_message` と同じ内容で構いません)
- **受け入れ条件の表は親が書き、親が突き合わせます。** 子が編集しないでください
- **完了したファイルは親が消します。** 子は消さないでください

書式と運用は `/home/claude/claude260730/tasks/README.md` にあります。
