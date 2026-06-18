---
name: next-session
description: >
  次セッションへの引き継ぎを作成する。CCoW (Claude Code on the Web) ではコンテナが
  ephemeral で次セッションは main の fresh clone から始まるため、引き継ぎ用 GitHub issue
  への投稿を唯一の正本とし、permalink をユーザーに提示する (handoff.md は作らない)。
  ローカル CLI では `.claude/handoff.md` に保存して commit する (issue は任意)。
  plan ファイルがあれば進捗も更新する。resume-session と対。
  トリガー:「引き継ぎ作成」「next-session」「セッション終わり」「申し送り」
  「handoff 保存」「次のセッションへ」等。
---

# 次セッションへの引き継ぎを作成

引き継ぎの置き場は**実行環境で変える**:

| 環境 | 正本 | handoff.md |
|---|---|---|
| **CCoW (リモート)** | 引き継ぎ用 **GitHub issue** | **作らない** |
| **ローカル CLI** | `.claude/handoff.md` (commit) | 作る (issue は任意) |

**CCoW で handoff.md を作らない理由**: コンテナは ephemeral で、次セッションは
**main の fresh clone** から始まる。handoff.md を feature ブランチに commit しても
main に無ければ次セッションのワークツリーには現れず、リンクでも渡せない。よって
CCoW では **GitHub issue が唯一機能する引き継ぎ手段**。handoff.md は徒労なので作らない。

## やること

1. **plan ファイルがあれば進捗を更新**: `plan/implementation-plan.md` 等が存在すれば、完了した
   タスクに `[x]`、Phase 見出しに ✅ (完了) / 🔧 (進行中) を追記する。無ければ skip
2. **git 状態を確認**: `git status` で未コミットの変更・push 済みブランチを把握する
3. **環境で分岐して引き継ぎを残す**:

### CCoW (リモート) の場合 — issue のみ

引き継ぎ用 issue に投稿する。handoff.md は**作らない**。

- **引き継ぎ先 issue を決める** (1 本に集約して乱立を防ぐ):
  - `$ARGUMENTS` に issue 番号 / URL があればそれを使う
  - 無ければ `handoff` ラベルの open issue を探して再利用する
  - それも無ければ新規作成する (title: `🔁 Session handoff`, label: `handoff`)
- **GitHub MCP の issue コメント tool** (例: `mcp__github__add_issue_comment`。環境により
  server prefix が異なる) で下記 3 セクションを投稿する。先頭に「日付・どのブランチからの
  引き継ぎか」を 1 行入れる
- push 済みブランチ名、関連 PR / commit のリンクを本文に含める
- **`Refs #N` を使う** (`Closes` / `Fixes` / `Resolves #N` は禁止 — auto-close 防止)

### ローカル CLI の場合 — handoff.md

`.claude/handoff.md` に下記 3 セクションを書き、ローカル経路で
`git add .claude/handoff.md` → commit → `git push -u origin <branch>`
(`create_or_update_file` / `push_files` は使わない)。issue 投稿は任意
(ローカルは `claude --teleport` / web follow-up で会話ごと継続できるため)。

### 引き継ぎ本文 (3 セクション、両環境共通)

```markdown
## 未コミットの変更
- (あれば git status の結果を簡潔に)

## 次にやること
- 最優先タスク
- その次のタスク
- ...

## 注意点
- 次のセッションで知っておくべき制約や決定事項のみ (最小限)
```

4. **ユーザーに報告**:
   - CCoW: 投稿した **issue コメントの permalink** を提示。次セッションでは
     `/resume-session <permalink>` にそのまま渡せる旨を添える
   - ローカル: handoff.md の path を提示

## ルール

- **秘密の値 (token / API key / password) を本文に書かない** — 名前だけ書き、値は
  `secret-inject` 経由。会話・log・issue に値が出た時点で compromised
- **要約は不要** — 過去にやったことは plan ファイル / git に記録済み
- **次にやることにフォーカス** — 次のセッションの Claude がすぐ着手できるように。簡潔に
- `$ARGUMENTS` が issue 指定でなく自由文なら、それを「次にやること」の先頭に含める
