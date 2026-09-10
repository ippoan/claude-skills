# parent-role/hooks — 親子プロトコルの機械的な栓 (hook 6 本)

**skill ではない** (`SKILL.md` は無い)。ここは hook の**置き場**だけで、
運用の正本は [`task-split` §4.5「機械的な栓」](../task-split/SKILL.md) と
[`report-to-parent`「機械的な栓」](../report-to-parent/SKILL.md) に**同一文**で置いてある
(片方だけ直さないこと)。symlink コマンドと `settings.json` の断片もそこにある。

| ファイル | event / matcher | 役 |
|---|---|---|
| `hooks/session-role-log.sh` | PreToolUse `mcp__ccd_session_mgmt__set_session_title` | title から親/子の marker を立てる。**塞がない** |
| `hooks/block-parent-repo-writes.sh` | PreToolUse `Edit` / `Write` / `NotebookEdit` | 親の repo 書き込みを deny (main clone も worktree も) |
| `hooks/block-parent-commits.sh` | PreToolUse `Bash` | 親の `git commit` / `push` / `apply` / `am` / `cherry-pick` を deny |
| `hooks/block-child-asks-user.sh` | PreToolUse `AskUserQuestion` | 子のユーザーへの直接質問を deny |
| `hooks/warn-archive-refused.sh` | **PostToolUseFailure** `mcp__ccd_session_mgmt__archive_session` (PostToolUse は成功時のみ。拒否はツール失敗 — Refs #163) | 親の archive が「was not archived」で拒否された瞬間 (**文言は問わない** — pinned でも live work でも同じ、Refs #167) に、task-split §6 の次の一手を出す。1 回目 = 再試行 1 回まで / 2 回目以降 = **`[決定] ユーザー指示で self-archive` の本文を完成形で出す** (拒否文言の原文・基準 3 点・`user-quotes.txt` の原文・report-to-parent 例外 (b) の条文を実行時抽出まで埋め、親が埋めるのは PR 番号だけ)。**塞がない** (ただし原文があれば `pending-<session_id>` に子を書く) |
| `hooks/require-archive-decision-sent.sh` | PreToolUse `*` (全ツール) | `pending-<session_id>` がある間、その子への `[決定] ユーザー指示で self-archive` の `send_message` と `list_sessions` / `archive_session` / `ToolSearch` 以外を deny。文面だけの hook は親が自分の判断で飛ばした (Refs ippoan/alc-app-s3#135) |
| `hooks/test-parent-role-hooks.sh` | — | 受け入れテスト。`HOME` を一時ディレクトリへ差し替えて回す |

```bash
bash parent-role/hooks/test-parent-role-hooks.sh
```

**★ hook は設置したセッションでは効かない** (settings watcher は session 開始時の設定しか見ない。
2026-09-09 実測)。設置後は新しいセッションで確かめる。

Refs ippoan/claude-skills#152 #160 #163
