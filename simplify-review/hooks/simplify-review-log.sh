#!/bin/bash
# PreToolUse / matcher: Agent
# 「このセッションで simplify-reviewer を Agent tool で起動した」証跡を残すだけ。
# ブロックはしない (常に素通し)。require-simplify-review.sh がこれを読む。
#
# 記録の形: 1 行 = "<epoch 秒>" を ~/.claude/state/simplify-reviewed/<session_id> に追記。
#
# Why: 「計画を reviewer に通す」は自己申告では担保できない。機械的に観測できる証跡
# (= Agent tool の subagent_type) だけを数える。general-purpose agent に定義を貼って
# 動かしても数えない (証跡が残らないため)。
set -euo pipefail

STATE_DIR="${HOME}/.claude/state/simplify-reviewed"
mkdir -p "$STATE_DIR" 2>/dev/null || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
typ=$(printf '%s' "$payload" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null || true)

[ "$typ" = "simplify-reviewer" ] || exit 0
[ -n "$sid" ] || exit 0

sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
printf '%s\n' "$(date +%s)" >> "${STATE_DIR}/${sid_safe}" 2>/dev/null || true

# 7 日より古い証跡は掃く (セッションは終わっているはず)
find "$STATE_DIR" -type f -mtime +7 -delete 2>/dev/null || true
exit 0
