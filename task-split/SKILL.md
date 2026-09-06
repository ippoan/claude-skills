---
name: task-split
description: 大きな実装・修正・調査作業を PR サイズの独立タスクに分割し、spawn_task チップで worktree 別セッションとして並行起動する親側の運用。ユーザーが「tasks に分けて」「タスクに分割」「並行でやって」「別セッションで起動」「チップにして」と言ったとき、設計 review の実装フェーズに入るとき、または 2 PR 以上に分かれる規模の作業を任されたときに必ず使う。各タスクへの親子通信プロトコルの埋め込みと、起動後の交通整理・マージ順の采配までがこの skill の範囲。
---

# task-split — 分割起動と交通整理 (親側)

大きな作業を spawn_task チップに分割し、worktree 独立セッションで並行実装させる。
このセッション (親) は実装せず、**分割・調整・マージ順の采配**に徹する。

## 0. 前提

分割対象の作業内容 (設計 review の結論、修正一覧など) が会話に既にあること。
無ければ先に調査・設計をやってから戻ってくる。

**分割案は起票前に `simplify-reviewer` に通す** ([[simplify-review]])。hook が spawn_task を
未通過のあいだ deny する。「1 画面 1 PR」型の分割はここで [MAJOR] が付く。

## 1. 親が `#p<issue>` を名乗る

子は起動 prompt しか受け取らない。子が親へ報告を返すには **親セッションのタイトル**が
逆引きキーになる (子は `mcp__ccd_session_mgmt__list_sessions` でタイトル一致から
sessionId を引く)。**逆引きキーは案件ごとに 1 本だけ**にする。

### 命名規約 (ユーザー指示 2026-08-25)

| 役 | タイトルの形 | 例 |
|---|---|---|
| 親 (監督) | `#p<issue> <短い題>` | `#p874 netprint の監督` |
| 子 — 親と同じ issue の枝 | `[S]`/`[O]` + `#c<親issue>-<分岐番号> <短い題>` | `[S] #c874-12 通知先を画面から設定する` |
| 子 — **自分の issue を持つ** | `[S]`/`[O]` + `#p<親issue>-c<子issue> <短い題>` | `[S] #p874-c987 Secrets Store の掃除` |
| 交代前の旧親 | `[旧] #p<issue> <短い題>` | `[旧] #p874 netprint の監督` |

`#p` / `#c` で親子が一目で分かり、`<issue>` が一致するものだけが同じ案件。
一覧に複数案件の親子が並んでも、どの子がどの親に属すかを突き合わせ無しで読める。

**子の issue が親と分かれるときは `#p<親issue>-c<子issue>`** (ユーザー指示 2026-08-25)。
`#c874-12` の `12` は**分岐番号**、`#p874-c987` の `987` は**子自身の issue 番号**で、
`#p` が前置されているかどうかで読み分ける。番号だけ見て取り違えないこと。
子の issue の下でさらに PR が分かれるなら末尾に分岐番号を足す (`#p874-c987-2`)。

### ★ 親の判定は「`#p<issue>` の直後がスペース」

`#p874-c987` は「`#p874` で始まる」を満たしてしまう。**前方一致だけで親を探すと、
兄弟の子が互いを親と誤認する** (`list_sessions` は自分を除外するので自分は引かないが、
隣の子は引けてしまう)。したがって判定はこう書く:

- **親** = `#p<issue>` の**直後がスペース**のもの (`#p874 …`)。`[旧]` 付きは除く
- **子** = `#c<親issue>-…` または `#p<親issue>-c…`

`<issue>` の前方一致だけで済ませない — `#p87` が `#p874` を引くのも同じ穴。

**`#p<issue>` は世代が変わっても不変。** 親を何度引き継いでも子の逆引きキーは同じ
文字列のままなので、**配り終えた prompt を書き直さなくてよく、走行中の子への
「親交代」通知も要らない**。旧親には `[旧] ` を前置するため、
「`#p<issue>` + スペースで始まるタイトル」は常に現役の親 1 件だけを指す。

- **★ 親の 2 手目**: **[[parent-fanout]] を読む。** 分割前の**調査**と、子の [完了] 後の
  **裏取り**は、read-only の subagent (`task-surveyor` / `child-auditor`) へ並列に
  逃がせる。**逃がさないと親が 1 本のままボトルネックになる** — 子が同時に終わると
  N 件の検証が直列で待つ (実害 2026-08-27: 監督 1 世代ぶん、裏取りを全部親が直列でやった)。
  **親に残すのは決定だけ** (分割・マージ順・go・PR 作成・archive)。
- **親の最初の一手**: `mcp__ccd_session_mgmt__set_session_title` を
  `session_id: "self"` で呼んで `#p<issue> <短い題>` を名乗る。
  **`"self"` は受け付けられる** (実測 2026-08-25。ここに以前
  「`set_session_title` は自分を拒否する」と書いてあったのは誤り)。
  自分で名乗れば自分のタイトルが確定するので、**「最初の子に逆引きキーを聞き返す」
  手順は不要**になった。
- **自分の sessionId は自分では取得できない。**
  `list_sessions` は自セッションを除外し、`get_session` も自分を拒否する。
  取れないのは **ID とタイトルの「読み」**で、**タイトルの「書き」だけが例外**。
- **sessionId を prompt に埋めない。** `scratchpad` ディレクトリの UUID も
  `~/.claude/sessions/*.json` の `sessionId` も**別物** (後者は transcript の ID) で、
  `local_` を付けても `send_message` の宛先にならず子から `not found` が返る
  (実害 2026-07-31、2 タスクとも同じ失敗)。**prompt には ID ではなく判別条件を書く**:
  > 報告は `list_sessions` でタイトル逆引き。宛先は
  > **`#p\<issue\>` の直後がスペースのタイトル**を持つセッション
  > (`[旧]` 付きは交代前の旧親、`#p\<issue\>-c…` は兄弟の子。どちらも送らない)。
- **旧親が一覧に残っていても誤配しない。** 後継が起動時に旧親を
  `[旧] #p<issue> …` へ改名するのが交代手順に入っているため
  (手順は [[next-session]] の「監督役の交代」)。
  **規約の移行中で、旧形式のタイトルを prompt に持つ子が走っている間だけ**は、
  1 回だけ「新しい判別条件は `#p<issue>` + スペースで始まるタイトル」を通知する。

## 2. 分割の原則

- **名前は `#c<親issue>-<分岐番号> <短い題>`** (子が自分の issue を持つなら
  `#p<親issue>-c<子issue> <短い題>`。§1 の命名規約)。spawn_task の title に必ず
  この形で付ける (例: 「#c205-1 fold の読み分離と unnest 化」)。
  分岐番号は依存順 (= マージ順) と
  一致させる。同じ `<issue>-<番号>` キーを worktree の branch 名
  (`fix/<issue>-<番号>-<slug>` 等)・テスト DB コンテナ名・子からの報告の名乗りまで
  一気通貫で使う (branch 名やコンテナ名には `#c` を付けず `<issue>-<番号>` だけを
  使う) — どの PR / セッション / コンテナがどのタスクかを突き合わせ無しで
  読めるようにするため。対応する issue が無い作業は先に issue を立てる。
- **1 タスク = 1 PR。** レビューできる大きさに切る。
- **依存順を決めて番号を振る。** どれが先にマージされるかを全 prompt に書く。
- **ファイル所有権を割る。** 同じファイルを 2 タスクが触るなら、(a) 関数・節単位で
  所有を分けて互いの領分を「触らない」と明記するか、(b) 後発を「draft で出し、
  先行マージ後に rebase して ready」運用にする。worktree は起動時点の main から
  分岐するので、衝突を防げるのは**起動前の所有権設計だけ**。
- 独立にテスト・CI が通る切り方を優先する。依存タスクの未マージ変更を前提にしない。

## 3. spawn_task の prompt は自己完結で書く

子にはこの会話のコンテキストが**一切届かない**。足りない文脈は子が推測して事故る。
各 prompt に必ず含める:

0. **手順 0 で `set_session_title { session_id: "self", title: "<チップと同じタイトル>" }` を打たせる**
   (hook が子と認識するため。**アプリがチップに付けたタイトルは hook を通らない** — §4.5)
1. repo と、作業 branch 名 (`fix/<issue>-<分岐番号>-<slug>` の形で指定)、
   対象ファイルと行番号
2. 変更内容と**理由 (why)** — 「何をするか」だけだと子が別解に流れる
3. 制約 (触ってはいけないファイル・プロジェクト固有の罠・CI の gate)
4. テストの期待と、**「branch push まで。PR は親が作るので、子は `gh pr create` を
   打たない」** の指示 (交通整理の節)。**「go が来てから作る」と書かない** — 子が
   自分で作ってよいと読める (2026-08-22 の実害。分類器に弾かれる)。Refs する issue 番号。

4.5 **★ 実機確認の「いつ・誰が・どこで」を prompt に書く (2026-08-22、オーナー指示)。**
   **チップを作る前に親が決めること。** 書かないと子が終わり際に dev を立てようとし、
   `npm install` の E401 で詰まり、`gh auth refresh` を頼み、Chrome が届かないと悩み、
   最後に「どうしますか」と聞いてくる — **全部、最初に決めていれば発生しない手間。**

   **決め方は repo の deploy 経路で機械的に決まる。まず auto tag かを確認する:**

   ```
   gh run list --repo <repo> --workflow "Tag Release" --limit 5 --json event,conclusion
   gh api repos/<repo>/tags --jq '.[0:4][]|.name'
   ```

   | deploy | 実機確認の決め方 |
   |---|---|
   | **auto tag** (merge → 自動タグ → 数十秒で本番) | **マージ後・本番・親がやる。** 子は「実機確認は親がやる。dev も preview も触らない」と prompt に書いて渡す |
   | 手動タグ / flip が要る | マージ前に staging か dev。誰が踏むかまで prompt に書く |

   **preview は agent の選択肢に入れない** — 別の認証レルムだと Google ログインを
   代行できず必ず詰まる (`nuxt-dtako-admin` の `auth-staging` で実害)。
   **人間の pre-PR 目視用**であって、agent の実機確認手段ではない。DB 相手のテストがあるなら
   **専用コンテナの起動コマンドと接続 env var** まで書く (「共有ローカル資源」の節)
5. 他タスクとの調整: 所有権の割り当て、マージ順、draft/ready の指定
6. 末尾に**親への報告**節:
   > 作業の開始時・判断に迷ったとき・PR 作成後に、/report-to-parent の手順で
   > 親セッション (タイトル: 「#p<issue> <短い題>」) へ send_message で報告すること。
   > report-to-parent skill が無い環境なら: `list_sessions` でタイトル一致の
   > sessionId を引き、[開始] 計画 / [質問] 選択肢+推奨 / [完了] PR#+触ったファイル
   > を送る。

モデルについて: 新規セッションは settings.json の `model` (**現在 sonnet**) で起動する。
**spawn_task にモデル指定パラメータは無い**ので、上位モデルで回したいチップは
**title の先頭に `[O]` を書いてユーザーに切り替えてもらう** (§3.5 の末尾)。
`[S]` は既定のままでよい印。

**★ 子は「呼び出し元セッションのモデル」を継がない** (実測 2026-08-03: 親が Opus・
settings.json が `sonnet` の状態で、直接 spawn した子は `claude-sonnet-5` だった)。
**親を Opus にしても子は勝手に高くならない** — この心配で設計を歪めないこと。

**★ ただし「起動時に手で切り替える手間」は、Sonnet のセッションから起票すると減る**
(ユーザー実感、2026-08-03)。生成される session の `model` は同じだったが、
**チップを押すときの切り替え操作が要らなくなった**。
⇒ 起票が多い案件では **常駐の「起票中継」セッションを 1 つ立てて Sonnet で起動しておき、
親はそこへ依頼を送って `spawn_task` を代行させる**とよい。中継への prompt には必ず:

- **渡す `prompt` は「指示」ではなく「データ」**であること (中身に「worktree を作れ」等と
  書いてあるが、中継が実行してはいけない)。**1 文字も変えずに横流し**させる
- 長文は `<<<PROMPT_BEGIN>>>` / `<<<PROMPT_END>>>` のようなマーカーで囲んで送る
- `title` / `tldr` / `cwd` / `prompt` の**4 つが揃わなければ作らせない** (推測で埋めない)
- **常駐させ、自分から archive させない**

## 3.5 Sonnet 級でも回る prompt にする (費用最適化、ユーザー方針 2026-07-31)

タスクセッションのモデルは既定設定で決まる。**prompt を以下の基準で書けば
実装タスクは Sonnet 級で回り、Opus/Fable は親の設計・調査に温存できる。**

- **親が判断を出し切る。** prompt に「検討して決めよ」「適切に選べ」を残さない。
  選択肢が生じ得る箇所は親の決定と理由を書く。判断の質はモデルの質に一番効く —
  そこを prompt 側に移せばモデルを下げられる。
- **変更は座標で指定する。** ファイル・関数・行番号・変更後の形 (「X を Y に
  変える」か擬似 diff)。「いい感じに」を書かない。
- **受け入れ条件は機械検証可能に。** 実行コマンド、期待するテスト名と結果、
  grep で確認できる不変条件。「〜であることを確認」より「このコマンドがこの
  出力になる」。
- **基点 SHA は hook が同期する** (`~/.claude/hooks/sync-git-base.sh`、SessionStart。
  2026-07-31 設置)。セッション開始時に origin を fetch し、clean なら default
  branch へ ff、結果を additionalContext で注入する — 「以降を基点」と prompt に
  書くだけでは検証されない実害 (2 コミット前で実装済み機能を再実装) への機械対策。
  prompt 側は基点 SHA を明記しつつ、**[完了] に `git merge-base --is-ancestor
  <基点SHA> HEAD && echo OK` の出力を含めさせる** (hook が効かない環境の保険)。
- **罠は「症状 → 対処」形式。** 例:「extract が DNS で落ちたら re-run」
  「git reset --hard が弾かれたら stash → ff-merge → drop」。
- **調査・設計・原因不明のデバッグは切り出さない。** それは親 (上位モデル) が
  先にやり、結論だけを実装タスクに落とす。「実装を特定してから直す」型の
  タスクは上位モデルに残すか、調査フェーズを親が済ませて座標化する。
- **[質問] エスカレーションを強調する。** 「迷ったら決めずに親へ」が下位モデル
  運用の安全弁。自信の無い独自判断より質問の方が安い。
- **高価な呼び出しの回数上限を prompt に書く。** 1 呼び数十秒の API (本番経路・
  R2 掃引つき等) を子が分析目的の二分探索・全数掃引に使うと、時間もトークンも
  溶ける (実害 2026-07-31: 30〜60s/呼の preview API で行差分の局在化を掃引)。
  「この API は 1 呼 N 秒。手順に無い呼び出しを M 回超えそうなら設計を変えて
  [質問]」と書く。局在化・原因究明はローカルで再現できる場所 (fixture +
  実 DB コンテナ) に移すのが原則。

**推奨モデルは title の先頭に `[S]` / `[O]` で書く** (ユーザー指示 2026-07-31)。

```
[S] #c205-17 recalc_month も warnings が出た回は指紋を刻まない
[O] #c205-19 142 行差の原因究明 (ローカル再現)
```

`[S]` = Sonnet で回る (既定のまま起動してよい) / `[O]` = Opus 推奨
(ユーザーが起動時に UI で切り替える)。**末尾に「Opus 推奨」と書く形は使わない** —
チップ一覧では末尾が切れて見えないことがあり、**起動する瞬間に目に入る位置**である
必要がある。番号 (`#c<issue>-<分岐>`) はその直後に置き、対応関係は従来どおり。

判定の目安: 座標 + 決定 + テスト境界まで書けた → **`[S]`**。
「〜の実装を特定して」「原因を突き止めて」が残っている、設計判断を子に委ねる部分が
ある → **`[O]`**。迷ったら `[O]` (下位モデルで judgment を要求する方が高くつく)。

**go 前の裏取り (Sonnet 運用のガードレール、実測 2026-07-31)**: 子は機械証明の
要求 (merge-base の出力貼付など) をスルーすることがある。親は go を出す前に
compare API 1 発で裏を取る:
`gh api "repos/<owner>/<repo>/compare/<基点SHA>...<branch>" --jq '{status,ahead_by,behind_by,files:[.files[].filename]}'`
— behind_by 0 (基点が祖先) と、変更ファイルが [完了] の申告どおりかを見る。

## 4. worktree の扱い

- **分離は自動 — ただし cwd が repo のときだけ。** spawn_task に `cwd` (対象 repo の
  パス) を**必ず渡す** — hook (`require-spawn-task-cwd.sh`、2026-07-31 設置) が
  **cwd 無し / 実在しないパスの起票を機械的に拒否**する。repo を触らないタスクも
  作業ディレクトリを明示する (暗黙の継承は禁止)。親の cwd が repo 外だとチップは worktree 無しで起動し、
  main clone を共有編集する (実害 2026-07-31: 2 タスクが同一 checkout で同じ
  ファイルを併行編集し変更が混在)。
- **prompt の手順 0 に worktree 作成を明記する** (cwd 指定の保険):
  「最初に `git worktree add <自分のscratchpad>/wt-<task> -b <branch> origin/main`
  で自分の worktree を作り、以後そこでだけ作業。main clone への書き込み禁止」。
- **機械的な強制**: PreToolUse hook (`~/.claude/hooks/block-main-clone-writes.sh`、
  2026-07-31 設置) が **main clone (.git がディレクトリ) への Edit/Write を全
  セッションで拒否**する。worktree (.git がファイル) は許可 = 作成者だけが使うので
  所有権が成立。保守で main clone を書く必要があるときだけ
  `<repo>/.claude/allow-main-writes` を作る (終わったら削除)。Bash 経由の書き込み
  (sed -i 等) までは防げない — prompt の禁止指示と併用する。
  **★ この hook は worktree を許可する** (= 作成者だけが使う所有権の強制) ので、
  **親が自分で worktree を作って実装する**のは止められない。それを塞ぐのは §4.5 の
  `block-parent-repo-writes.sh` (目的が違うので両方置く)。
- **分岐点は起動時点の default branch。** 兄弟タスクの未マージ PR は worktree に
  存在しない — これが後発タスクを draft→rebase 運用にする理由。先行 PR の変更を
  前提にしたコードは、rebase 後に結線する形で書かせる。
- **rebase は子の worktree 内で完結させる。** 先行 PR がマージされたら、親が後発の
  子へ send_message で「main を fetch して rebase → ready 化」を指示する。
  親が子の worktree を直接触らない (2 セッションが同じ tree を書くと壊れる)。
- **掃除は PR の状態で判断する。** マージ後に `git worktree remove` + `git branch -D`。
  **squash merge だと `git merge-base --is-ancestor` では merged と判定できない** —
  必ず PR の状態 (MERGED) で見る。掃除は子の [完了] 後に親が指示するか、全タスク
  完了後にまとめてやる。あわせて `archive_session` で終わったセッションを畳む。
- **remote branch は repo 設定に任せる。** `delete_branch_on_merge` を on にしておけば
  merge 主体 (workflow / 人) に関係なく自動削除される。off のまま子に
  `push --delete` させると merged-PR ガード系の hook に弾かれがち — その場合も
  hook を迂回させず、親が API (`gh api -X DELETE .../git/refs/heads/<branch>`) で消す。
- **チップが main clone で走ることもある** (実測: 4 並行中 1 つは worktree ではなく
  main clone だった)。子の終了手順は cwd で分岐 — worktree なら remove、main clone
  なら `git checkout main` + `git pull --ff-only` で原状復帰してから branch -D。

## 4.5 機械的な栓 (hook) — 親は実装せず、子はユーザーに聞かない

機械的な栓が 4 本ある。**読了チェックは不読を防ぐだけで違反を防げない** — 2026-09-05、
`#p134` の監督 (親) セッションが自分で migration SQL を書き、postgres を立て、commit しようとして
ユーザーに止められた。その親は task-split の「**このセッション (親) は実装せず**」を
**読了して引用まで提出していた** (Refs ippoan/claude-skills#152)。だから口そのものを塞ぐ。

`parent-role/hooks/` の 4 本を `~/.claude/hooks/` へ symlink し、`~/.claude/settings.json` に登録する。

### hook 4 本 (`parent-role/hooks/`)

| hook | matcher | 何をするか | fail-open |
|---|---|---|---|
| `session-role-log.sh` | `mcp__ccd_session_mgmt__set_session_title` | `tool_input.session_id == "self"` のときだけ、title から役を判定して marker を立てる。**塞がない** | — (常に素通し) |
| `block-parent-repo-writes.sh` | `Edit` / `Write` / `NotebookEdit` | parent marker 有 + 書き先の上流に `.git` (**ファイル = worktree / ディレクトリ = main clone のどちらでも**) → **deny** | parent marker が無ければ素通し |
| `block-parent-commits.sh` | `Bash` | parent marker 有 + `git commit` / `push` / `apply` / `am` / `cherry-pick` → **deny**。`gh pr create` / `gh issue create` / `gh issue comment` / `git branch -D` / `git worktree add`\|`remove`\|`list` / 読み取り系はすべて**許可** | 同上 |
| `block-child-asks-user.sh` | `AskUserQuestion` | child marker 有 → **deny** (親へ `send_message` の `[質問]` に寄せる) | child marker が無ければ素通し |

**「書き込み全部禁止」にはしていない。** 親は scratchpad に計画を書き、memory を更新し、
**PR を作り**、マージ後に **branch を掃除する**必要がある。塞ぐのは
「repo の作業ツリーへの書き込み」と「commit/push」だけ。

### marker の立て方 — title が唯一の判定材料

★ `~/.claude/sessions/*.json` に **title は無い** (2026-09-05 実測。keys は親子で完全同一で、
「spawn_task で起動された」ことを示す欄も無い)。**title を hook が知れるのは
`set_session_title` の瞬間だけ**なので、親も子も**手順 0 で自分を名乗る**必要がある。

| title (命名規約は task-split §1) | marker |
|---|---|
| `^#p[0-9]+ ` (★ 直後がスペース) | `~/.claude/state/parent-role/<session_id>` を作り、child marker を消す |
| `#c[0-9]+-` または `#p[0-9]+-c` を含む | `~/.claude/state/child-role/<session_id>` を作り、parent marker を消す |
| `^\[旧\] #p` | 両方消す (交代した旧親はどちらの役でもない) |

**チップがアプリ側で付けたタイトルは hook を通らない。** だから子の prompt には
「手順 0 で `set_session_title { session_id: "self", title: "<チップと同じタイトル>" }` を打つ」
を必ず書く。同じ文字列への改名は no-op なので害は無い。
**名乗らなかったセッションは marker が立たず素通し** (誤爆より取りこぼしを選ぶ。
`require-simplify-review.sh` の「session_id が取れない payload も素通し」と同じ方針)。

### escape hatch (どちらも終わったら消す)

| 状況 | 作るファイル |
|---|---|
| 親がどうしても repo を直接書く / commit する | `~/.claude/state/parent-role/<session_id>.override` |
| 親が居ない単独セッションでユーザーに聞きたい | `~/.claude/state/child-may-ask/<session_id>` |

### サブエージェント経由は「穴」ではなく逃げ道 (オーナー判断 2026-09-05)

hook は `session_id` を鍵にするので、**Agent tool のサブエージェントは別 session で走り
親の marker を持たない** → B/C を素通しする。**これは塞がない。** 親が「書きたいもの」を
抱えたときの正しい形が background の `Agent` だから — **親の turn が空くのでユーザーの指示に
常に応答できる**。`task-surveyor` / `child-auditor` / `simplify-reviewer` はいずれも read-only で、
marker を伝播させると**調査すらできなくなる**。**deliberate と accidental を分けるのが hook の役目。**

⇒ deny されたときの行き先は 3 つ (deny の文言にも書いてある):

- **repo の変更 (PR になるもの)** → `spawn_task` でチップにする (worktree・branch・CI が付く)
- **repo 外の成果物 (計画・PR 本文・issue 本文・memory)** → そのまま書ける
- **調査・裏取り** → `Agent` を **`run_in_background: true`** で (親の turn を止めない)

### 限界 (承知の上で入れている)

- **Bash の `sed -i` / `cat > file` は取りこぼす** (`block-main-clone-writes.sh` と同じ)。
  ただし `block-parent-commits.sh` が commit/push を止めるので、成果物として repo の外へは出ない
- **permission プロンプトは hook で消せない。** ツール承認・`archive_session` の確認は設計上
  ユーザーに出る。「子からの割り込み」を 0 にはできない
- **敵対的な回避を防ぐ機能ではない** (marker は自己申告)。塞ぐ対象は
  「**うっかり inline で書き始める**」経路
- 既存の `block-main-clone-writes.sh` は **worktree を許可**するので 2026-09-05 の事故を
  止められなかった (親が自分で worktree を作った)。**目的が違うので消さないこと** —
  あちらは「main clone は誰も書かない」、`block-parent-repo-writes.sh` は「親は repo を書かない」
- 子の判定に **cwd (worktree に居る = 子) は使っていない** (オーナー判断 2026-09-05)。
  ユーザーが自分で worktree に開いたセッションまで `AskUserQuestion` を失うため。
  **タイトルに `c` が入るのが子**なので陽性判定で足りる

### インストール (★ この repo は hook を**置くだけ**。symlink と登録は親かユーザーが打つ)

```bash
ln -sfn <claude-skills>/parent-role/hooks/session-role-log.sh         ~/.claude/hooks/session-role-log.sh
ln -sfn <claude-skills>/parent-role/hooks/block-parent-repo-writes.sh ~/.claude/hooks/block-parent-repo-writes.sh
ln -sfn <claude-skills>/parent-role/hooks/block-parent-commits.sh     ~/.claude/hooks/block-parent-commits.sh
ln -sfn <claude-skills>/parent-role/hooks/block-child-asks-user.sh    ~/.claude/hooks/block-child-asks-user.sh
```

`~/.claude/settings.json` の `PreToolUse` 配列に足す (既に `PreToolUse` があれば配列へ追記):

```json
"PreToolUse": [
  { "matcher": "mcp__ccd_session_mgmt__set_session_title",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/session-role-log.sh", "timeout": 10 }] },
  { "matcher": "Edit|Write|NotebookEdit",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/block-parent-repo-writes.sh", "timeout": 10,
                "statusMessage": "親セッションの repo 書き込みか確認中" }] },
  { "matcher": "Bash",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/block-parent-commits.sh", "timeout": 10,
                "statusMessage": "親セッションの commit/push か確認中" }] },
  { "matcher": "AskUserQuestion",
    "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/block-child-asks-user.sh", "timeout": 10 }] }
]
```

受け入れテスト: `bash <claude-skills>/parent-role/hooks/test-parent-role-hooks.sh`
(`HOME` を一時ディレクトリへ差し替えて回すので、実物の `~/.claude/state/` は汚さない)。

## 5. 共有ローカル資源 (DB / Docker / ポート)

worktree が分離するのは**ファイルだけ**。DB・Docker コンテナ・ホストポート・
グローバルキャッシュはマシン共有で、並行タスクの取り合いは worktree では防げない。

- **テスト DB はタスクごとに専用コンテナ。** 名前に `<issue>-<分岐番号>` を入れ
  (例: `kintai-pg-205-3`)、ホストポートは
  固定せずエフェメラルにする (`docker run -p 127.0.0.1::5432 ...` → `docker port` で
  取得して接続 env var に入れる)。固定ポートで既に動いているコンテナは**他セッション・
  他調査の持ち物** — 繋がない・消さない。起動前に `docker ps` で現状を見て、既存
  コンテナの一覧を「触らないもの」として各 prompt に書く。
- **「env 未設定で skip」型のテスト gate に注意。** DB 系テストは接続先が無いと
  丸ごと skip されて**緑のまま検証ゼロ**になる作りが多い。prompt に「DB テストが
  実際に走ったこと (skip でないこと) をログで確認し [完了] に書く」まで含める。
- **掃除は自分のぶんだけ。** 子はタスク終了時に自分のコンテナを `docker rm -f`。
  親は全タスク完了後に `docker ps` で残骸を確認する。
- 分離できない共有資源 (実機 DB・外部サービス・固定ポートの常駐物) は**所有権を
  1 タスクに割り当て**、他タスクは mock にするか、[質問] で親に使用の順番を取らせる。
- **MCP connector はチップセッションに引き継がれない** (実測 2026-07-31: 親に見える
  kyuyo-mcp / GitHub / Cloudflare 系 connector が子には無く、既定セットだけだった)。
  MCP tool 依存の手順をタスクに切り出すと子は実行できない — その工程は親セッション
  かユーザー実行に残し、子には「結果を親経由で受け取って記録・判定する」役を割る。
  prompt を書く前に「この手順の tool は子に在るか」を確認すること。

## 6. 起動後の交通整理 (親のしごと)

- 返ってきた task_id を控える。分割し直したら古いチップを `dismiss_task`。
- ユーザーがチップを起動すると子が `list_sessions` に現れる。追加指示は
  `send_message` (子の in-flight turn の後に届く)。

### ★★ 依頼のメッセージには `origin/main` の SHA を 1 行入れる (交差の機械的な検出)

**親の指示と子の push は普通に交差する。** そのとき親が書きがちなのが**状態語**:

> 「#1019 が **CI 実行中**で、マージされると main がもう一度動くので待って」

**これは子が受け取った時点で偽になっていることがある。** 実際、#760 の監督で
**1 日に 3 回**交差し、3 回目はこの形だった (子が受け取ったときには既にマージ済み)。

**⇒ 状態ではなく SHA を書く:**

> **この指示を書いた時点の `origin/main` = `f1b30ce4467acc784c19f0acb3fff06592e6bc9e`**

子は受け取った瞬間に `git ls-remote origin main` と突き合わせ、**実行前に交差を検出できる。**
採用した直後の 1 通で、子が「一致 (交差なし)」を確認してから動いた。**3 回とも防げた形。**

**子側の受け方は [[report-to-parent]] に書いてある。** 親はこの 1 行を書くだけでよい。

**あわせて**: **1 通 = 1 意図。** 追加作業を頼むメッセージに「凍結」を混ぜない
(子から見ると「やれ」と「止まれ」が同時に来る)。**依頼の完了報告を受けてから凍結を宣言する。**

### ★ 子の状態を「報告」から推し量らない — 毎回 `list_sessions` を見る

**子の報告は「何をしたか」しか教えず、「いま動いているか」は教えない。**
報告が来ないことを「まだ動いている」と読むと、**終わっている子を待ち続けて archive を落とす。**

**実害 (2026-08-26)**: 親が 2 件の子を「待機中」とユーザーに報告したが、**両方とも PR マージ・
本番確認まで終わっていた**。さらに 1 件は**掃除まで済ませて archive だけ落としていた**のに、
親はそれに気づかず「待ち」と言い続けた。ユーザーの「結局、子が動いてるか分かんないの？」で発覚。

⇒ **子の状態を口にする前に `list_sessions` を見る** (`isRunning` / `lastActivityAt`)。

**機械的な補助 (2026-08-26 設置)**: `UserPromptSubmit` hook
`~/.claude/hooks/list-child-sessions.sh` が、`~/.claude/sessions/*.json` の **pid の生死**を
毎ターン文脈へ注入する (対象 repo の worktree に居るセッションのみ。他 repo では黙る)。

hook が出す 3 つの信号:

| 信号 | 何が分かるか |
|---|---|
| **pid の生死** | プロセスが在るか |
| **最終活動からの経過** (transcript `.jsonl` の mtime) | **これが主信号。**「終わったか」はこれで見る |
| **CPU (0.3 秒の実測)** | いま計算しているか。**補助** |

**★ `CPU 0` は「暇」を意味しない** — **API 応答待ちのセッションは CPU を使わないまま働いている。**
CPU は「いま動いている」の**陽性証拠**にしかならず、0 を「終わった」の根拠にしてはいけない。
**終わったかどうかは経過時間で判断する。**

**★ hook は archive 済みかどうかを答えられない** (MCP でしか取れない)。
`list_sessions` の代わりにはならず、**畳む前に `list_sessions` で裏を取る。**
- 子からの **[質問]** には親の文脈 (他タスクとの整合) で即答する。
- **PR の順番は親が統制する — 栓は「PR 作成のタイミング」** (ユーザー指示 2026-07-31)。
  子は実装 + ローカル検証まで終えたら **branch を push するだけで PR は作らず**
  [完了] を報告する (branch push では CI は走らない — push trigger は通常 main のみ)。
  親が依存順に「PR 作成 go」を出し、**PR は親が ready で作成**する
  → CI 1 回 → auto-merge が green で即 merge。後発には先行の
  merge 確認後に「rebase → PR 作成 go」。**CI は PR ごとに 1 回しか回らない。**

  **★ 子に `gh pr create` を打たせない (2026-08-22 に実害)。** 「子 (セッション終了済みなら
  親) が作成」と書いていたため、親が「ready で作ってください」と指示してしまった。
  **子セッションでは分類器に拒否される** — #760 の 2 タスクのうち 1 つが実際に弾かれ、
  もう 1 つはたまたま通って**同じ案件で挙動が割れた**。repo 固有 skill
  (`kintai-ops` の「`gh pr create` を実行しないでください / PR は親が作ります」) が
  正しく、こちらの記述が緩かった。**repo 固有 skill と食い違ったら repo 固有が優先。**
- **draft を栓に使わない (却下済み)。** この org の auto-merge reusable
  (ippoan/ci-workflows) は job の `if: draft == false` で draft を skip し、
  caller の `on: pull_request` に `ready_for_review` type が無いため ready 化では
  再発火しない。event が凍結されるので job の rerun も不発 — 動かすには CI 丸ごと
  再実行 = 二重になる。誤って draft で作ってしまった PR は、checks green を確認して
  親が `gh pr merge --squash` を直接打って回収する。
- **[完了]** 報告か harness の終了通知が来たら: PR を確認し、マージ順に従って
  後続タスクへ rebase / ready 化を指示する。
- **★★ archive は「親が子の状況を確認して打つ」** (ユーザー指示 2026-08-22)。
  **子に self-archive させない。子にユーザーへ確認させない。**
  子側の [[report-to-parent]] にも同じ規約が書いてある — **片方だけ直さないこと**
  (子 skill が「子が畳むタイミングを握る」と書いていた時期があり、その文言を読んだ
  親が子へ self-archive を指示した実害 2026-08-25)。
  **「子にユーザーへ確認させない」は §4.5 の `block-child-asks-user.sh` が機械的に塞ぐ。**
  §4.5 の本文は [[report-to-parent]] と**同一文**で置いてある — こちらも片方だけ直さないこと。

  子は `[完了]` に**掃除まで終えたこと**を書いて終わる。そこから先は親の仕事:

  1. 親が基準 3 点を裏取りする — ①PR が MERGED (**全部の repo で**)、②掃除完了
     (worktree / コンテナ / local branch。**remote は `delete_branch_on_merge` で自動削除**)、
     ③未消化の申し送り無し (あるならチップ化済み or 次タスクの prompt に渡した)
  2. **子がまだ動いていないこと**を `list_sessions` の `lastActivityAt` / `isRunning` で見る
     (子は `[完了]` 後に自発的な精査を続けることがある。実害 2026-07-31)
  3. **親が `archive_session` を打つ**

  **★ 「アプリの Auto-archive on PR close に任せる」と判断しないこと** (2026-08-22 の実害)。
  設定が効いていても、**親が状況を確認して畳むのがユーザーの指示**。自動で畳まれた結果を
  見て「では何もしなくてよい」と読み替えるのは、確認工程を勝手に省くのと同じ。

  なお `archive_session` は self 含め**毎回ユーザー承認プロンプトが出る**
  (permission mode に関係なく必須)。**これは省く理由にならない** — プロンプトが出ることと、
  親が状況を確認することは別の話。

  取りこぼし条件も覚えておく: セッションに紐づく `prNumber` が**起動 repo と別 repo の PR**
  だと自動側は拾わない (実害 2026-07-31: 2 repo にまたがるタスクが畳まれ残った)。
- **hook では解けない。** archive は MCP tool 経由でユーザー承認が要るので、
  Stop / SessionEnd hook から自動実行できない。`~/.claude/sessions/*.json` にも
  archive 状態は無い (pid と cwd だけ)。**このプロトコルが唯一の機械的な栓**。
- **畳むのは常に親** (上の ★★)。ただし **`[完了]` 受領だけで打たない** — 子は
  `[完了]` 後に自発的な精査を続けることがある (実害 2026-07-31: キー衝突の調査続行中に
  親が archive して中断させた)。**打つ前に `list_sessions` の `lastActivityAt` /
  `isRunning` で活動停止を確認する。** これが「状況確認」の中身であって、
  **子やユーザーに「畳んでよいか」と聞くことではない。**
- **★ アプリが親の `archive_session` を拒否したとき** (実害 2026-09-06、
  ippoan/alc-app-s3#134 の #p134 第 8 世代)。ユーザーが子のタブを開いていると、
  基準 3 点と活動停止を確認済みでも、アプリが
  「was not archived: the app is keeping it for the user (pinned or in use). Wait or
  ask the user; they can also archive it from the sidebar.」で拒否する。この文言が
  返ったら:
  1. **親の再試行は 1 回まで**。同じ拒否が 2 回続いたら打ち続けない
  2. ユーザーに 3 択を提示する — 子のタブを閉じる / サイドバーから archive する /
     子に self-archive させる
  3. ユーザーが「子に archive させろ」と言ったら、親は子へ `send_message` で
     **`[決定] ユーザー指示で self-archive`** を送る。文面に
     「`archive_session { session_id: "self" }` を呼ぶ。『畳みます』と書くだけでは
     畳まれない」を含める (子が返信だけして畳まない事故を防ぐ)

  この経路を通ってよいのは、**親が事前に基準 3 点 (PR MERGED / 掃除済み / 申し送り無し)
  と `list_sessions` の活動停止を確認済み**で、かつ**ユーザーが直接指示した**ときだけ。
  拒否が面倒だからと最初から子に畳ませるのは上の ★★ の違反。
  子側の [[report-to-parent]] にも同じ例外 (親から `[決定] ユーザー指示で self-archive`
  が届いたら self-archive してよい) を書いた — **片方だけ直さないこと**。
- **監督役を引き継ぐときは、未 archive の子ごと引き渡す。** archive は親の責務なので、
  畳んでいない子を残したまま親が代わると責務が宙に浮く。引き継ぎ prompt に
  「子セッション台帳」(誰が居て・どの状態で・親が何をするか) を書くこと
  ([[next-session]] の「監督役の交代」)。**マージ済み・未 archive の子**が一番
  忘れられやすい。
- 全タスク完了で、結果 (PR 一覧・残件) をユーザーへまとめ、メモリの進捗ファイルを
  更新する。

## 子 → 親の通信プロトコル (report-to-parent と対)

| 種別 | いつ | 中身 |
|---|---|---|
| `[開始]` | 着手時 1 回 | タスク名 + 3 行以内の計画 |
| `[質問]` | 判断が親の文脈に依存するとき | 詰まった点 / 選択肢 / 子の推奨 |
| `[完了]` | PR 作成後 | PR #番号 / 変更要約 / **触ったファイル一覧** / 隣接タスクへの影響 |

[完了] の「触ったファイル一覧」が無いとマージ順と rebase 指示が出せない —
省略させない。
