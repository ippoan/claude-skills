#!/bin/bash
# parent-role hooks の受け入れテスト。
#
# ★ HOME を一時ディレクトリへ差し替えて回すので、~/.claude/state/ の実物は汚さない。
# 使い方: bash parent-role/hooks/test-parent-role-hooks.sh
set -u

HERE=$(cd -- "$(dirname -- "$0")" && pwd)
A="${HERE}/session-role-log.sh"
B="${HERE}/block-parent-repo-writes.sh"
C="${HERE}/block-parent-commits.sh"
D="${HERE}/block-child-asks-user.sh"

SANDBOX=$(mktemp -d /tmp/parent-role-hooks-test.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="${SANDBOX}/home"
mkdir -p "${HOME}/.claude/state"

# 対象ファイルの置き場 (repo 3 種)
mkdir -p "${SANDBOX}/wt/sub"        && : > "${SANDBOX}/wt/.git"          # worktree (.git がファイル)
mkdir -p "${SANDBOX}/clone/sub"     && mkdir -p "${SANDBOX}/clone/.git"  # main clone (.git がディレクトリ)
mkdir -p "${SANDBOX}/outside"                                            # repo 外 (/tmp 配下)

PASS=0; FAIL=0
SID="local_self_1"

reset_markers() {
  rm -rf "${HOME}/.claude/state/parent-role" "${HOME}/.claude/state/child-role" \
         "${HOME}/.claude/state/child-may-ask" 2>/dev/null
}
mk_parent()  { mkdir -p "${HOME}/.claude/state/parent-role";  : > "${HOME}/.claude/state/parent-role/$1"; }
mk_child()   { mkdir -p "${HOME}/.claude/state/child-role";   : > "${HOME}/.claude/state/child-role/$1"; }
mk_mayask()  { mkdir -p "${HOME}/.claude/state/child-may-ask";: > "${HOME}/.claude/state/child-may-ask/$1"; }

# run <hook> <payload json> → stdout を返す
run() { printf '%s' "$2" | bash "$1" 2>/dev/null; }

# decision <stdout> → "deny" | "allow"
decision() {
  if printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; then echo deny; else echo allow; fi
}

check() { # check <#> <hook> <説明> <期待> <実際>
  if [ "$4" = "$5" ]; then
    PASS=$((PASS+1)); printf 'ok   %-3s [%s] %-58s 期待=%-6s 実際=%s\n' "$1" "$2" "$3" "$4" "$5"
  else
    FAIL=$((FAIL+1)); printf 'FAIL %-3s [%s] %-58s 期待=%-6s 実際=%s\n' "$1" "$2" "$3" "$4" "$5"
  fi
}

state_of() { # marker の有無を "parent" / "child" / "none" / "both" で返す
  p=no; c=no
  [ -e "${HOME}/.claude/state/parent-role/$1" ] && p=yes
  [ -e "${HOME}/.claude/state/child-role/$1" ]  && c=yes
  if   [ $p = yes ] && [ $c = yes ]; then echo both
  elif [ $p = yes ]; then echo parent
  elif [ $c = yes ]; then echo child
  else echo none; fi
}

title_payload() { # <session_id そのもの> <tool_input.session_id> <title>
  jq -nc --arg s "$1" --arg t "$2" --arg ti "$3" \
    '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__set_session_title",tool_input:{session_id:$t,title:$ti}}'
}
file_payload() { jq -nc --arg s "$1" --arg f "$2" '{session_id:$s,tool_name:"Write",tool_input:{file_path:$f,content:"x"}}'; }
bash_payload() { jq -nc --arg s "$1" --arg c "$2" '{session_id:$s,tool_name:"Bash",tool_input:{command:$c}}'; }
ask_payload()  { jq -nc --arg s "$1" '{session_id:$s,tool_name:"AskUserQuestion",tool_input:{questions:[]}}'; }

echo "=== A. session-role-log.sh (証跡を立てる。常に素通し) ==="
reset_markers
run "$A" "$(title_payload "$SID" self '#p134 NFC タイムカード端末の監督')" >/dev/null
check 1 A 'session_id:"self" / title:"#p134 …" → parent marker' parent "$(state_of "$SID")"

reset_markers
run "$A" "$(title_payload "$SID" local_xxx '#p134 NFC タイムカード端末の監督')" >/dev/null
check 2 A 'tool_input.session_id が "self" 以外 → 何も作らない' none "$(state_of "$SID")"

reset_markers
run "$A" "$(title_payload "$SID" self '[S] #c134-2 doc を直す')" >/dev/null
check 3 A 'title:"[S] #c134-2 …" (親と同じ issue の枝) → child marker' child "$(state_of "$SID")"

reset_markers
run "$A" "$(title_payload "$SID" self '[O] #p134-c152 hook を作る')" >/dev/null
check 4 A 'title:"[O] #p134-c152 …" (自分の issue を持つ子) → child marker' child "$(state_of "$SID")"

reset_markers; mk_parent "$SID"; mk_child "$SID"
run "$A" "$(title_payload "$SID" self '[旧] #p134 NFC タイムカード端末の監督')" >/dev/null
check 5 A 'title:"[旧] #p134 …" (交代した旧親) → 両方消える' none "$(state_of "$SID")"

echo
echo "=== B. block-parent-repo-writes.sh (親の repo 書き込みを塞ぐ) ==="
reset_markers; mk_parent "$SID"
check 6 B "parent marker 有 + worktree 内 (.git がファイル)" deny \
  "$(decision "$(run "$B" "$(file_payload "$SID" "${SANDBOX}/wt/sub/migration.sql")")")"
check 7 B "parent marker 有 + main clone 内 (.git がディレクトリ)" deny \
  "$(decision "$(run "$B" "$(file_payload "$SID" "${SANDBOX}/clone/sub/SKILL.md")")")"
check 8 B "parent marker 有 + repo 外 (/tmp 配下)" allow \
  "$(decision "$(run "$B" "$(file_payload "$SID" "${SANDBOX}/outside/plan.md")")")"
reset_markers
check 9 B "marker 無 + worktree 内 (fail-open)" allow \
  "$(decision "$(run "$B" "$(file_payload "$SID" "${SANDBOX}/wt/sub/migration.sql")")")"

echo
echo "=== C. block-parent-commits.sh (親の commit/push を塞ぐ) ==="
reset_markers; mk_parent "$SID"
check 10 C 'parent marker 有 + "git commit -m x"' deny \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git commit -m x')")")"
check 11 C 'parent marker 有 + "gh pr create --fill"' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'gh pr create --fill')")")"
check 12 C 'parent marker 有 + "git branch -D foo"' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git branch -D foo')")")"

echo
echo "=== D. block-child-asks-user.sh (子のユーザー質問を塞ぐ) ==="
reset_markers; mk_child "$SID"
check 13 D "child marker 有" deny "$(decision "$(run "$D" "$(ask_payload "$SID")")")"
reset_markers; mk_parent "$SID"
check 14 D "parent marker 有 (親はユーザーに聞いてよい)" allow "$(decision "$(run "$D" "$(ask_payload "$SID")")")"
reset_markers; mk_child "$SID"; mk_mayask "$SID"
check 15 D "child marker 有 + child-may-ask 有 (escape)" allow "$(decision "$(run "$D" "$(ask_payload "$SID")")")"

echo
echo "=== 追加: 誤爆させない / 取りこぼさない ==="
reset_markers; mk_parent "$SID"
check 16 C 'parent: "git push origin HEAD" (単体)' deny \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git push origin HEAD')")")"
check 17 C 'parent: "git log --oneline -5 && git push" (複合の後段)' deny \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git log --oneline -5 && git push')")")"
check 18 C 'parent: "git worktree add /x -b b origin/main"' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git worktree add /x -b b origin/main')")")"
check 19 C 'parent: "git config --get remote.origin.pushurl" (push を含むが語ではない)' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git config --get remote.origin.pushurl')")")"
check 20 C 'parent: "git cherry-pick abc123"' deny \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git cherry-pick abc123')")")"
check 21 C 'parent: "gh issue comment 152 --body x"' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'gh issue comment 152 --body x')")")"
reset_markers
check 22 C 'marker 無 + "git commit -m x" (fail-open)' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git commit -m x')")")"
reset_markers; mk_parent "$SID"; : > "${HOME}/.claude/state/parent-role/${SID}.override"
check 23 B 'parent marker 有 + .override 有 → 素通し' allow \
  "$(decision "$(run "$B" "$(file_payload "$SID" "${SANDBOX}/wt/sub/migration.sql")")")"
check 24 C 'parent marker 有 + .override 有 → 素通し' allow \
  "$(decision "$(run "$C" "$(bash_payload "$SID" 'git commit -m x')")")"
reset_markers; mk_parent "$SID"
check 25 B 'parent marker 有 + NotebookEdit (notebook_path)' deny \
  "$(decision "$(run "$B" "$(jq -nc --arg s "$SID" --arg f "${SANDBOX}/wt/sub/a.ipynb" '{session_id:$s,tool_name:"NotebookEdit",tool_input:{notebook_path:$f}}')")")"
reset_markers
run "$A" "$(title_payload "$SID" self '[旧] #p134 …')" >/dev/null
check 26 A '[旧] は parent としても child としても立たない' none "$(state_of "$SID")"
reset_markers; mk_child "$SID"
run "$A" "$(title_payload "$SID" self '#p134 NFC タイムカード端末の監督')" >/dev/null
check 27 A '親を名乗り直すと child marker は消える' parent "$(state_of "$SID")"

echo
echo "--- 実物の ~/.claude/state を汚していないことの確認 (HOME=$HOME) ---"
find "${HOME}/.claude/state" -mindepth 1 | sed "s|^${HOME}|\$HOME|" | sort

echo
echo "==================== ${PASS} passed / ${FAIL} failed ===================="
[ "$FAIL" -eq 0 ]
