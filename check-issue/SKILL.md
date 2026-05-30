---
name: check-issue
description: ippoan / ohishi-exp 配下の全リポジトリにまたがる open issue を一括確認するスキル。`mcp__ci-dashboard__list_org_issues` を呼んで結果をリポジトリ別にグルーピングして提示する。トリガー：「issue 確認」「open issue」「未対応 issue」「issue 一覧」「issue まとめ」「全 org の issue」「ci-dashboard issue 確認」「check-issue」「自分宛 issue」等。
---

# check-issue

複数 org にまたがる open issue を 1 リクエストで取得し、リポジトリ別にまとめて提示する。

## 実行手順

1. `mcp__ci-dashboard__list_org_issues` ツールを ToolSearch で読み込む (まだ読み込まれていなければ):
   ```
   ToolSearch(query: "select:mcp__ci-dashboard__list_org_issues")
   ```

2. 既定パラメータで呼び出す (ユーザーが個別指定していない場合):
   ```
   mcp__ci-dashboard__list_org_issues(
     orgs: ["ippoan", "ohishi-exp"],
     state: "open",
     per_page: 100
   )
   ```

3. ユーザーの指示があれば追加フィルタを反映:
   - 「自分宛」「assigned to me」「@me」 → `assignee: "@me"`
   - ラベル指定 (例: 「bug ラベル」) → `labels: ["bug"]`
   - 「closed も含めて」「全部」 → `state: "all"`
   - 特定 org のみ (例: 「ippoan だけ」) → `orgs: ["ippoan"]`

## 出力フォーマット

リポジトリ別にグルーピングし、以下のテーブル形式で提示する:

```markdown
**Open issues: N 件 (M repos)**

### owner/repo (件数)
| # | title | author | updated |
|---|---|---|---|
| [#123](url) | タイトル | @user | YYYY-MM-DD |
```

- 件数 0 の repo はスキップ
- `updated_at` は日付部分のみ表示 (YYYY-MM-DD)
- `total_count > items.length` の場合 (= per_page で切れた場合) は末尾に `⚠️ N 件中 X 件のみ表示。残りは per_page を上げて再実行。` と注記
- `assignee` フィルタ指定時は `author` 列を `assignees` 列に置き換え

## ユーザー入力例と挙動

| ユーザー発話 | 呼び出し |
|---|---|
| 「issue 確認」「check-issue」 | デフォルト (両 org / open / per_page 100) |
| 「自分宛の issue」 | `assignee: "@me"` 追加 |
| 「ippoan の bug ラベルの issue」 | `orgs: ["ippoan"]`, `labels: ["bug"]` |
| 「closed も含めて全部」 | `state: "all"` |

## 個別 issue を深掘りしたい場合

ユーザーが特定 issue の詳細・コメントまで見たいと言ったら、`mcp__ci-dashboard__get_issue(repo, issue_number)` に切り替える。check-issue は一覧専用。

## issue → worktree 命名

未対応 issue を選んで実装に入る時、worktree / branch 名は **`<issue-number>-<type>-<short-description>`**
形式にする (規約詳細は [[branch-issue-linking]])。先に issue を立ててから
worktree を作るのが原則で、claude-hooks の `worktree-naming-guard.sh` が
登録されていれば命名違反 + issue 不在を PreToolUse で deny する。

```bash
# 例: check-issue で #145 を選んだ → そのまま worktree 作成
WT=145-feat-line-works-webhook
cd <repo> && git fetch origin main
git worktree add -b $WT .claude/worktrees/$WT origin/main
```

## 制約

- GitHub Search API のレート制限は 30 req/min。短時間に連打しない
- 1 リクエストの最大は 100 件 (`per_page` 上限)。`list_org_issues` 側でページングは未実装
- PR は `is:issue` で除外される
