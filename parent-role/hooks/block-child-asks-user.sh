#!/bin/bash
# PreToolUse / matcher: AskUserQuestion
# 子 (タスク) セッションがユーザーへ直接質問するのを拒否し、親経由 (send_message の
# [質問]) へ寄せる。
#
# Why (オーナー要望 2026-09-05):「子から質問がくるのもうざいから、親経由にしたい」。
# report-to-parent / task-split には既に書いてあるが、機械的な栓が無かった。
#
# ★ 判定は **child-role marker の陽性判定**。cwd (worktree に居る = 子) では判定しない
#   — ユーザーが自分で worktree に開いたセッションまで AskUserQuestion を失うため
#   (オーナー判断 2026-09-05)。命名規約でタイトルに c が入るのが子なので陽性で足りる。
#
# - child-role marker が無ければ素通し (fail-open)。名乗らない子は塞がらない
# - escape: ~/.claude/state/child-may-ask/<session_id> が在れば素通し
#   (親が居ない単独セッション用)
#
# 限界: permission プロンプト (ツール承認・archive_session の確認) は hook で消せない。
#       「子からの割り込みを 0 にする」ことはできない。
set -u

CHILD_DIR="${HOME}/.claude/state/child-role"
MAY_ASK_DIR="${HOME}/.claude/state/child-may-ask"

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')

[ -e "${CHILD_DIR}/${sid_safe}" ] || exit 0
[ -e "${MAY_ASK_DIR}/${sid_safe}" ] && exit 0

reason="子セッションはユーザーに直接質問しません。list_sessions でタイトルが #p<親issue> + **スペース**で始まるセッションを引き、send_message で
  [質問] 詰まった点 / 選択肢 / 自分の推奨
を送ってください ([旧] 付きは旧親、#p<親issue>-c… は兄弟の子。どちらにも送らない)。
**返信を待って止まらないこと** — 自分の推奨で進められるところまで進め、親の回答で覆ったら直す。
親が居ない単独セッションなら touch ${MAY_ASK_DIR}/${sid_safe} を作れば解除されます。"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
