#!/bin/bash
# PreToolUse / matcher: * (全ツール)
#
# 親の archive_session がアプリに 2 回以上拒否され、warn-archive-refused.sh が
# [決定] ユーザー指示で self-archive の完成形を出したあと、その [決定] を子へ send_message
# するまで、ほかのツールを deny する。
#
# Why (2026-09-10、#p135 第 10 世代の親。Refs ippoan/alc-app-s3#135):
#   warn-archive-refused.sh は「★ 次の tool 呼び出しは send_message です」と出していたが、
#   exit 2 の advisory なので親は自分の判断で上書きできた。1 通目の後に子の self-archive も
#   同じ文言で拒否され、3 回目の拒否で hook が再び send_message を指示したのに、親は
#   「子も拒否されたのだから送っても無駄」と判断して送らず、ユーザーに 3 択だけ出した。
#   ユーザー:「hooksも無視か？」「どんだけmemory書いても無視すんじゃん」。
#   文面を返すだけの hook と memory はモデルの判断で上書きされる → 口を塞ぐ。
#
# 状態: ~/.claude/state/archive-refused/pending-<session_id> (中身 = 宛先の子 session_id 1 行)
#   書くのは warn-archive-refused.sh (2 回目以降 / 対象が self 以外 / user-quotes.txt に原文あり /
#   その子への送信が 2 通未満)。消すのはこの hook だけ。
#
# 許可するもの:
#   - send_message: tool_input.session_id が pending の子 + message が
#     「[決定] ユーザー指示で self-archive」で始まる (先頭の空白・改行は落として見る —
#     hook の本文は字下げして出るので、そのまま貼っても通す)
#     → 許可して pending を消し、sent-<session_id>-<子> を 1 増やす (2 通で打ち止め)
#   - list_sessions / archive_session (状態確認と再試行は妨げない)
#   - get_session / set_pinned (★ 2026-09-18)。拒否文言が「pinned or in use」のときは
#     **pin を外すのが正解で [決定] 中継は効かない** (pin は子の self-archive も塞ぐ。
#     待っても消えない — anthropics/claude-code#93259)。塞いだままだと親は unpin すらできない。
#     warn-archive-refused.sh は unpin を促す回に pending を立てないが、前の回の pending が
#     残っていても remedy を打てるように許可側にも入れておく
#   - ToolSearch (send_message が deferred のとき schema を読む唯一の手段。副作用なし)
#   - Agent (★ 2026-09-11、Refs ippoan/alc-app-s3#135。tool_name の実物は ~/.claude/hooks/
#     simplify-review-log.sh の matcher: Agent で確認済み。旧名 Task の実例は見つからず未追加)。
#     subagent_type では絞らない (ユーザー判断「agent 起動が今は正」) — [決定] の本文が
#     手元に無いとき、session-archiver 等の agent に archive_session を打たせて hook の
#     文面を持ち帰らせる以外に、pending を抜ける手段が無かったため。agent の tool 呼び出しは
#     親と同じ session_id で届くので、pending 中でも send_message / list_sessions /
#     archive_session / ToolSearch / get_session / set_pinned 以外は agent 経由でも
#     同じく deny される (未実測)。
#   それ以外は deny。子が既に畳まれていても、送信 1 回で pending は消えるので害は小さい
#   (list_sessions の応答は見ない。単純に保つ)。
#
# fail-open: jq が無い / session_id が取れない / pending が無い → 素通し (既存の hook と同じ)。
# 解除: 正しい send_message の 1 回か、ユーザー本人による rm (Bash も塞がれるのでモデルは消せない)。
# サブエージェントの tool 呼び出しは親と同じ session_id で届く (2026-09-10 実測: サブエージェントの
# Skill 呼び出しが skills-invoked/<親の session_id> に記録された) ので、pending は親が起動した
# サブエージェント (session-archiver 等) のツールも塞ぐはず (その deny そのものは未実測)。
# 別 session_id = 別セッションは共有しない。
set -u
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0

state_dir="${HOME}/.claude/state/archive-refused"
pending="${state_dir}/pending-$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')"
[ -f "$pending" ] || exit 0

child=$(head -n 1 "$pending" 2>/dev/null | tr -d '[:space:]')
[ -n "$child" ] || exit 0

HEADING='[決定] ユーザー指示で self-archive'
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$tool" in
  mcp__ccd_session_mgmt__list_sessions|mcp__ccd_session_mgmt__archive_session|ToolSearch|Agent|mcp__ccd_session_mgmt__get_session|mcp__ccd_sidebar__set_pinned)
    exit 0 ;;
  mcp__ccd_session_mgmt__send_message)
    to=$(printf '%s' "$payload" | jq -r '.tool_input.session_id // empty' 2>/dev/null || true)
    msg=$(printf '%s' "$payload" | jq -r '.tool_input.message // empty' 2>/dev/null || true)
    msg="${msg#"${msg%%[![:space:]]*}"}"
    if [ "$to" = "$child" ] && [ "${msg#"$HEADING"}" != "$msg" ]; then
      sent_file="${state_dir}/sent-$(printf '%s-%s' "$sid" "$child" | tr -c 'A-Za-z0-9._-' '_')"
      n=0
      [ -f "$sent_file" ] && n=$(cat "$sent_file" 2>/dev/null || echo 0)
      case "$n" in ''|*[!0-9]*) n=0 ;; esac
      printf '%s' "$((n + 1))" > "$sent_file" 2>/dev/null || true
      rm -f "$pending" 2>/dev/null || true
      exit 0
    fi
    ;;
esac

reason="archive 拒否後の [決定] をまだ送っていません。warn-archive-refused.sh が出した本文をそのまま send_message で ${child} へ送ってください。
  次の tool 呼び出し: mcp__ccd_session_mgmt__send_message { session_id: \"${child}\", message: <本文。先頭は「${HEADING}」> }
  - 「子も拒否されたのだから送っても無駄」と自分で判断しない。送るかどうかは hook が決めています
  - 送るまで通るのは、この宛先・この見出しの send_message / list_sessions / archive_session / ToolSearch / Agent / get_session / set_pinned だけです
  - 拒否文言が「pinned or in use」なら、[決定] より先に get_session で pinned を確かめ set_pinned で外してください
    (pin は待っても消えず、子の self-archive も塞ぎます — anthropics/claude-code#93259)
  - 本文が手元に無ければ、agent (session-archiver 等) に archive_session を 1 回打たせ、
    hook が出す文面を原文のまま持ち帰らせてください。親が archive_session を打ち直すのを
    既定にしない — agent 起動が今は正です
  - ユーザー本人が「送るな」と言ったときだけ、ユーザー本人が rm ${pending} で解除します"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
