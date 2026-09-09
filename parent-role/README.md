# parent-role/hooks — 親子プロトコルの機械的な栓 (hook 5 本)

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
| `hooks/warn-archive-refused.sh` | **PostToolUse** `mcp__ccd_session_mgmt__archive_session` | 親の archive が「pinned or in use」で拒否された瞬間に、task-split §6 の次の一手 (1 回目 = 再試行 1 回まで / 2 回目以降 = 3 択を 1 行で知らせる → **ユーザーの原文を貼った** `[決定]` を子へ送る → 待たずに続行) を出す。**塞がない** |
| `hooks/test-parent-role-hooks.sh` | — | 受け入れテスト。`HOME` を一時ディレクトリへ差し替えて回す |

```bash
bash parent-role/hooks/test-parent-role-hooks.sh
```

**★ hook は設置したセッションでは効かない** (settings watcher は session 開始時の設定しか見ない。
2026-09-09 実測)。設置後は新しいセッションで確かめる。

Refs ippoan/claude-skills#152 #160
