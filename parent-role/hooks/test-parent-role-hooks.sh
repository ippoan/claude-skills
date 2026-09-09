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
E="${HERE}/warn-archive-refused.sh"

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
         "${HOME}/.claude/state/child-may-ask" "${HOME}/.claude/state/archive-refused" 2>/dev/null
}
mk_parent()  { mkdir -p "${HOME}/.claude/state/parent-role";  : > "${HOME}/.claude/state/parent-role/$1"; }
mk_child()   { mkdir -p "${HOME}/.claude/state/child-role";   : > "${HOME}/.claude/state/child-role/$1"; }
mk_mayask()  { mkdir -p "${HOME}/.claude/state/child-may-ask";: > "${HOME}/.claude/state/child-may-ask/$1"; }

# run <hook> <payload json> → stdout を返す
run() { printf '%s' "$2" | bash "$1" 2>/dev/null; }
# run_err <hook> <payload json> → stderr を返す (PostToolUse / PostToolUseFailure hook は stderr で文面を返す)
run_err() { printf '%s' "$2" | { bash "$1" 2>&1 1>&3 3>&-; } 3>&1; }
# run_rc <hook> <payload json> → exit code を返す
run_rc() { printf '%s' "$2" | bash "$1" >/dev/null 2>&1; echo $?; }

# decision <stdout> → "deny" | "allow"
decision() {
  if printf '%s' "$1" | grep -q '"permissionDecision":"deny"'; then echo deny; else echo allow; fi
}
# has <text> <needle> → "yes" | "no"
has() { if printf '%s' "$1" | grep -qF -- "$2"; then echo yes; else echo no; fi; }

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
archive_payload() { # <session_id> <tool_input.session_id> <tool_response (文字列)>
  jq -nc --arg s "$1" --arg t "$2" --arg r "$3" \
    '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__archive_session",tool_input:{session_id:$t,reason:"PR merged"},tool_response:$r}'
}
archive_failure_payload() { # PostToolUseFailure 形: tool_response 無し、error キーに失敗文言
  jq -nc --arg s "$1" --arg t "$2" --arg r "$3" \
    '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__archive_session",tool_input:{session_id:$t,reason:"PR merged"},error:$r}'
}
archive_payload_blocks() { # tool_response が content block 配列で来る形
  jq -nc --arg s "$1" --arg t "$2" --arg r "$3" \
    '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__archive_session",tool_input:{session_id:$t},tool_response:[{type:"text",text:$r}]}'
}

REFUSED='Session local_child_1 was not archived: the app is keeping it for the user (pinned or in use). Wait or ask the user; they can also archive it from the sidebar.'
BUSY='Session local_child_1 was not archived: it is still working (mid-turn).'
OK_RESP='Archived session local_child_1.'

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
echo "=== E. warn-archive-refused.sh (PostToolUseFailure。拒否の瞬間に §6 の次の一手を出す) ==="
reset_markers
check 28 E '成功応答 → 黙って素通し (exit 0)' 0 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$OK_RESP")")"
check 29 E '「still working」の拒否 → 素通し (pinned の話ではない)' 0 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$BUSY")")"
check 30 E 'pinned 拒否 → exit 2 で文面を返す' 2 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")"
# ↑ で 1 回数えたので、証跡を作り直して 1 回目・2 回目を順に見る
reset_markers
out1=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 31 E '1 回目の文面: 「再試行は 1 回まで」を含む' yes "$(has "$out1" '再試行は 1 回まで')"
check 32 E '1 回目の文面: 3 択はまだ出さない' no "$(has "$out1" 'サイドバー')"
out2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 33 E '2 回目の文面: 「もう再試行しない」を含む' yes "$(has "$out2" 'もう再試行しない')"
check 34 E '2 回目の文面: 3 択 (タブを閉じる)' yes "$(has "$out2" 'タブを閉じる')"
check 35 E '2 回目の文面: 3 択 (サイドバーから archive)' yes "$(has "$out2" 'サイドバーから archive')"
check 36 E '2 回目の文面: 3 択 (子のタブに直接「畳んで」)' yes "$(has "$out2" '直接「畳んで」')"
check 37 E '2 回目の文面: 待たずに続行 + 次の turn で list_sessions' yes "$(has "$out2" '次の turn の頭で list_sessions')"
check 38 E '2 回目の文面: 子へ [決定] ユーザー指示で self-archive を送る手順を出す' yes "$(has "$out2" '[決定] ユーザー指示で self-archive')"
check 39 E '2 回目の文面: [決定] にユーザーの原文を要約せず貼れと書く' yes "$(has "$out2" '原文を、要約せずそのまま貼る')"
check 40 E '2 回目の文面: 原文が無いなら送らないと書く' yes "$(has "$out2" '貼れる原文が無いなら送らない')"
check 41 E '証跡: ~/.claude/state/archive-refused/<sid>-<target> = 2' 2 "$(cat "${HOME}/.claude/state/archive-refused/${SID}-local_child_1" 2>/dev/null)"
out3=$(run_err "$E" "$(archive_payload_blocks "$SID" local_child_1 "$REFUSED")")
check 42 E 'tool_response が content block 配列でも拾う (3 回目)' yes "$(has "$out3" '3 回目')"
reset_markers
outs=$(run_err "$E" "$(archive_payload "$SID" self "$REFUSED")")
check 43 E 'self の拒否 → 「再試行しない」+ サイドバー / タブを閉じる' yes "$(has "$outs" 'サイドバーから archive')"
check 44 E 'self の拒否 → 親へ送る話にしない' yes "$(has "$outs" '親へ送る話でも')"
check 45 E 'self の拒否は証跡を作らない (再試行の回数を数える対象ではない)' none \
  "$( [ -e "${HOME}/.claude/state/archive-refused/${SID}-self" ] && echo made || echo none)"
check 46 E 'tool_response 無し → 素通し' 0 "$(run_rc "$E" "$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__archive_session",tool_input:{session_id:"x"}}')")"
# PostToolUseFailure 形 (tool_response 無し、error キーに拒否文言) — Refs #163
reset_markers
outf1=$(run_err "$E" "$(archive_failure_payload "$SID" local_child_1 "$REFUSED")")
check 47 E 'PostToolUseFailure 形 (error キー) 1 回目: 「再試行は 1 回まで」' yes "$(has "$outf1" '再試行は 1 回まで')"
outf2=$(run_err "$E" "$(archive_failure_payload "$SID" local_child_1 "$REFUSED")")
check 48 E 'PostToolUseFailure 形 (error キー) 2 回目: 3 択 (サイドバーから archive)' yes "$(has "$outf2" 'サイドバーから archive')"
check 49 E 'PostToolUseFailure 形: 証跡 = 2' 2 "$(cat "${HOME}/.claude/state/archive-refused/${SID}-local_child_1" 2>/dev/null)"
reset_markers
outfs=$(run_err "$E" "$(archive_failure_payload "$SID" self "$REFUSED")")
check 50 E 'PostToolUseFailure 形 self の拒否 → 「再試行しない」+ 親へ送る話にしない' yes "$(has "$outfs" '親へ送る話でも')"
check 51 E 'PostToolUseFailure 形 self は証跡を作らない' none \
  "$( [ -e "${HOME}/.claude/state/archive-refused/${SID}-self" ] && echo made || echo none)"

echo
echo "--- 実物の ~/.claude/state を汚していないことの確認 (HOME=$HOME) ---"
find "${HOME}/.claude/state" -mindepth 1 | sed "s|^${HOME}|\$HOME|" | sort

echo
echo "==================== ${PASS} passed / ${FAIL} failed ===================="
[ "$FAIL" -eq 0 ]
