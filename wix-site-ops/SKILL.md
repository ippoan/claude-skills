---
name: wix-site-ops
description: 大石運輸倉庫の Wix サイト (ohishiunyusouko.com) を触るときの運用知識。Wix MCP での読み書き、公開のたびの記録 (ohishi-exp/wix-ohishiunyusouko-backup の HISTORY.md と tools/record.sh、pre-push hook で本番と照合)、ブログのコメント設定、編集・レビュー・公開の流れ、踏み抜き済みの罠をまとめる。トリガー:「wix」「Wix サイト」「ohishiunyusouko」「ホームページ」「HP のバックアップ」「公開したので記録して」「HISTORY.md」「サイトを公開した」「ブログのコメント」「お問い合わせフォーム」「siteRevision」「Wix MCP」「メディアマネージャ」等。Wix の設定を変える前・バックアップを取る前に必ず読む。
---

# wix-site-ops — 大石運輸倉庫 Wix サイトの運用

**ここに進捗や日付つきの数字を書かないこと** (版番号・件数は `REVISION` と repo の README が正)。

## 座標

| もの | 値 |
|---|---|
| サイト | https://www.ohishiunyusouko.com/ (Wix 名 `ohishiunyusouko-site`) |
| siteId | `682bd6bb-e337-435c-81f3-850e2f57964d` |
| エディタ | 旧 Wix Editor (Studio ではない)。Premium・独自ドメイン・Velo 有効 (独自コードは読まれていない) |
| アプリ | Wix Blog / Wix Forms & Payments (旧フォーム) / Wix Invoices **V1** / Wix Payments / Promote SEO |
| バックアップ repo | `ohishi-exp/wix-ohishiunyusouko-backup` (**private**)。常設 clone は `~/claude260730/wix-ohishiunyusouko-backup` |

## Wix MCP

- connector は claude.ai の **Wix** (`mcp.wix.com`)。tool 名は `mcp__<uuid>__ListWixSites` のように uuid 付き。`ToolSearch` で `wix` を引いて load する。
- **MCP tool はセッション開始時のスナップショット**。途中で connector をつないでも、通知が来るまで呼べない。
- 流れ: `GetSiteContext(siteId)` → `SearchWixRESTDocumentation` で method を探す → `ReadFullDocsArticle` で例と endpoint を確かめる → `ExecuteWixAPI` (1 関数に読み書きをまとめる)。endpoint を記憶で書かない。
- **docs の curl 例と「Method API Endpoint」が食い違うことがある**。Blog Settings は例の `/v3/blog-settings` が 404、正は `https://www.wixapis.com/v3/blog-settings/v3/blog-settings`。迷ったら読み取りで両方試す。
- 書き込み (設定変更・公開) は本番に即効く。**ユーザーの明示の OK を取ってから**。

## バックアップ (3 段)

Wix にはサイトを書き出す機能が無い。git の控えから **Wix に戻すことはできない**。戻すのは Wix の中で。

| 何を | どこで | いつ |
|---|---|---|
| ページのデザイン・文章 | Wix の**サイト履歴** (保存・公開で自動。復元可。**ブログ記事・ギャラリー・連絡先は戻らない**) | 自動 |
| 公開の記録と本文 | repo の `HISTORY.md` + `snapshot/` (`tools/record.sh`。ブラウザ無し 20 秒) | 公開・変更のたび |
| 見た目 | repo の `pages/` `offline/` (`tools/backup.sh`。ブラウザ 15 分) | 大きく直す前だけ |

大きく直す前は Wix の「サイトを複製」も (Duplicate Site API はアカウント単位の権限が要る。MCP で通るかは未確認)。

### 公開・変更したら記録する (「公開したので記録して」と言われたら)

```bash
cd ~/claude260730/wix-ohishiunyusouko-backup && git fetch -q origin
git worktree add <scratchpad>/wix-rec -b rec-<日付> origin/main
cd <scratchpad>/wix-rec && tools/install-hook.sh          # worktree ごとに 1 回 (下の罠)
tools/record.sh "内容" 変更者 "#依頼" 確認者              # snapshot/ を取り直し HISTORY.md に 1 行足してコミット
git push -u origin HEAD                                   # pre-push hook が本番と照合
gh pr create --repo ohishi-exp/wix-ohishiunyusouko-backup --fill   # merge はユーザー (レビュアー)
```

- **pre-push hook** (`tools/pre-push` → `tools/check-history.sh`) が本番を取り直して「版番号 = HISTORY.md の最新行の版」「本文 = `snapshot/`」を照合し、違えば push を止める。照合は**手元の hook だけ** (GitHub Actions は使わない、とユーザー判断)。
- **`siteRevision` はエディタで公開したときだけ増える**。ブログの変更 (記事の再公開・ブログ設定) では増えない (2026-11-19 に 19 記事を再公開しても 1120 のまま)。ブログだけの変更は本文の照合で拾う。HISTORY.md には同じ版の行が複数あってよい。
- **共通 pre-push hook は repo の hook を `git rev-parse --git-dir`/hooks で探す**。worktree ではそれが `.git/worktrees/<名前>/hooks` を指すので、`tools/install-hook.sh` で本体と worktree の両方に symlink を置かないと照合が動かない。
- snapshot は Wix がサーバー側で返す HTML から script/style を捨てて文字だけにする。同じ版なら毎回同じ結果 (2 回取って完全一致を確認済み)。日本語 URL は `urllib.parse.quote` が要る。Wix はたまに 1 ページだけ応答が止まるので再試行を入れてある。
- snapshot で取れないもの: 表アプリ (iframe) の中身と見た目。表を直したときは `tools/backup.sh` も回す。

### 見た目ごと取り直す (大きく直す前)

```bash
git worktree add <scratchpad>/wix-backup origin/main --detach
<scratchpad>/wix-backup/tools/backup.sh          # 版番号が同じなら何もしない。--force / --no-push
git worktree remove --force <scratchpad>/wix-backup
```

- 27 ページをブラウザで開いて撮る (15 分ほど)。走らせるのは背景 (`run_in_background`) で。同じ版でも 80 ファイルほど差分が出る (開くたびに変わる値が HTML に入るため)。
- 取るもの: `pages/*.png` (フルページ画像)、`pages/*.html` (JS 実行後の DOM)、`pages/*.frames/` (iframe の中身)、`pages/*.txt` (本文 + 枠の文字)、`offline/` (script を外し画像を手元参照にした版)。
- **メディア原本 `media/` は backup.sh では更新しない** (Wix の認証が要る)。画像を入れ替えたときは MCP で `POST https://www.wixapis.com/site-media/v1/folders/media-root/generate-download-url` → 返った zip を curl で落として展開。
- 自動実行 (GitHub Actions / cron) はしない方針 (private repo の Actions 分を使いたくない、とユーザー判断)。

## 罠 (踏み抜き済み)

- **Wix は通信が止まない**。playwright の `networkidle` 待ちは 60 秒ずつ空振りする。`load` → 最後までスクロール → 数秒待ち。
- **日本語フォントが無いとスクリーンショットが □ だらけ**。このマシンは `~/.local/share/fonts/noto-cjk/` に Noto CJK を入れてある (sudo 不要)。
- **会社概要の表・営業所一覧は Wix 表アプリの iframe** (`wix-visual-data.appspot.com`)。`page.content()` や `innerText` には入らない。`page.mainFrame().childFrames()` で枠ごとに取る。
- **ギャラリー部品は JS で描く**ので offline 版では空白。見た目はスクリーンショットにしか残らない (スクリーンショットは削らない)。
- **メディア zip の中のパスは `/車両/...` と `/` 始まり**。そのまま makedirs すると `/車両` を作ろうとして Permission denied。先頭の `/` を外す。
- **gitleaks (pre-push hook) が Wix 公開ページで必ず鳴る**: `biToken` (訪問者全員に配られる解析 ID) と `stylableMetadataURLs` の 40 桁 (Wix 部品のビルド hash、sourcegraph-access-token と誤認)。hook は repo の `.gitleaks.toml` を読まず `.gitleaksignore` の fingerprint だけを見る。fingerprint は commit ごとに変わるので、**取り直しのたびに次の commit で足す** (backup.sh が自動でやる。それ以外の検出が出たら止まる)。
- **`~/claude260730/` 配下の main clone は Write/Edit が hook で拒否**される (`git init` しただけのフォルダも対象になる)。作業は worktree で。
- **`git add -A` と commit と push を 1 回の Bash でつなぐと分類器に止められる**。add はパスを明示、commit・push は別の呼び出しで。
- 新 Wix Forms の API (`wix.form_app.form`) は「この site に無い」と返る。お問い合わせは旧フォームなので、送信履歴は管理画面からの CSV 書き出ししか無い。

## ブログのコメント

- 全体設定は Blog Settings API (`GET`/`PATCH .../v3/blog-settings/v3/blog-settings`)。`comments` の 4 項目 (`enabled` / `anonymousEnabled` / `ratingsEnabled` / `ratingsMandatory`) は**必ず 4 つ一緒に**送り、`revision` も渡す。
- ヘルプには「`enabled: false` で全記事のコメント欄と既存コメントが非表示」とあるが、**このサイトでは全体設定を切っても記事ページにコメント欄が出たままだった** (10 分待っても変わらず)。効いたのは**記事ごとの設定**。全体設定は `enabled: false` のまま残してある。
- 記事ごと: `PATCH https://www.wixapis.com/blog/v3/draft-posts/{postId}` に `{"draftPost":{"commentingEnabled":false},"action":"UPDATE_PUBLISH"}`。post と draft post は同じ id。**`UPDATE_PUBLISH` は下書きを丸ごと公開する**ので、先に draft を GET して `hasUnpublishedChanges: true` の記事は飛ばす (未公開の編集を本番に出してしまう)。止めると既存コメントも非表示になる (削除はされない)。
- 確認は API の値ではなく**本番ページで**: playwright で記事を開いて最後までスクロールし、「コメントを追加」と既存コメントの文字が消えたかを見る。
- 管理画面なら: 全体はブログ → その他のアクション → ブログ設定 → 「コメントと評価」。記事ごとはブログ → 投稿 → 編集 → 設定 →「この記事へのコメントを許可」→ 公開。

## 編集・レビュー・公開の流れ (発注者・レビュアーがいる場合)

1. 依頼: 変更内容を issue 等で残す。
2. 編集: 共同作業者として招待 (ダッシュボード → 役割と権限)。エディタで「保存」しただけでは本番に出ない。
3. 確認: **テストサイト** (Release Manager) で別版を作り、公開割合 0% のままレビュアーに見せる。
4. 公開: 承認後に「この版を公開」→ `siteRevision` が増える → `tools/record.sh` で記録して PR (hook が本番と照合)。
5. 戻す: Wix の**サイト履歴**から以前の版に復元。git のバックアップは Wix で戻せないときの最後の控え。

未確認: テストサイトを割合 0% のまま URL で見せられるか / 「編集できるが公開できない」カスタム役割を作れるか。
