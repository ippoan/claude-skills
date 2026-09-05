# parent-role/hooks — 親子プロトコルの機械的な栓 (PreToolUse hook 4 本)

**skill ではない** (`SKILL.md` は無い)。ここは hook の**置き場**だけで、
運用の正本は [`task-split` §4.5「機械的な栓」](../task-split/SKILL.md) と
[`report-to-parent`「機械的な栓」](../report-to-parent/SKILL.md) に**同一文**で置いてある
(片方だけ直さないこと)。symlink コマンドと `settings.json` の断片もそこにある。

| ファイル | matcher | 役 |
|---|---|---|
| `hooks/session-role-log.sh` | `mcp__ccd_session_mgmt__set_session_title` | title から親/子の marker を立てる。**塞がない** |
| `hooks/block-parent-repo-writes.sh` | `Edit` / `Write` / `NotebookEdit` | 親の repo 書き込みを deny (main clone も worktree も) |
| `hooks/block-parent-commits.sh` | `Bash` | 親の `git commit` / `push` / `apply` / `am` / `cherry-pick` を deny |
| `hooks/block-child-asks-user.sh` | `AskUserQuestion` | 子のユーザーへの直接質問を deny |
| `hooks/test-parent-role-hooks.sh` | — | 受け入れテスト。`HOME` を一時ディレクトリへ差し替えて回す |

```bash
bash parent-role/hooks/test-parent-role-hooks.sh
```

Refs ippoan/claude-skills#152
