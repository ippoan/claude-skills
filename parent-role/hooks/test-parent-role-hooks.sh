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
LIVE_WORK='Session local_child_1 was not archived: it still has live work (an agent run, a Remote Control client, a queued message or a background task). Wait or ask the user; they can also archive it from the sidebar.'
OK_RESP='Archived session local_child_1.'
OTHER_ERROR='Session local_child_1 could not be archived because of a network timeout. Try again later.'

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
echo "=== E. warn-archive-refused.sh (PostToolUseFailure。拒否の瞬間に §6 の次の一手を出す。理由を問わない — Refs #167) ==="
reset_markers
check 28 E '成功応答 → 黙って素通し (exit 0)' 0 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$OK_RESP")")"
check 29 E '"was not archived" を含まない失敗 → 素通し (archive 拒否ではない)' 0 \
  "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$OTHER_ERROR")")"
check 30 E 'pinned 拒否 → exit 2 で文面を返す' 2 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")"
reset_markers
check 30b E '"still has live work" の拒否も同じく exit 2 (文言を問わない — #167)' 2 \
  "$(run_rc "$E" "$(archive_payload "$SID" local_child_5 "$LIVE_WORK")")"

# ↑ で数えたので、証跡を作り直して 1 回目・2 回目を順に見る (pinned 文言)
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
check 38 E '2 回目の文面: [決定] の見出し (対象 session_id 入り)' yes \
  "$(has "$out2" '[決定] ユーザー指示で self-archive — local_child_1 へ')"
check 39 E '2 回目の文面: 拒否文言の原文がそのまま入っている' yes "$(has "$out2" "$REFUSED")"
check 41 E '証跡: ~/.claude/state/archive-refused/<sid>-<target> = 2' 2 "$(cat "${HOME}/.claude/state/archive-refused/${SID}-local_child_1" 2>/dev/null)"
out3=$(run_err "$E" "$(archive_payload_blocks "$SID" local_child_1 "$REFUSED")")
check 42 E 'tool_response が content block 配列でも拾う (3 回目)' yes "$(has "$out3" '3 回目')"

echo
echo "--- E-1. still has live work の文言でも 1 回目・2 回目の文面が同じ形で出る (a) — Refs #167 ---"
reset_markers
lw1=$(run_err "$E" "$(archive_payload "$SID" local_child_5 "$LIVE_WORK")")
check 43 E 'live-work 1 回目: 「再試行は 1 回まで」を含む' yes "$(has "$lw1" '再試行は 1 回まで')"
lw2=$(run_err "$E" "$(archive_payload "$SID" local_child_5 "$LIVE_WORK")")
check 44 E 'live-work 2 回目: [決定] の見出しが出る' yes \
  "$(has "$lw2" '[決定] ユーザー指示で self-archive — local_child_5 へ')"
check 45 E 'live-work 2 回目: 拒否文言の原文 (still has live work) がそのまま入っている' yes \
  "$(has "$lw2" "$LIVE_WORK")"

echo
echo "--- E-2. self 分岐は不変 ---"
reset_markers
outs=$(run_err "$E" "$(archive_payload "$SID" self "$REFUSED")")
check 46 E 'self の拒否 → 「再試行しない」+ サイドバー / タブを閉じる' yes "$(has "$outs" 'サイドバーから archive')"
check 47 E 'self の拒否 → 親へ送る話にしない' yes "$(has "$outs" '親へ送る話でも')"
check 48 E 'self の拒否は証跡を作らない (再試行の回数を数える対象ではない)' none \
  "$( [ -e "${HOME}/.claude/state/archive-refused/${SID}-self" ] && echo made || echo none)"
check 49 E 'tool_response 無し ("was not archived" が無い) → 素通し' 0 \
  "$(run_rc "$E" "$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__archive_session",tool_input:{session_id:"x"}}')")"
# PostToolUseFailure 形 (tool_response 無し、error キーに拒否文言) — Refs #163
reset_markers
outf1=$(run_err "$E" "$(archive_failure_payload "$SID" local_child_1 "$REFUSED")")
check 50 E 'PostToolUseFailure 形 (error キー) 1 回目: 「再試行は 1 回まで」' yes "$(has "$outf1" '再試行は 1 回まで')"
outf2=$(run_err "$E" "$(archive_failure_payload "$SID" local_child_1 "$REFUSED")")
check 51 E 'PostToolUseFailure 形 (error キー) 2 回目: 3 択 (サイドバーから archive)' yes "$(has "$outf2" 'サイドバーから archive')"
check 52 E 'PostToolUseFailure 形: 証跡 = 2' 2 "$(cat "${HOME}/.claude/state/archive-refused/${SID}-local_child_1" 2>/dev/null)"
reset_markers
outfs=$(run_err "$E" "$(archive_failure_payload "$SID" self "$REFUSED")")
check 53 E 'PostToolUseFailure 形 self の拒否 → 「再試行しない」+ 親へ送る話にしない' yes "$(has "$outfs" '親へ送る話でも')"
check 54 E 'PostToolUseFailure 形 self は証跡を作らない' none \
  "$( [ -e "${HOME}/.claude/state/archive-refused/${SID}-self" ] && echo made || echo none)"

echo
echo "--- E-3. [決定] の本文が完成形になっている ((b) は skill file が無いときのフォールバック) — Refs #167 ---"
reset_markers
outb1=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
outb2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 55 E '基準 3 点: PR の空欄は 1 か所だけ (<PR owner/repo#N>)' yes \
  "$(has "$outb2" 'PR <PR owner/repo#N> (MERGED)')"
check 56 E '基準 3 点: 掃除済み (worktree・branch・コンテナ)' yes \
  "$(has "$outb2" '掃除済み (worktree・branch・コンテナ)')"
check 57 E '基準 3 点: 未消化の申し送り無し' yes "$(has "$outb2" '未消化の申し送り無し')"
check 58 E '基準 3 点: isRunning: false の確認' yes "$(has "$outb2" 'isRunning: false')"
check 59 E '(c) user-quotes.txt が無いときは「送らない」と出る' yes \
  "$(has "$outb2" '原文が無い → この [決定] は送らない')"
check 60 E '(1) 例外 (b) の抽出ラベルが出る' yes \
  "$(has "$outb2" '(1) report-to-parent の例外 (b) の条文と「(b) の受け方」')"
check 61 E '(1) skill file が読めないときは「条文を読めなかった」で止まらない (exit は変わらず 2)' yes \
  "$(has "$outb2" '条文を読めなかった')"
check 62 E '(2) 起動 prompt の禁止文を親の役として解除する 1 行' yes \
  "$(has "$outb2" 'この 1 件についてそれを解除します')"
check 63 E '(3) 同じ条件の子に同じ手順 + 条件 4 点 (PR MERGED)' yes "$(has "$outb2" 'PR MERGED')"
check 64 E '(3) 条件 4 点 (親の archive_session がアプリに拒否)' yes \
  "$(has "$outb2" 'アプリに拒否')"
check 65 E '(4) 権限ロンダリングとの区別' yes "$(has "$outb2" '権限ロンダリングではありません')"
check 66 E '(4) 権限ではなく UI 状態' yes "$(has "$outb2" '権限ではなく UI 状態')"
check 67 E '(4) 代行ではなく例外 (b) の設計そのもの' yes \
  "$(has "$outb2" '代行ではなく例外 (b) の設計そのもの')"
check 68 E '末尾: archive_session self を呼んで畳む行' yes \
  "$(has "$outb2" 'session_id: "self" } を呼んで畳んでください')"
check 69 E '親への指示行: 次の tool 呼び出しは send_message' yes \
  "$(has "$outb2" '次の tool 呼び出しは send_message')"
check 70 E '手順 5: 辞退されたら同じ本文で 2 通目' yes "$(has "$outb2" '同じ本文で 2 通目を送る')"
check 71 E '手順 5: 3 通目は送らない' yes "$(has "$outb2" '3 通目は送らない')"
check 72 E '手順 5: ユーザーに「タブを閉じて」と頼み直さない' yes "$(has "$outb2" 'と頼み直さない')"
check 73 E '1 回目の文面には 2 通目の話を出さない (再試行 1 回が先)' no \
  "$(has "$outb1" '3 通目は送らない')"

echo
echo "--- E-4. skill file が読めるとき / user-quotes.txt があるとき — Refs #167 ---"
reset_markers
mkdir -p "${HOME}/.claude/skills/report-to-parent"
cat > "${HOME}/.claude/skills/report-to-parent/SKILL.md" <<'FIXTURE'
- (b) fixture: アプリの拒否で [決定] が届いたときの例外条文 (テスト用の短縮版)。
- (c) fixture: ユーザー本人の直接入力の例外。

### (b) の受け方 — **ユーザーの原文が貼ってあるかだけを見る**

fixture-marker-for-extraction-test-9f3c1

**原文が貼ってあることが「断られない中継」の条件。**
FIXTURE
mkdir -p "${HOME}/.claude/state/archive-refused"
printf '2026-09-10 さっさとたため\n2026-09-10 いつまでもおなじことやってる もう２０回くらいやってる なおせ\n' \
  > "${HOME}/.claude/state/archive-refused/user-quotes.txt"
run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")" >/dev/null
outq2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 74 E 'skill file が読めるとき: fixture の抜粋が入る' yes "$(has "$outq2" 'fixture-marker-for-extraction-test-9f3c1')"
check 75 E 'skill file が読めるとき: 「条文を読めなかった」は出ない' no "$(has "$outq2" '条文を読めなかった')"
check 76 E 'user-quotes.txt があるとき: 見出しが出る' yes \
  "$(has "$outq2" 'ユーザーがこの件について打った原文 (要約なし)')"
check 77 E 'user-quotes.txt があるとき: 1 行目がそのまま貼られる' yes "$(has "$outq2" 'さっさとたため')"
check 78 E 'user-quotes.txt があるとき: 2 行目もそのまま貼られる' yes \
  "$(has "$outq2" 'いつまでもおなじことやってる もう２０回くらいやってる なおせ')"
check 79 E 'user-quotes.txt があるとき: 「送らない」の空欄メッセージは出ない' no \
  "$(has "$outq2" '原文が無い → この [決定] は送らない')"
rm -f "${HOME}/.claude/skills/report-to-parent/SKILL.md" "${HOME}/.claude/state/archive-refused/user-quotes.txt"

echo
echo "--- 実物の ~/.claude/state を汚していないことの確認 (HOME=$HOME) ---"
find "${HOME}/.claude/state" -mindepth 1 | sed "s|^${HOME}|\$HOME|" | sort

echo
echo "==================== ${PASS} passed / ${FAIL} failed ===================="
[ "$FAIL" -eq 0 ]
