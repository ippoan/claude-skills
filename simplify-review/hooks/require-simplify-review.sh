#!/bin/bash
# PreToolUse / matcher: ExitPlanMode|mcp__ccd_session__spawn_task
# 計画から実装へ移る 2 つの口 (plan mode を抜ける / 子タスクを起票する) を、
# このセッションで simplify-reviewer を 1 回以上起動するまで塞ぐ。
#
# Why: 2026-08-24〜31 の 1 週間で +55.7k/−3.4k 行 (16:1)。同型スイープが 3 世代続き、
# 削減を名乗った計画の半分が実装前の実測で消えた。「計画を reviewer に通す」を
# 手順に書くだけでは後回しになる (戻る引き金が無い) ので、口そのものを塞ぐ。
#
# 挙動:
# - 証跡 (~/.claude/state/simplify-reviewed/<session_id>、simplify-review-log.sh が書く) が
#   在れば素通し。1 セッション 1 回で足りる (計画を直したら再度通すのは親の判断)
# - agent 定義 (~/.claude/agents/simplify-reviewer.md) が無い環境では素通し (fail-open)。
#   reviewer が存在しないのに塞ぐと全ての計画が詰む。導入したら必ず定義も置くこと
# - session_id が取れない payload も素通し (誤爆より取りこぼしを選ぶ)
set -u

STATE_DIR="${HOME}/.claude/state/simplify-reviewed"
AGENT_DEF="${HOME}/.claude/agents/simplify-reviewer.md"

[ -e "$AGENT_DEF" ] || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)

sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
[ -s "${STATE_DIR}/${sid_safe}" ] && exit 0

reason="この計画はまだ simplify-reviewer に通っていません (${tool:-この操作} は計画から実装へ移る口なので塞いでいます)。
先に Agent(subagent_type: \"simplify-reviewer\") を起動し、次を渡してください:
 1. 計画テキストの原文 (要約ではなく全文)
 2. repo の絶対パスと基点 SHA (origin/main)
 3. 任意: issue 番号 / 親 issue 番号、repo 固有の担保 (認可 helper 名・gate 登録簿・public repo の禁止語)
返ってきた [BLOCKER]/[MAJOR] を計画に反映してから、この操作をやり直してください。
調査だけのチップでも同じです (reviewer は「対象外」を 1 ターンで返します)。
agent が not found なら定義が遅れて着いているだけです — 少し置いて再試行してください。"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
