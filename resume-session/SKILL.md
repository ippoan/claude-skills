---
name: resume-session
description: >
  前回セッションの引き継ぎを読み込み、提案ではなく即座に作業を再開する。引き継ぎ用 issue
  コメント (CCoW、$ARGUMENTS に URL/番号) → .claude/handoff.md → handoff ラベル issue の
  最新コメント、の順で復元する。新セッション開始時や compact 後に実行。next-session と対。
  トリガー:「作業再開」「resume-session」「引き継ぎ読み込み」「前回の続き」
  「handoff 復元」「セッション再開」等。
---

# 前回セッションから作業を自動再開

引き継ぎ情報を読み込み、**提案ではなく即座に作業を実行する**。

## 引き継ぎソースの優先順位

CCoW はコンテナが ephemeral で handoff.md が無いことがあるため、issue を最優先にする:

1. **`$ARGUMENTS` に issue / comment の URL または番号が渡された場合** — 最優先。
   GitHub MCP の issue 取得 tool (例: `mcp__github__issue_read` / `get_issue`。環境により
   server prefix が異なる) でそのコメントを読む。これで handoff.md が無くても復元できる
2. **`.claude/handoff.md`** — Read ツールで読む (従来経路、ローカル CLI で有効)
3. **`handoff` ラベルの open issue の最新コメント** — 1, 2 が無いとき GitHub MCP で探して読む

いずれも見つからなければ「引き継ぎが見つかりません。/next-session で保存してから
使用してください」と案内して終了する。

## 手順

1. **引き継ぎの読み込み**: 上記優先順位でソースを 1 つ選び読み込む
2. **git 状態の確認**: `git status` で現在の状態を確認。引き継ぎが別ブランチを指す場合は
   `git fetch origin <branch>` → checkout してそのブランチに合わせる
3. **引き継ぎ内容を簡潔に報告** (3行以内): 何を再開するかだけ伝える
4. **「次にやること」の先頭タスクから即座に実行開始する** — 提案や確認は不要、すぐ手を動かす
   - `$ARGUMENTS` が issue/comment ではなく具体タスク文字列の場合はそちらを優先して実行
5. タスクが完了したら次のタスクに進む
6. **全タスク完了後、plan ファイルがあれば更新する**:
   - 完了したタスクのチェックボックスを `[x]` に変更
   - Phase 見出しに ✅ を追記、進捗サマリーがあれば状態を更新
   - 更新内容をコミットに含める
