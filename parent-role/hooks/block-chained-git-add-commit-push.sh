#!/bin/bash
# PreToolUse / matcher: Bash
# `git add -A` / `git add .` と、`git commit` + `git push` を 1 回の Bash 呼び出しでつなぐ形を、
# 打つ前に拒否して正しい打ち方を返す。
#
# Why (2026-10-14, ohishi-exp/rust-leave-worker#1 の子 #p1-c48): `git add -A && git commit … && git push …` を
# 1 回の Bash で打ち、auto mode の分類器に [Modify Shared Resources] で 3 回止められた (親の中継の許可も
# 効かなかった)。① `git add <ファイルを明示>` ② `git commit` ③ `git push origin <作業 branch>` を別々の
# Bash 呼び出しにしたら 3 つとも通った。先に hook で止めて打ち方を返せば、手順が崩れない。
#
# deny : (a) `git add` の引数に `-A` / `--all` / `.` (単独のトークン) がある
#        (b) 1 つのコマンドに `git commit` と `git push` の両方がある (`&&` `;` `||` `|` 改行のどれでも)
# 許可 : `git add <ファイル>` / `git commit` だけ / `git push` だけ / `git add <ファイル> && git commit` /
#        `git` 以外。`git -C <dir> …` も同じ規則で判定する
#
# - **全セッションに効く** (child / parent の marker は見ない)
# - jq が無い / payload が壊れている / command が空 → 素通し (fail-open)
#
# 限界: 引用符・変数展開は解釈しない (空白区切りの単純な分割)。commit メッセージの中に「&& git push」
#       のような文字列があると誤って止まりうる — 許容する (メッセージを変えればよい)。うっかりを止める栓で
#       あって、敵対的な回避を防ぐ機能ではない。
set -u

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0
printf '%s' "$cmd" | grep -q 'git' || exit 0

# 区切りで割って 1 セグメントずつ見る
segments=$(printf '%s' "$cmd" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|]/\n/g')

hit_add=""; has_commit=0; has_push=0
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  read -ra tok <<<"$seg"
  n=${#tok[@]}; i=0; seen_git=0; sub=""
  while [ "$i" -lt "$n" ]; do
    t="${tok[$i]}"; i=$((i+1))
    if [ "$seen_git" -eq 0 ]; then
      [ "$t" = git ] && seen_git=1
      continue
    fi
    if [ -z "$sub" ]; then
      case "$t" in
        -C|-c|--git-dir|--work-tree|--namespace) i=$((i+1)) ;;   # 値を取るオプション
        -*) ;;
        *) sub="$t"; break ;;
      esac
    fi
  done
  case "$sub" in
    commit) has_commit=1 ;;
    push)   has_push=1 ;;
    add)
      while [ "$i" -lt "$n" ]; do
        case "${tok[$i]}" in
          -A|--all|.) hit_add=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'); break ;;
        esac
        i=$((i+1))
      done
      ;;
  esac
done <<EOF2
$segments
EOF2

if [ -z "$hit_add" ] && ! { [ "$has_commit" -eq 1 ] && [ "$has_push" -eq 1 ]; }; then
  exit 0
fi

reason='`git add -A` / `git add .` と、`git commit` と `git push` を 1 回の Bash でつなぐ形は auto mode の分類器に [Modify Shared Resources] で止められる。`git add <ファイルを明示>`・`git commit`・`git push origin <作業 branch>` を **別々の Bash 呼び出し**で打つこと。'

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
