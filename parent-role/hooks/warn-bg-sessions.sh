#!/bin/bash
# PostToolUse / matcher: mcp__ccd_session_mgmt__list_sessions
# PostToolUseFailure / matcher: mcp__ccd_session_mgmt__archive_session
#
# `claude --bg` (spawn-task-button mod) で起動した子は、デスクトップアプリの管理外で
# `list_sessions` / `archive_session` に出ない (ListAgents には bg で出る)。
# 親が一覧を見て「子はもう居ない」と読む、あるいはオーナーに「閉じてください」と頼む
# 事故を避けるため、`claude agents --json` から kind == "background" を抜いて、
# 畳み方 (`claude stop <id>` → `claude rm <id>`、task-split §6) を additionalContext で出す。
# Refs ippoan/claude-skills#203 / ippoan/alc-dtako-worker#26
#
# **塞がない** (情報を足すだけ)。fail-open: jq / claude / timeout が無い・JSON が不正・
# 5 秒で返らない・bg が 0 件 → 何も出さず exit 0。
# warn-archive-refused.sh (PostToolUseFailure の archive_session) とは別の本数で、
# あちらは stderr + exit 2 の文面、こちらは additionalContext の JSON。文面は互いに触れない。
set -u

command -v jq >/dev/null 2>&1 || exit 0
command -v claude >/dev/null 2>&1 || exit 0
command -v timeout >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
ev=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
case "$ev" in
  PostToolUseFailure) ;;
  *) ev=PostToolUse ;;
esac

out=$(timeout 5 claude agents --json 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0

# bg だけを「名前 / id / status」の行にする。配列でなければ 0 件扱い。
lines=$(printf '%s' "$out" | jq -r '
  (if type == "array" then . else [] end)
  | map(select(type == "object" and .kind == "background"))
  | .[]
  | "- \(.name // "(名前なし)") / \(.id // .sessionId // "?") / \(.status // "?")"' 2>/dev/null) || exit 0
[ -n "$lines" ] || exit 0

n=$(printf '%s\n' "$lines" | jq -Rn '[inputs] | length' 2>/dev/null) || exit 0

ctx="list_sessions に出ない bg セッションが ${n} 件:
${lines}
畳むのは \`claude stop <id>\` → \`claude rm <id>\` (task-split §6「bg で起動した子」)。オーナーに「閉じてください」と頼まない。先に PR が MERGED で未コミット変更が無いことを確かめる。"

jq -nc --arg ev "$ev" --arg c "$ctx" \
  '{hookSpecificOutput:{hookEventName:$ev,additionalContext:$c}}'
exit 0
