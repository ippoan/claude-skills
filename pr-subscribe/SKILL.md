---
name: pr-subscribe
description: いま動いている Claude Code on Web (CCoW) session を、指定した GitHub PR の活動 (CI failure / comment / review) に購読させるスキル。`mcp__github__subscribe_pr_activity` を呼び、以後その PR のイベントが `<github-webhook-activity>` として session に届く (= 別 identity の comment / CI 失敗で session が re-wake される)。PR は URL / `owner/repo#N` / 番号で渡す。**省略時は必ずユーザーに PR を確認してから**購読する。トリガー:「PR 購読」「PR を購読させて」「この PR を見張って」「watch PR」「subscribe PR」「CCoW に購読させる」「PR の CI/コメント監視」「re-wake 用に購読」「pr-subscribe」等。/pr-subscribe <PR URL> で呼び出し可能。
---

# pr-subscribe

実行中の CCoW session を 1 本の GitHub PR の活動に購読させる。購読後、その PR の
**CI failure / comment / review** が `<github-webhook-activity>` として session に
注入される。これは cc-relay の re-wake 経路 (#69) の受け口でもある — session 自身
とは別の GitHub identity (例 `github-actions[bot]` / `cc-relay-agent[bot]`) が打った
comment は harness の self-loop filter を通過し、寝ている session を起こす。

## 入力 (PR は「変数」)

呼び出し引数で PR を受け取る。受理する形式:

- フル URL: `https://github.com/<owner>/<repo>/pull/<N>`
- 短縮: `<owner>/<repo>#<N>` または `<owner>/<repo> <N>`
- 番号のみ: `<N>` — ただし対象 repo が文脈から一意に分かる時だけ

### PR が渡されなかった / 解釈できない場合

**勝手に推測して購読しない。** `AskUserQuestion` でユーザーに確認する:

- 質問: 「どの PR を購読しますか？ PR の URL (または `owner/repo#番号`) を教えてください。」
- 直近に作成/言及した PR があるなら、それを候補 (Recommended) として提示してよい。
- 回答が URL/番号として解釈できるまで購読しない。

## 実行手順

1. 引数 (または確認で得た文字列) から `owner` / `repo` / `pullNumber` を抽出する。
   - URL 例 `https://github.com/ippoan/cc-relay/pull/71` → owner=`ippoan`, repo=`cc-relay`, pullNumber=`71`。
   - `pullNumber` は整数。抽出できなければ上記「確認」に戻る。

2. ツールを読み込む (未ロードなら):
   ```
   ToolSearch(query: "select:mcp__github__subscribe_pr_activity")
   ```

3. 購読する:
   ```
   mcp__github__subscribe_pr_activity(owner: <owner>, repo: <repo>, pullNumber: <pullNumber>)
   ```
   冪等なので再呼び出しは安全。

4. 購読できたことを 1 行で報告し、**ターンを終える**。
   - 以後イベントは `<github-webhook-activity>` として自動的に届く。
   - **`sleep` / polling で待たない** (harness が webhook で起こす)。
   - 解除したくなったら `mcp__github__unsubscribe_pr_activity` を案内する。

## 注意

- 購読対象は repo スコープ許可リスト内の PR であること (アクセス不可なら購読は失敗する)。
- 購読は**この session 限定**。別 session を購読させたい場合はその session で本スキルを実行する。
- 「他 agent の作業を知りたい」用途では、相手が **bot identity の comment** を打つ前提
  (raw push や同一 identity の comment は self-filter で届かない)。詳細は
  ippoan/cc-relay#69。
