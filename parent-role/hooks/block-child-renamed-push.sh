#!/bin/bash
# PreToolUse / matcher: Bash
# 子 (タスク) セッションが local と remote で branch 名の違う push (`git push origin a:b`) を
# 打つのを拒否する。
#
# Why (2026-09-30, ohishi-exp/rust-ichibanboshi#322 の子 #c322-9): 予定の branch 名が別 worktree に
# 握られていたため `feat/x-2` で作り、`git push origin feat/x-2:feat/x` と別名のまま push した。
# PR の headRefName (feat/x) と local branch 名 (feat/x-2) が食い違い、片付け役
# (worktree-janitor) が同一 branch と判定できず掃除が止まった。
#
# deny : コマンドに `git push` を含み、refspec `<src>:<dst>` の src と dst が違うもの
#        (`refs/heads/` 接頭辞と先頭の `+` は剥がして比べる。`HEAD:<dst>` は現在の branch 名 —
#         `-C <dir>` があればその dir で `git rev-parse --abbrev-ref HEAD` — と比べる)
# 許可 : refspec 無し / `-u origin <name>` / `<name>:<name>` / `--delete`・`-d`・`:<dst>` (削除) /
#        tag の push (`refs/tags/…`・`--tags`) / `git push` 以外すべて
#
# - child-role marker が無ければ素通し (fail-open)。名乗らない子は塞がらない
# - jq が無い / payload が壊れている / session_id が取れない → 素通し
#
# 限界: 引用符やシェル変数展開は解釈しない (空白区切りの単純な分割)。うっかりを止める栓であって、
#       敵対的な回避を防ぐ機能ではない。
set -u

CHILD_DIR="${HOME}/.claude/state/child-role"

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')

[ -e "${CHILD_DIR}/${sid_safe}" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0
printf '%s' "$cmd" | grep -q 'push' || exit 0

cwd=$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null || true)

strip_ref() { # refs/heads/ と先頭の + を剥がす
  local r="${1#+}"
  printf '%s' "${r#refs/heads/}"
}

# 複合コマンドは区切りで割って 1 セグメントずつ見る (`cd x && git push a:b` を捕まえるため)
segments=$(printf '%s' "$cmd" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g')

hit=""
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  read -ra tok <<<"$seg"
  dir="$cwd"; seen_git=0; seen_push=0; skip=0
  positional=()
  i=0; n=${#tok[@]}
  while [ "$i" -lt "$n" ]; do
    t="${tok[$i]}"; i=$((i+1))
    if [ "$seen_git" -eq 0 ]; then
      [ "$t" = git ] && seen_git=1
      continue
    fi
    if [ "$seen_push" -eq 0 ]; then
      if [ "$t" = "-C" ] && [ "$i" -lt "$n" ]; then dir="${tok[$i]}"; i=$((i+1)); continue; fi
      [ "$t" = push ] && seen_push=1
      continue
    fi
    case "$t" in
      --delete|-d|--tags|--mirror) skip=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) i=$((i+1)) ;;   # 値を取るオプション
      -*) ;;
      *) positional+=("$t") ;;
    esac
  done
  [ "$seen_push" -eq 1 ] && [ "$skip" -eq 0 ] || continue
  # positional[0] = remote、[1..] = refspec
  [ "${#positional[@]}" -ge 2 ] || continue
  for spec in "${positional[@]:1}"; do
    case "$spec" in *:*) ;; *) continue ;; esac
    src="${spec%%:*}"; dst="${spec#*:}"
    [ -n "$src" ] && [ -n "$dst" ] || continue              # `:dst` は remote branch の削除
    case "$src$dst" in *refs/tags/*) continue ;; esac
    src=$(strip_ref "$src"); dst=$(strip_ref "$dst")
    if [ "$src" = HEAD ]; then
      if [ -n "$dir" ] && [ -d "$dir" ]; then
        src=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      else
        src=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)
      fi
      [ -n "$src" ] && [ "$src" != HEAD ] || continue       # 取れない / detached は素通し
    fi
    if [ "$src" != "$dst" ]; then
      hit=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
      break 2
    fi
  done
done <<EOF2
$segments
EOF2

[ -n "$hit" ] || exit 0

reason="local と remote で branch 名が違う push は、片付け役 (worktree-janitor) が同一 branch と判定できなくなるので止めた (拒否した箇所: ${hit})。
予定の branch 名が他の worktree に握られているなら、別名で push せず、親へ send_message で [質問] を送ること
(list_sessions でタイトルが #p<親issue> + スペースで始まるセッションを引く)。
通る形: git push / git push -u origin <name> / git push origin <name>:<name> / --delete / tag の push。"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
