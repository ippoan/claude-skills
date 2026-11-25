---
name: wix-site-ops
description: Wix サイト (旧 Wix Editor) を運用するときの知識。Wix MCP での読み書き、公開のたびの記録 (バックアップ repo の HISTORY.md と tools/record.sh、pre-push hook で本番と照合)、エディタでのスマホ表示の直し方、スマホだけ CSS で見た目を変える方法 (カスタムコード)、ブログのコメント設定、編集・レビュー・公開の流れ、踏み抜き済みの罠をまとめる。サイト固有の値 (siteId・部品 ID・repo の場所) はここに書かず、各サイトのバックアップ repo の CLAUDE.md に置く。トリガー:「wix」「Wix サイト」「ホームページ」「HP のバックアップ」「公開したので記録して」「HISTORY.md」「サイトを公開した」「スマホ表示」「カスタムコード」「ブログのコメント」「お問い合わせフォーム」「siteRevision」「Wix MCP」「メディアマネージャ」等。Wix の設定を変える前・バックアップを取る前に必ず読む。
---

# wix-site-ops — Wix サイト (旧エディタ) の運用

**この skill は公開 repo にある。サイト固有の値 (siteId、部品の `comp-…` ID、private repo の場所、版番号) は書かない**。
それらは対象サイトのバックアップ repo の `CLAUDE.md` に書き、作業の最初にそちらを読む
(このマシンでは `~/claude260730/` 配下の `wix-*-backup`)。進捗や日付つきの数字もここに書かない。

## Wix MCP

- connector は claude.ai の **Wix** (`mcp.wix.com`)。tool 名は `mcp__<uuid>__ListWixSites` のように uuid 付き。`ToolSearch` で `wix` を引いて load する。
- **MCP tool はセッション開始時のスナップショット**。途中で connector をつないでも、通知が来るまで呼べない。
- 流れ: `WixREADME` (初回) → `SearchWixRESTDocumentation` で method を探す → `ReadFullDocsArticle` で例と endpoint を確かめる → `ExecuteWixAPI` (1 関数に読み書きをまとめる)。endpoint を記憶で書かない。`WixREADME` の結果は大きいのでファイルに落ちる (読み飛ばしてよい)。
- **docs の curl 例と「Method API Endpoint」が食い違うことがある**。Blog Settings は例の `/v3/blog-settings` が 404、正は `https://www.wixapis.com/v3/blog-settings/v3/blog-settings`。迷ったら読み取りで両方試す。
- 書き込み (設定変更・公開) は本番に即効く。**ユーザーの明示の OK を取ってから**。

## バックアップ (3 段)

Wix にはサイトを書き出す機能が無い。git の控えから **Wix に戻すことはできない**。戻すのは Wix の中で。

| 何を | どこで | いつ |
|---|---|---|
| ページのデザイン・文章 | Wix の**サイト履歴** (保存・公開で自動。復元可。**ブログ記事・ギャラリー・連絡先は戻らない**) | 自動 |
| 公開の記録と本文 | バックアップ repo の `HISTORY.md` + `snapshot/` (`tools/record.sh`。ブラウザ無し 20 秒) | 公開・変更のたび |
| 見た目 | バックアップ repo の `pages/` `offline/` (`tools/backup.sh`。ブラウザ 15 分) | 大きく直す前だけ |
| カスタムコード | バックアップ repo の `custom-code/` (控え。Wix 側を直したら同じにする) | 変えたとき |

大きく直す前は Wix の「サイトを複製」も (Duplicate Site API はアカウント単位の権限が要る。MCP で通るかは未確認)。

### 公開・変更したら記録する (「公開したので記録して」と言われたら)

```bash
cd <バックアップ repo の clone> && git fetch -q origin
git worktree add <scratchpad>/wix-rec -b rec-<日付> origin/main
cd <scratchpad>/wix-rec && tools/install-hook.sh          # worktree ごとに 1 回 (下の罠)
tools/record.sh "内容" 変更者 "#依頼" 確認者              # snapshot/ を取り直し HISTORY.md に 1 行足してコミット
git push -u origin HEAD                                   # pre-push hook が本番と照合
gh pr create --fill                                       # merge はユーザー (レビュアー)
```

- **pre-push hook** (`tools/pre-push` → `tools/check-history.sh`) が本番を取り直して「版番号 = HISTORY.md の最新行の版」「本文 = `snapshot/`」を照合し、違えば push を止める。照合は**手元の hook だけ** (GitHub Actions は使わない、とユーザー判断)。
- **`siteRevision` はエディタで公開したときに増える**。ブログの変更 (記事の再公開・ブログ設定) では増えない。カスタムコードを変えたときに増えたことはある。HISTORY.md は record.sh が取った値をそのまま書く。同じ版の行が複数あってよい。
- **共通 pre-push hook は repo の hook を `git rev-parse --git-dir`/hooks で探す**。worktree ではそれが `.git/worktrees/<名前>/hooks` を指すので、`tools/install-hook.sh` で本体と worktree の両方に hook を置かないと照合が動かない。置くのは「push した作業場所の `tools/pre-push` を呼ぶ」中継スクリプト。**symlink にすると、worktree を消した瞬間にリンク先が無くなり照合が黙って止まる** (一度踏んだ)。
- snapshot は Wix がサーバー側で返す HTML から script/style を捨てて文字だけにする。同じ版なら毎回同じ結果。日本語 URL は `urllib.parse.quote` が要る。Wix はたまに 1 ページだけ応答が止まるので再試行を入れてある。
- snapshot で取れないもの: 表アプリ (iframe) の中身と見た目、CSS で変えた見た目。それらを直したときは本番を撮って確かめる。

### 見た目ごと取り直す (大きく直す前)

```bash
git worktree add <scratchpad>/wix-backup origin/main --detach
<scratchpad>/wix-backup/tools/backup.sh          # 版番号が同じなら何もしない。--force / --no-push
git worktree remove --force <scratchpad>/wix-backup
```

- 全ページをブラウザで開いて撮る (十数分)。背景 (`run_in_background`) で走らせる。同じ版でも多数のファイルに差分が出る (開くたびに変わる値が HTML に入るため)。
- **メディア原本は backup.sh では更新しない** (Wix の認証が要る)。画像を入れ替えたときは MCP で `POST https://www.wixapis.com/site-media/v1/folders/media-root/generate-download-url` → 返った zip を curl で落として展開。
- 自動実行 (GitHub Actions / cron) はしない方針。

## 罠 (踏み抜き済み)

- **本番ページをブラウザで開くとサイトの統計に数えられる** (Wix の統計と Google Analytics の両方。cookie 同意バナーが無いと止まらない。iPhone の UA で撮るとスマホの訪問に見える)。playwright では `newPage()` の前に `ctx.route('**/*', r => /frog\.wix\.com|panorama\.wixapps\.net|google-analytics\.com|googletagmanager\.com|analytics\.google\.com/.test(r.request().url()) ? r.abort() : r.continue())` で解析の送信を落とす (表示は変わらない)。backup の撮影スクリプトに入っているか確かめる (入っていない repo がある)。回線の IP が固定でないと IP での除外は使えない。curl は JS を動かさないので対象外。Wix にログインした Chrome での閲覧は Wix の統計には数えられない (GA には数えられうる)。
- playwright-core の既定の headless (old) は今の Chrome では起動しない。`chromium.launch({ executablePath: '/usr/bin/google-chrome', headless: false, args: ['--headless=new'] })`。
- **Wix は通信が止まない**。`networkidle` 待ちは空振りする。`load` → 少しずつ最後までスクロール (画面に入ってから読み込む部品がある) → 数秒待ち。
- **日本語フォントが無いとスクリーンショットが □ だらけ**。`~/.local/share/fonts/` に Noto CJK を入れる (sudo 不要)。
- **Wix 表アプリは iframe** (`wix-visual-data.appspot.com`)。`page.content()` や `innerText` には入らない。`page.mainFrame().childFrames()` で枠ごとに取る。
- **ギャラリー部品は JS で描く**ので offline 版では空白。見た目はスクリーンショットにしか残らない。
- **メディア zip の中のパスは `/フォルダ/...` と `/` 始まり**。そのまま makedirs すると Permission denied。先頭の `/` を外す。
- **gitleaks (pre-push hook) が Wix 公開ページで必ず鳴る**: `biToken` (訪問者全員に配られる解析 ID) と `stylableMetadataURLs` の 40 桁 (部品のビルド hash を token と誤認)。hook は `.gitleaksignore` の fingerprint だけを見る。fingerprint は commit ごとに変わるので取り直しのたびに次の commit で足す。
- バックアップ repo の本体 clone は Write/Edit が hook で拒否されることがある。作業は worktree で。
- **`git add -A` と commit と push を 1 回の Bash でつなぐと分類器に止められる**。add はパスを明示、commit・push は別の呼び出しで。
- 新 Wix Forms の API (`wix.form_app.form`) は旧フォームのサイトでは「無い」と返る。旧フォームの送信履歴は管理画面からの CSV 書き出ししか無い。
- `~/.claude/skills/` の skill は claude-skills の clone へのリンクのことがある。そこにコピーすると公開 repo の作業コピーを書き換える。直すときは claude-skills の PR で。

## エディタでスマホ表示を直す (Claude in Chrome)

- 開き方: `https://manage.wix.com/editor/<siteId>` → 上部「ページ」で切替 → スマホアイコン。編集は「保存」まで。**公開はユーザー**。保存後のダイアログは「閉じる」(「今すぐ公開」を押さない)。
- 旧エディタでは**色・文字・デザインは PC とスマホで共通**。スマホだけで変えられるのは位置・大きさ・非表示と、スマホ専用に足した部品 (左上の「＋」= モバイルサイトに追加: テキスト・画像・ボタン・装飾・ボックス・ソーシャル・埋め込みコード)。PC を変えずに見た目を変えるなら次節の CSS。
- 座標: preview iframe (`document.getElementById('preview').contentDocument`) の `getBoundingClientRect` は 320 幅のページ座標で、右パネルの X / Y にそのまま使える。本番の値も同じ座標系。
- 位置・大きさは右パネルの 幅 / 高 / X / Y に数値入力 (三回クリック → 入力 → Enter)。Y はページ絶対値。**パネルの縦位置は選んだ部品の種類で変わる**ので、入力前に zoom で欄を確かめる。カラム・セクションの高さもレイヤーから選べば数値で入る (入れると中の部品も一緒に動く)。
- **キャンバスのクリックでエディタが勝手にスクロールし、別の部品を選んでいることがある** (別ブロックの部品を数値で動かす事故を一度起こした)。数値を入れる前に右パネルの 幅・高・X・Y を zoom で見て、選んだものか確かめる。確実なのはレイヤーパネル (左下) から選ぶこと。非表示にした部品はレイヤーの一覧から消えるので、行の位置がずれる。
- 入れ子の部品はクリック 1 回目で親 (セクション・ボックス) が選ばれる。もう 1 回で子。ヘッダーと重なる部品はレイヤーから選ぶ。
- **↶ (取り消し) は 1 操作 = 1 段とは限らない**。数えて押すと行き過ぎる。行き過ぎたら ↷ で 1 段ずつ戻し、preview の DOM で位置を測って確かめる。保存した状態に丸ごと戻すならエディタを開き直す (未保存の変更は捨てられる)。
- 開き直したあと、セクションの下に前の高さぶんの空白が出ることがある。そのセクションの高さを一度変えて戻すと詰まる。直したら保存し直す。
- **スマホのセクション順はレイヤーパネルのドラッグでは変わらない** (レイヤー上だけ変わる)。画面上でセクションにマウスを乗せると横に出る ↑↓ で動かす。
- スマホで非表示のセクションを「表示」に戻すと、別セクションへ移されていた子部品が元に戻り、並びも PC 順に戻ることがある。抜けた側に空白が残るので高さを詰める。
- 部品をどけても、下の部品は寄ってこない。空白を数値で詰める。セクションの高さが数値で入らないときは下端中央のつまみ (`[data-hook=section-edge-resize-button]`) をドラッグ (画面 1px ≒ ページ 1.25px)。
- 旧リスト部品はエディタとプレビューで崩れて描かれることがある (文字が縦に並ぶ)。重ねる部品の位置は本番の座標で決め、公開後に本番で確かめる。
- **コラージュ (ギャラリー) のスマホの高さは PC の縦横比から決まり、数値欄は灰色**。スマホでレイアウト → 画像の配置を「縦」にすると幅いっぱいになる (PC は変わらない)。
- PC で部品を削除すると部品ごと消える (スマホからも)。スマホだけ消すなら非表示ボタン。

## スマホだけ見た目を変える (カスタムコードの CSS)

- 入れ先はダッシュボードの「設定 → カスタムコード」(`/dashboard/<siteId>/code-embed`)。ページ指定・ヘッダー・種類「必須」(CSS だけなら同意不要)。**適用した時点で本番に出る** (エディタの公開を待たない)。外すときは一覧のスイッチを切る。控えはバックアップ repo の `custom-code/`。
- スマホ判定は本番・エディタとも `body.device-mobile-optimized`。旧エディタには**自分でクラスを付ける機能が無い** (Studio の `customClassList` も使えない)。範囲はセクションの ID で絞り、中は Wix が付ける `wixui-column-strip__column` / `wixui-rich-text` / `wixui-image` / `wixui-vector-image` / `wixui-horizontal-line` と `data-hook` (`bgLayers` / `item-container` / `post-list-item` / `post-title` など) を使う。ハッシュのクラス (`FDI5TK` 等) は Wix の更新で変わるので使わない。
- 配置は「mesh」(CSS grid + `[data-mesh-id=...] > [id=...]` の margin)。行の高さやセクション下の余白は `grid-template-rows` と子の `margin` が持っている。子は本番だと `interact-element` で包まれることがあるので `> interact-element > ` の形も並べて書く。`wixui-rich-text` は部品そのものに付く場合と子に付く場合があるので両方の形を書く。
- 試し当ては、エディタの preview iframe の `head` に `<style>` を差して見る (保存されない)。ただし**本番は公開済みの版**で、エディタで非表示にした部品が本番には残っていたり、同じ見た目の部品でも種類が違ったり (アイコンに見えて画像パーツ) する。入れたら必ず本番のスマホ表示を撮って確かめる。本番の HTML は curl (iPhone UA) で取れる (`<style>` が入ったかの確認にも使える。統計に数えられない)。
- ブログの記事リストは pro-gallery で、各行が `position:absolute` と固定の高さで並ぶ。行を詰めるには `item-container` を `position:relative; height:auto` にして流し込み、`.gallery-item-common-info-outer` の float と幅を外す。記事にカテゴリが無いと、カテゴリ別のラベルは出し分けられない (`::before` で固定の文字なら出せる)。
- カスタムコードの textarea に長い文字を `type` で打つと Chrome がタイムアウトする。JS で `HTMLTextAreaElement.prototype` の value setter を呼んで `input` を投げ、最後に 1 文字打って消す (React に拾わせる)。保存前に中身を控えと行ごとに比べる。
- 適用したページ以外の HTML にも、Wix の設定 JSON の中にコードの文字列が入る (適用はされない)。

## ブログのコメント

- 全体設定は Blog Settings API (`GET`/`PATCH .../v3/blog-settings/v3/blog-settings`)。`comments` の 4 項目 (`enabled` / `anonymousEnabled` / `ratingsEnabled` / `ratingsMandatory`) は**必ず 4 つ一緒に**送り、`revision` も渡す。
- ヘルプには「`enabled: false` で全記事のコメント欄が非表示」とあるが、**全体設定を切っても記事ページにコメント欄が出たままだったサイトがある**。効いたのは**記事ごとの設定**。
- 記事ごと: `PATCH https://www.wixapis.com/blog/v3/draft-posts/{postId}` に `{"draftPost":{"commentingEnabled":false},"action":"UPDATE_PUBLISH"}`。post と draft post は同じ id。**`UPDATE_PUBLISH` は下書きを丸ごと公開する**ので、先に draft を GET して `hasUnpublishedChanges: true` の記事は飛ばす。止めると既存コメントも非表示になる (削除はされない)。
- 確認は API の値ではなく**本番ページで** (記事を開いて最後までスクロールし、「コメントを追加」と既存コメントが消えたか)。
- 管理画面なら: 全体はブログ → その他のアクション → ブログ設定 → 「コメントと評価」。記事ごとはブログ → 投稿 → 編集 → 設定 →「この記事へのコメントを許可」→ 公開。

## 編集・レビュー・公開の流れ (発注者・レビュアーがいる場合)

1. 依頼: 変更内容を issue 等で残す。
2. 編集: 共同作業者として招待 (ダッシュボード → 役割と権限)。エディタで「保存」しただけでは本番に出ない。
3. 確認: **テストサイト** (Release Manager) で別版を作り、公開割合 0% のままレビュアーに見せる。
4. 公開: 承認後に「この版を公開」→ `siteRevision` が増える → `tools/record.sh` で記録して PR (hook が本番と照合)。
5. 戻す: Wix の**サイト履歴**から以前の版に復元。カスタムコードはスイッチで外す。git のバックアップは最後の控え。

未確認: テストサイトを割合 0% のまま URL で見せられるか / 「編集できるが公開できない」カスタム役割を作れるか。
