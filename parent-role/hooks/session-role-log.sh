#!/bin/bash
# PreToolUse / matcher: mcp__ccd_session_mgmt__set_session_title
# 「このセッションは親か子か」の証跡を立てるだけ。ブロックはしない (常に素通し)。
# block-parent-repo-writes.sh / block-parent-commits.sh / block-child-asks-user.sh が
# これを読む。
#
# 記録の形: 空ファイル ~/.claude/state/parent-role/<session_id>
#                      ~/.claude/state/child-role/<session_id>
#
# Why: ~/.claude/sessions/*.json に **title は無い** (2026-09-05 実測。keys は親子で
# 完全同一で、「spawn_task で起動された」ことを示す欄も無い)。title を hook が知れるのは
# set_session_title の瞬間だけなので、役割の判定材料はこの形しか無い。
#
# 命名規約の正本は task-split skill §1:
#   親        `#p<issue> <題>`            (★ #p<数字> の直後がスペース)
#   子 (枝)   `[S]/[O] #c<親issue>-<番号> <題>`
#   子 (自issue) `[S]/[O] #p<親issue>-c<子issue> <題>`
#   旧親      `[旧] #p<issue> <題>`
#
# ★ tool_input.session_id == "self" のときだけ働く。他セッションの改名 (旧親を [旧] へ
#   付け替える等) で自分に marker が立つのを防ぐ。
set -u

STATE_ROOT="${HOME}/.claude/state"
PARENT_DIR="${STATE_ROOT}/parent-role"
CHILD_DIR="${STATE_ROOT}/child-role"

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

target=$(printf '%s' "$payload" | jq -r '.tool_input.session_id // empty' 2>/dev/null || true)
[ "$target" = "self" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
title=$(printf '%s' "$payload" | jq -r '.tool_input.title // empty' 2>/dev/null || true)
[ -n "$title" ] || exit 0

mkdir -p "$PARENT_DIR" "$CHILD_DIR" 2>/dev/null || exit 0
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')

if printf '%s' "$title" | grep -qE '^\[旧\] #p'; then
  # 交代した旧親。どちらの役でもない
  rm -f "${PARENT_DIR}/${sid_safe}" "${CHILD_DIR}/${sid_safe}" 2>/dev/null || true
elif printf '%s' "$title" | grep -qE '#c[0-9]+-|#p[0-9]+-c'; then
  : > "${CHILD_DIR}/${sid_safe}" 2>/dev/null || true
  rm -f "${PARENT_DIR}/${sid_safe}" 2>/dev/null || true
elif printf '%s' "$title" | grep -qE '^#p[0-9]+ '; then
  : > "${PARENT_DIR}/${sid_safe}" 2>/dev/null || true
  rm -f "${CHILD_DIR}/${sid_safe}" 2>/dev/null || true
fi

# 7 日より古い証跡は掃く (セッションは終わっているはず)
find "$PARENT_DIR" "$CHILD_DIR" -type f -mtime +7 -delete 2>/dev/null || true
exit 0
