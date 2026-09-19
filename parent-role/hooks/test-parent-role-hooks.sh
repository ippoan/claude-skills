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
G="${HERE}/require-spawn-task-title.sh"

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
mk_parent_titled() { mkdir -p "${HOME}/.claude/state/parent-role"; printf '%s\n' "$2" > "${HOME}/.claude/state/parent-role/$1"; }

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
spawn_payload() { # <session_id> <title>
  jq -nc --arg s "$1" --arg t "$2" \
    '{session_id:$s,tool_name:"mcp__ccd_session__spawn_task",tool_input:{title:$t,prompt:"x",tldr:"x"}}'
}
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
# remedy 3 分岐のどれにも当たらない未知の文言。**従来どおりの経路 (1 回目 = 再試行 1 回 →
# 2 回目 = [決定] 完成形) に落ちること**を見るのに使う (#167 の穴を開け直していないかの回帰)。
# ★ 2026-09-18: 以前この経路は REFUSED (pinned or in use) で見ていたが、app_hold は
#   n <= 2 のあいだ unpin 指示に変わったので、**従来経路の期待値はこちらの文言へ移設した**。
UNKNOWN_HOLD='Session local_child_1 was not archived: it is still working (a turn in progress). Wait or ask the user; they can also archive it from the sidebar.'
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
echo "=== E. warn-archive-refused.sh (PostToolUseFailure。拒否の瞬間に §6 の次の一手を出す。**検出**は理由を問わない — Refs #167。**remedy の出し分けは H**) ==="
reset_markers
check 28 E '成功応答 → 黙って素通し (exit 0)' 0 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$OK_RESP")")"
check 29 E '"was not archived" を含まない失敗 → 素通し (archive 拒否ではない)' 0 \
  "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$OTHER_ERROR")")"
check 30 E 'pinned 拒否 → exit 2 で文面を返す' 2 "$(run_rc "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")"
reset_markers
check 30b E '"still has live work" の拒否も同じく exit 2 (文言を問わない — #167)' 2 \
  "$(run_rc "$E" "$(archive_payload "$SID" local_child_5 "$LIVE_WORK")")"

# ↑ で数えたので、証跡を作り直して 1 回目・2 回目を順に見る。
# ★ 2026-09-18: ここは **未知の文言** (UNKNOWN_HOLD) で回す。app_hold (pinned or in use) は
#   n <= 2 が unpin 指示に変わったため、「2 回目で [決定] 完成形」を見るこの一連は
#   **文言定数を未知の文言へ差し替えて従来経路のまま**にした (app_hold の 3 回目は H-1 で別に見る)。
reset_markers
out1=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
check 31 E '1 回目の文面: 「再試行は 1 回まで」を含む' yes "$(has "$out1" '再試行は 1 回まで')"
check 32 E '1 回目の文面: 3 択はまだ出さない' no "$(has "$out1" 'サイドバー')"
out2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
check 33 E '2 回目の文面: 「もう再試行しない」を含む' yes "$(has "$out2" 'もう再試行しない')"
check 34 E '2 回目の文面: 3 択 (タブを閉じる)' yes "$(has "$out2" 'タブを閉じる')"
check 35 E '2 回目の文面: 3 択 (サイドバーから archive)' yes "$(has "$out2" 'サイドバーから archive')"
check 36 E '2 回目の文面: 3 択 (子のタブに直接「畳んで」)' yes "$(has "$out2" '直接「畳んで」')"
check 37 E '2 回目の文面: 待たずに続行 + 次の turn は Agent で session-archiver' yes \
  "$(has "$out2" '次の turn は Agent で session-archiver')"
check 38 E '2 回目の文面: [決定] の見出し (対象 session_id 入り)' yes \
  "$(has "$out2" '[決定] ユーザー指示で self-archive — local_child_1 へ')"
check 39 E '2 回目の文面: 拒否文言の原文がそのまま入っている' yes "$(has "$out2" "$UNKNOWN_HOLD")"
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
# ★ 2026-09-18 (意図した挙動変更): self でも証跡を数える。escalate (1 回目 = unpin /
#   2 回目 = サイドバー) に n が要るため、加算を self 判定より前に移した。
check 48 E 'self の拒否も証跡を数える (escalate に n が要る)' 1 \
  "$(cat "${HOME}/.claude/state/archive-refused/${SID}-self" 2>/dev/null)"
check 49 E 'tool_response 無し ("was not archived" が無い) → 素通し' 0 \
  "$(run_rc "$E" "$(jq -nc --arg s "$SID" '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__archive_session",tool_input:{session_id:"x"}}')")"
# PostToolUseFailure 形 (tool_response 無し、error キーに拒否文言) — Refs #163
reset_markers
outf1=$(run_err "$E" "$(archive_failure_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
check 50 E 'PostToolUseFailure 形 (error キー) 1 回目: 「再試行は 1 回まで」' yes "$(has "$outf1" '再試行は 1 回まで')"
outf2=$(run_err "$E" "$(archive_failure_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
check 51 E 'PostToolUseFailure 形 (error キー) 2 回目: 3 択 (サイドバーから archive)' yes "$(has "$outf2" 'サイドバーから archive')"
check 52 E 'PostToolUseFailure 形: 証跡 = 2' 2 "$(cat "${HOME}/.claude/state/archive-refused/${SID}-local_child_1" 2>/dev/null)"
reset_markers
outfs=$(run_err "$E" "$(archive_failure_payload "$SID" self "$REFUSED")")
check 53 E 'PostToolUseFailure 形 self の拒否 → 「再試行しない」+ 親へ送る話にしない' yes "$(has "$outfs" '親へ送る話でも')"
check 54 E 'PostToolUseFailure 形 self も証跡を数える (同上)' 1 \
  "$(cat "${HOME}/.claude/state/archive-refused/${SID}-self" 2>/dev/null)"

echo
echo "--- E-3. [決定] の本文が完成形になっている ((b) は skill file が無いときのフォールバック) — Refs #167 ---"
reset_markers
outb1=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
outb2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
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
run_err "$E" "$(archive_payload "$SID" local_child_1 "$UNKNOWN_HOLD")" >/dev/null
outq2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$UNKNOWN_HOLD")")
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
echo "=== F. require-archive-decision-sent.sh (PreToolUse 全ツール。[決定] を送るまで口を塞ぐ — Refs ippoan/alc-app-s3#135) ==="
F="${HERE}/require-archive-decision-sent.sh"
AR="${HOME}/.claude/state/archive-refused"
PENDING="${AR}/pending-${SID}"
SENT="${AR}/sent-${SID}-local_child_1"
# hook の本文は 2 スペース字下げで出る。そのまま貼られた形で通ることを見る
DECISION_BODY='  [決定] ユーザー指示で self-archive — local_child_1 へ

  親の archive_session がアプリに 2 回拒否されました。'
send_payload() { # <session_id> <宛先> <message>
  jq -nc --arg s "$1" --arg t "$2" --arg m "$3" \
    '{session_id:$s,tool_name:"mcp__ccd_session_mgmt__send_message",tool_input:{session_id:$t,message:$m}}'
}
tool_payload() { jq -nc --arg s "$1" --arg n "$2" '{session_id:$s,tool_name:$n,tool_input:{}}'; }
with_quotes() { mkdir -p "$AR"; printf '2026-09-10 さっさとたため\n' > "${AR}/user-quotes.txt"; }
exists() { if [ -e "$1" ]; then echo yes; else echo no; fi; }
refuse() { run_err "$E" "$(archive_failure_payload "$SID" "$1" "$LIVE_WORK")" >/dev/null; }

echo "--- F-a. pending を作る条件 ---"
reset_markers; with_quotes
refuse local_child_1
check 80 F '(a) 1 回目の拒否では pending を作らない' no "$(exists "$PENDING")"
refuse local_child_1
check 81 F '(a) 2 回目の拒否で pending が作られる' yes "$(exists "$PENDING")"
check 82 F '(a) pending の中身 = 対象の子 session_id 1 行' local_child_1 "$(cat "$PENDING" 2>/dev/null)"
reset_markers
refuse local_child_1; refuse local_child_1
check 83 F '(a) user-quotes.txt が無い回は作らない (本文が「送らない」)' no "$(exists "$PENDING")"
reset_markers; with_quotes
refuse self; refuse self
check 84 F '(a) self の拒否は作らない' no "$(exists "$PENDING")"

echo "--- F-b. pending 中は塞ぐ / 状態確認と再試行は通す ---"
reset_markers; with_quotes
refuse local_child_1; refuse local_child_1
check 85 F '(b) pending 中の Bash → deny' deny "$(decision "$(run "$F" "$(bash_payload "$SID" 'git status')")")"
check 86 F '(b) pending 中の Write (repo 外でも) → deny' deny \
  "$(decision "$(run "$F" "$(file_payload "$SID" "${SANDBOX}/outside/plan.md")")")"
check 87 F '(b) pending 中の AskUserQuestion → deny' deny "$(decision "$(run "$F" "$(ask_payload "$SID")")")"
check 88 F '(b) deny の理由に宛先の子 session_id が入る' yes \
  "$(has "$(run "$F" "$(bash_payload "$SID" 'ls')")" 'send_message で local_child_1 へ')"
check 89 F '(b) list_sessions → 許可' allow \
  "$(decision "$(run "$F" "$(tool_payload "$SID" mcp__ccd_session_mgmt__list_sessions)")")"
check 90 F '(b) archive_session → 許可 (再試行は妨げない)' allow \
  "$(decision "$(run "$F" "$(tool_payload "$SID" mcp__ccd_session_mgmt__archive_session)")")"
check 91 F '(b) ToolSearch → 許可 (deferred の send_message を読む手段)' allow \
  "$(decision "$(run "$F" "$(tool_payload "$SID" ToolSearch)")")"
check 91.1 F '(b) Agent → 許可 (session-archiver 等に archive_session を打たせる経路。Refs ippoan/alc-app-s3#135)' allow \
  "$(decision "$(run "$F" "$(tool_payload "$SID" Agent)")")"
check 91.3 F '(b) get_session → 許可 (pinned の確認。pinned が原因の回は unpin が正解 — #93259)' allow \
  "$(decision "$(run "$F" "$(tool_payload "$SID" mcp__ccd_session_mgmt__get_session)")")"
check 91.4 F '(b) set_pinned → 許可 (pin を外して打ち直す経路を塞がない)' allow \
  "$(decision "$(run "$F" "$(tool_payload "$SID" mcp__ccd_sidebar__set_pinned)")")"
check 91.2 F '(b) Bash は引き続き deny (Agent / get_session / set_pinned 以外まで緩めていないことの確認)' deny \
  "$(decision "$(run "$F" "$(bash_payload "$SID" 'ls')")")"

echo "--- F-c. 宛先・見出しが違う send_message は塞ぐ ---"
check 92 F '(c) 別の宛先への send_message → deny' deny \
  "$(decision "$(run "$F" "$(send_payload "$SID" local_child_9 "$DECISION_BODY")")")"
check 93 F '(c) 正しい宛先でも見出しが違う → deny' deny \
  "$(decision "$(run "$F" "$(send_payload "$SID" local_child_1 '[報告] 子も拒否されたので送りません')")")"
check 94 F '(c) deny の後も pending は残る' yes "$(exists "$PENDING")"

echo "--- F-d. 正しい宛先・見出しの send_message で許可され pending が消える ---"
check 95 F '(d) 正しい宛先・見出し (字下げ付きのまま) → 許可' allow \
  "$(decision "$(run "$F" "$(send_payload "$SID" local_child_1 "$DECISION_BODY")")")"
check 96 F '(d) 許可と同時に pending が消える' no "$(exists "$PENDING")"
check 97 F '(d) 送信数 sent-<sid>-<子> = 1' 1 "$(cat "$SENT" 2>/dev/null)"
check 98 F '(d) 消えた後の Bash は素通し' allow "$(decision "$(run "$F" "$(bash_payload "$SID" 'git status')")")"
refuse local_child_1
check 99 F '(d) 送信 1 通の後の拒否 → pending をもう一度作る (2 通目)' yes "$(exists "$PENDING")"
run "$F" "$(send_payload "$SID" local_child_1 "$DECISION_BODY")" >/dev/null
refuse local_child_1
check 100 F '(d) 送信 2 通の後の拒否 → 作らない (3 通目は送らない — task-split §6)' no "$(exists "$PENDING")"

echo "--- F-e. pending 無し / session_id 無しは素通し ---"
reset_markers
check 101 F '(e) pending 無し + Bash → 素通し' allow "$(decision "$(run "$F" "$(bash_payload "$SID" 'git commit -m x')")")"
check 102 F '(e) session_id の無い payload → 素通し' allow \
  "$(decision "$(run "$F" '{"tool_name":"Bash","tool_input":{"command":"ls"}}')")"
with_quotes; refuse local_child_1; refuse local_child_1
check 103 F '(e) 別 session_id (別セッション。サブエージェントは親と同じ id) は pending を共有しない' allow \
  "$(decision "$(run "$F" "$(bash_payload local_other_2 'ls')")")"

echo
echo "=== G. require-spawn-task-title.sh (PreToolUse spawn_task。title を命名規約 4 形で検査 — Refs ippoan/alc-app-s3#135, ippoan/claude-skills#186) ==="
reset_markers
check 104 G 'marker 無し + 規約違反 title → 素通し' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p135-c-kiosk-measurements 題')")")"

reset_markers; mk_parent "$SID"
check 105 G 'parent marker (空) + 枝の子 → 通る' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #c135-18 題')")")"
check 106 G 'parent marker (空) + 自 issue の子 → 通る' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[O] #p874-c987 題')")")"
check 107 G 'parent marker (空) + 自 issue の子 (さらに分岐番号) → 通る' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p874-c987-2 題')")")"
check 108 G 'parent marker (空) + 後継の親 → 通る' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '#p135 題')")")"

reset_markers; mk_parent "$SID"
check 109 G '不正: #c の後が語 (c-kiosk-measurements)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p135-c-kiosk-measurements 題')")")"
check 110 G '不正: 分岐番号が数字でない (#c135-x)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #c135-x 題')")")"
check 111 G '不正: 題が無い (#c135-18 のみ)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #c135-18')")")"
check 112 G '不正: [S]/[O] が無い (#c135-18 題)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '#c135-18 題')")")"
check 113 G '不正: [S]/[O] 以外の角括弧 ([X] #c135-18 題)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[X] #c135-18 題')")")"

reset_markers; mk_parent_titled "$SID" '#p135 監督'
check 114 G '親 marker が #p135 監督 + 子 title が #c136-… (issue 番号の取り違え)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #c136-1 題')")")"
check 115 G '親 marker が #p135 監督 + 子 title が #c135-… (issue 番号が一致)' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #c135-1 題')")")"

reset_markers; mk_parent "$SID"
check 116 G '親 marker が空 (改名前の古い marker 等) + #c136-… → 番号照合は飛ばして通る' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #c136-1 題')")")"

reset_markers; mk_child "$SID"
check 117 G 'child marker だけ (parent marker 無し) + 違反 title → 素通し' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p135-c-dtako 題')")")"

reset_markers; mk_parent "$SID"
check 118 G 'payload が壊れている (不正 JSON) → 素通し' allow \
  "$(decision "$(printf '{not json' | bash "$G" 2>/dev/null)")"

echo
echo "--- G-2. 形4 (別案件の新しい親: [S]/[O] #p<issue> <題>) — 番号照合を飛ばす (Refs ippoan/claude-skills#186) ---"
reset_markers; mk_parent_titled "$SID" '#p310 遠隔点呼の点呼種別の監督'
check 139 G '形4: [S] #p353 題 → marker が #p310 でも通る (番号照合を飛ばす)' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p353 題')")")"
check 140 G '形4: [O] #p353 題 → 通る' allow \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[O] #p353 題')")")"
check 141 G '形3 (接頭辞なし): #p353 題 → marker が #p310 なら番号照合で deny (後継の親は従来どおり)' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '#p353 題')")")"
check 142 G '不正: [S] #p353題 (スペース無し) → deny' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p353題')")")"
check 143 G '不正: [S] #p353  (題が空) → deny' deny \
  "$(decision "$(run "$G" "$(spawn_payload "$SID" '[S] #p353 ')")")"

echo
echo "--- G-3. [S] #p353 題 を set_session_title に渡しても marker が立たない (改名前は素通り。意図の固定) ---"
reset_markers
run "$A" "$(title_payload "$SID" self '[S] #p353 題')" >/dev/null
check 144 A '[S] #p353 題 は session-role-log.sh のどの分岐にも当たらず parent marker を立てない' none \
  "$(state_of "$SID")"

echo
echo "--- G-1. session-role-log.sh (A) が書く marker の中身がタイトル 1 行になっている ---"
reset_markers
run "$A" "$(title_payload "$SID" self '#p135 監督')" >/dev/null
check 119 A 'parent marker の中身が set_session_title の title と一致 (空ファイルではない)' '#p135 監督' \
  "$(cat "${HOME}/.claude/state/parent-role/${SID}" 2>/dev/null)"

echo
echo "=== H. warn-archive-refused.sh の remedy 3 分岐 (2026-09-18。**検出**は #167 のまま・**次の一手だけ**文言で分ける) ==="
# 上流 (Claude Desktop) は 4 分岐 (running / losable_work / pinned / on_screen) を計算しているのに
# 文言が 2 種に潰れている — anthropics/claude-code#93259 / #93269 / #93270 (いずれも open)。
PENDING_H="${HOME}/.claude/state/archive-refused/pending-${SID}"

echo "--- H-1. app_hold (pinned or in use): n <= 2 は **unpin が先**。pending を立てない ---"
reset_markers; with_quotes
ah1=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 120 E 'app_hold 1 回目: get_session で pinned を見ろと出す' yes "$(has "$ah1" 'get_session')"
check 121 E 'app_hold 1 回目: set_pinned で外せと出す' yes "$(has "$ah1" 'set_pinned')"
check 122 E 'app_hold 1 回目: pending を立てない (立てると親が unpin すら打てない)' no "$(exists "$PENDING_H")"
check 123 E 'app_hold 1 回目: [決定] 本文は出さない (pin には中継が効かない)' no \
  "$(has "$ah1" '[決定] ユーザー指示で self-archive')"
ah2=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 124 E 'app_hold 2 回目: まだ unpin 経路 (pending を立てない)' no "$(exists "$PENDING_H")"
check 125 E 'app_hold 2 回目: 上流 issue 93259 を示す' yes "$(has "$ah2" '93259')"
ah3=$(run_err "$E" "$(archive_payload "$SID" local_child_1 "$REFUSED")")
check 126 E 'app_hold 3 回目: 従来の [決定] 完成形へ落ちる' yes \
  "$(has "$ah3" '[決定] ユーザー指示で self-archive — local_child_1 へ')"
check 127 E 'app_hold 3 回目: pending が立つ (中継が正解の回)' yes "$(exists "$PENDING_H")"

echo "--- H-2. app_hold + self: on_screen は self では発火しない ⇒ 原因は pinned で確定 ---"
reset_markers
sh1=$(run_err "$E" "$(archive_payload "$SID" self "$REFUSED")")
check 128 E 'self app_hold 1 回目: 「原因は pinned で確定」と断言する' yes "$(has "$sh1" '原因は pinned で確定')"
check 129 E 'self app_hold 1 回目: set_pinned で外して打ち直す手順を出す' yes "$(has "$sh1" 'set_pinned')"
sh2=$(run_err "$E" "$(archive_payload "$SID" self "$REFUSED")")
check 130 E 'self app_hold 2 回目: サイドバーへ escalate (証跡 n を使った出し分け)' yes \
  "$(has "$sh2" 'アプリ側でしか外せません')"

echo "--- H-3. live_work: [決定] を 2 通送っても続くなら #93270 の agent run leak ---"
reset_markers; with_quotes
printf '2' > "${HOME}/.claude/state/archive-refused/sent-${SID}-local_child_7"
lk=$(run_err "$E" "$(archive_payload "$SID" local_child_7 "$LIVE_WORK")")
check 131 E 'live_work + 送信 2 通: 上流 issue 93270 を示す' yes "$(has "$lk" '93270')"
check 132 E 'live_work + 送信 2 通: [決定] 本文を出さない (3 通目を送らせない)' no \
  "$(has "$lk" '[決定] ユーザー指示で self-archive')"
check 133 E 'live_work + 送信 2 通: サイドバーからの archive へ誘導 (唯一の復帰手段)' yes \
  "$(has "$lk" 'サイドバーから archive してください')"
check 134 E 'live_work + 送信 2 通: pending を立てない' no "$(exists "$PENDING_H")"

echo "--- H-4. 未知の文言は**従来どおり** (1 回目 = 再試行 1 回 → 2 回目 = [決定]) — #167 の回帰 ---"
reset_markers; with_quotes
uk1=$(run_err "$E" "$(archive_payload "$SID" local_child_8 "$UNKNOWN_HOLD")")
check 135 E '未知の文言 1 回目: 「再試行は 1 回まで」' yes "$(has "$uk1" '再試行は 1 回まで')"
check 136 E '未知の文言 1 回目: unpin を持ち出さない (知らない文言に remedy を当てない)' no \
  "$(has "$uk1" 'set_pinned')"
uk2=$(run_err "$E" "$(archive_payload "$SID" local_child_8 "$UNKNOWN_HOLD")")
check 137 E '未知の文言 2 回目: [決定] 完成形が出る' yes \
  "$(has "$uk2" '[決定] ユーザー指示で self-archive — local_child_8 へ')"
check 138 E '未知の文言 2 回目: pending が立つ' yes "$(exists "$PENDING_H")"

echo
echo "--- 実物の ~/.claude/state を汚していないことの確認 (HOME=$HOME) ---"
find "${HOME}/.claude/state" -mindepth 1 | sed "s|^${HOME}|\$HOME|" | sort

echo
echo "==================== ${PASS} passed / ${FAIL} failed ===================="
[ "$FAIL" -eq 0 ]
