#!/bin/bash
# PreToolUse / matcher: Edit|Write|NotebookEdit
# 親 (監督) セッションから **repo の作業ツリーへの書き込み**を拒否する。
# main clone (.git がディレクトリ) も worktree (.git がファイル) も等しく塞ぐ。
#
# Why (2026-09-05): #p134 の監督セッションが自分で実装を始めた。migration SQL を書き、
# postgres を立て、commit しようとしてユーザーに止められた。その親は task-split の
# 「このセッション (親) は実装せず」を読了して引用まで提出していた。
# **読了チェックは不読を防ぐだけで違反を防げない。** 口そのものを塞ぐ。
#
# ★ 既存の block-main-clone-writes.sh との違い: あちらは worktree を**許可**する
#   (「main clone は誰も書かない」= 所有権の強制)。親は自分で worktree を作ったので
#   素通しした。こちらは **親に限り worktree も塞ぐ**。両方置くこと (目的が違う)。
#
# 挙動:
# - parent-role marker が無ければ素通し (fail-open。名乗らない親は塞がらない)
# - file_path から上へ辿り、.git が在れば (ファイル / ディレクトリを問わず) deny
# - repo 外 (scratchpad / ~/.claude/projects/*/memory / /tmp) は許可
# - escape: ~/.claude/state/parent-role/<session_id>.override が在れば素通し
#
# 限界: Bash 経由の書き込み (sed -i / cat > file) は取りこぼす
#       (block-main-clone-writes.sh と同じ)。ただし block-parent-commits.sh が
#       commit/push を止めるので、成果物として repo の外へは出ない。
set -u

PARENT_DIR="${HOME}/.claude/state/parent-role"

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')

[ -e "${PARENT_DIR}/${sid_safe}" ] || exit 0
[ -e "${PARENT_DIR}/${sid_safe}.override" ] && exit 0

file=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null || true)
[ -n "$file" ] || exit 0

dir=$(dirname -- "$file")
repo=""
while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
  if [ -e "$dir/.git" ]; then repo="$dir"; break; fi
  dir=$(dirname -- "$dir")
done
[ -n "$repo" ] || exit 0

reason="親 (監督) セッションは repo を直接書けません (${repo} は git の作業ツリーです。main clone も worktree も同じ)。
逃げ道は 3 つあります:
 1. **repo の変更 (PR になるもの)** → spawn_task でチップにする。worktree・branch・CI が付き、所有権も分かれます
 2. **repo 外の成果物 (計画・PR 本文・issue 本文・memory)** → そのまま書けます (scratchpad / ~/.claude/projects/*/memory / /tmp は許可)
 3. **調査・裏取り** → Agent を run_in_background: true で起動する。サブエージェントは親の marker を持たないので書けます。**background にすること** — 親の turn を止めるとユーザーの指示に応答できなくなります
どうしても親が直接書く必要があるなら touch ${PARENT_DIR}/${sid_safe}.override (終わったら消すこと)。"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
