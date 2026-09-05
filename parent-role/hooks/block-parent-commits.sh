#!/bin/bash
# PreToolUse / matcher: Bash
# 親 (監督) セッションの commit / push を拒否する。
# block-parent-repo-writes.sh が取りこぼす Bash 経由の書き込み (sed -i / cat > file) も、
# ここで commit を止めれば成果物として repo の外へは出ない。
#
# ★ 「書き込み全部禁止」にしないこと。親は scratchpad に計画を書き、memory を更新し、
#   **PR を作り** (gh pr create は親の専権)、マージ後に **branch を掃除する**必要がある。
#   塞ぐのは commit/push 系だけ。
#
# deny : git commit / git push / git apply / git am / git cherry-pick
# 許可 : gh pr create / gh issue create / gh issue comment /
#        git branch -D / git worktree add|remove|list / 読み取り系すべて
#
# - parent-role marker が無ければ素通し (fail-open)
# - escape: ~/.claude/state/parent-role/<session_id>.override が在れば素通し
set -u

PARENT_DIR="${HOME}/.claude/state/parent-role"

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')

[ -e "${PARENT_DIR}/${sid_safe}" ] || exit 0
[ -e "${PARENT_DIR}/${sid_safe}.override" ] && exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# 複合コマンドは区切りで割って 1 セグメントずつ見る (`git log && git push` を捕まえるため)
segments=$(printf '%s' "$cmd" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g')

hit=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  # 明示的な許可 (誤爆させない): gh 系と git branch / git worktree
  printf '%s' "$seg" | grep -qE '(^|[[:space:]])gh([[:space:]]|$)' && continue
  printf '%s' "$seg" | grep -qE '(^|[[:space:]])git[[:space:]]+(branch|worktree)([[:space:]]|$)' && continue
  # git を含み、かつ禁止サブコマンドを 1 語として含むセグメントだけ deny
  printf '%s' "$seg" | grep -qE '(^|[[:space:]])git([[:space:]]|$)' || continue
  if printf '%s' "$seg" | grep -qE '(^|[[:space:]])(commit|push|apply|am|cherry-pick)([[:space:]]|$)'; then
    hit=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    break
  fi
done <<EOF
$segments
EOF

[ -n "$hit" ] || exit 0

reason="親 (監督) セッションは commit / push できません (拒否した箇所: ${hit})。
親のしごとは分割・調整・マージ順の采配であって、実装ではありません。
 - **repo の変更 (PR になるもの)** → spawn_task でチップにする。commit / push は子がやります
 - **repo 外の成果物 (計画・PR 本文・issue 本文・memory)** → そのまま書けます
 - **調査・裏取り** → Agent を run_in_background: true で (親の turn を止めない)
親にも許可されている操作: gh pr create / gh issue create / gh issue comment /
git branch -D / git worktree add|remove|list / 読み取り系すべて (git log / git diff / gh pr view …)。
どうしても親が直接 commit する必要があるなら touch ${PARENT_DIR}/${sid_safe}.override (終わったら消すこと)。"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
