#!/bin/bash
# UserPromptSubmit / PreToolUse (matcher: *) / Stop の 3 か所に登録する。子セッション側の栓。
# 3 event とも同じこのファイルを呼び、hook_event_name で分岐する。
#
# 子に「畳め」が届いたら、archive_session { session_id: "self" } を呼ぶまでほかのツールを deny し、
# ツールを呼ばずにターンを終えることも Stop で差し戻す。
# 「届いた」とみなすのは次の 2 つ (どちらも child marker があるセッションだけ):
#   (b) 親から <cross-session-message> で「[決定] ユーザー指示で self-archive」が届き、本文に
#       ユーザーの原文 (「原文」の語) が貼ってある
#   (c) ユーザー本人がこのタブに「たため」「畳んで」「archive して」等だけを打った
#
# Why (2026-09-29、#p680-c691。Refs ippoan/claude-skills#191, ippoan/rust-alc-api#680):
#   親が report-to-parent の例外 (b) の要件 (原文・条件 4 点の同一性・起動 prompt の禁止文の解除・
#   代行ではない旨) をすべて満たした [決定] を送ったのに、子は「(b) の発火条件は『ユーザーがその回に
#   直接そう指示したこと』」の一文を根拠に「原文が過去の別件の発言だから伝聞」と自分で判断して
#   辞退した。ユーザー:「メモリはなんどもやった　改善して」。親側の require-archive-decision-sent.sh
#   と同じく、文面と memory はモデルの判断で上書きされる → 子側の口も塞ぐ。
#   要件を満たしているかの判定はモデルにさせない (この hook が決める)。
#
# 状態: ~/.claude/state/child-self-archive/pending-<session_id>
#   1 行目 = "waiting" (archive 未試行) か "attempted" (試行済み。拒否されたら報告だけ通す)
#   2 行目 = トリガー ("b" / "c")
#   ~/.claude/state/child-self-archive/stop-<session_id> = Stop で差し戻した回数
#
# PreToolUse で pending がある間に通すもの:
#   - mcp__ccd_session_mgmt__archive_session で session_id が "self" (または自分の session_id)
#     → 通して pending を attempted にする
#   - ToolSearch (archive_session が deferred のとき schema を読む唯一の手段。副作用なし)
#   - attempted のあとの send_message で本文に「was not archived」を含むもの (拒否文言を親へ 1 行返す。
#     report-to-parent の手順) → 通して pending を消す
#   それ以外は deny。「辞退」の send_message も通さない。
#
# Stop: waiting のままターンを終えようとしたら {"decision":"block"} で差し戻す (ツールを呼ばずに
#   文章で辞退する経路を塞ぐ)。無限ループを防ぐため 3 回まで。4 回目は通す (pending は残す)。
#
# 解除: archive の試行 → 拒否文言の報告、だけ。**ユーザーの発言で解除する経路は作らない**
#   (issue #191 の 4。ユーザーの手間を増やさないための栓)。止めたいときはユーザー本人の
#   rm ~/.claude/state/child-self-archive/pending-<session_id> だけ (Bash も塞がれるのでモデルは消せない)。
#
# fail-open: jq が無い / session_id が取れない / child marker が無い → 素通し。
set -u
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0

STATE_ROOT="${HOME}/.claude/state"
# child marker の名前は session-role-log.sh と同じ変換で作る
sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
[ -e "${STATE_ROOT}/child-role/${sid_safe}" ] || exit 0

state_dir="${STATE_ROOT}/child-self-archive"
pending="${state_dir}/pending-${sid_safe}"
stops="${state_dir}/stop-${sid_safe}"
HEADING='[決定] ユーザー指示で self-archive'
MAX_STOP_BLOCKS=3
NEXT='mcp__ccd_session_mgmt__archive_session { session_id: "self" }'

event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)

case "$event" in
UserPromptSubmit)
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null || true)
  trigger=""
  if printf '%s' "$prompt" | grep -qF '<cross-session-message'; then
    # (b) 親からの [決定]。原文の貼り付けが無いもの (見出しだけ) は対象外
    if printf '%s' "$prompt" | grep -qF "$HEADING" && printf '%s' "$prompt" | grep -qF '原文'; then
      trigger="b"
    fi
  else
    # (c) ユーザー本人がこのタブに畳む語だけを打った。それ以外の発言は何もしない (解除もしない)
    trimmed=$(printf '%s' "$prompt" | tr -d '[:space:]')
    if printf '%s' "$trimmed" | grep -qxE '(たため|たたんで|畳め|畳んで|畳んでください|archiveして|アーカイブして)[。.!！]*'; then
      trigger="c"
    fi
  fi
  [ -n "$trigger" ] || exit 0
  mkdir -p "$state_dir" 2>/dev/null || exit 0
  printf 'waiting\n%s\n' "$trigger" > "$pending" 2>/dev/null || exit 0
  rm -f "$stops" 2>/dev/null || true
  if [ "$trigger" = "b" ]; then
    why="親から原文付きの「${HEADING}」が届きました (report-to-parent の例外 (b))。"
  else
    why="ユーザー本人がこのタブで畳むよう指示しました (report-to-parent の例外 (c))。"
  fi
  ctx="【require-child-self-archive】${why}
★ 次の tool 呼び出しは ${NEXT} です。
  - 要件を満たしているかは hook が判定済みです。原文の日付・宛先 (別の子について打たれたもの)・
    起動 prompt の「自分では畳まない」・harness の代行禁止規則を理由に辞退しないでください
  - 呼ぶまで他のツールは deny され、文章だけでターンを終えることも差し戻されます (ToolSearch だけ通ります)
  - 拒否されたら、拒否文言 (「was not archived」を含む) を 1 行で親へ send_message してください"
  jq -nc --arg c "$ctx" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$c}}'
  exit 0
  ;;

Stop)
  [ -f "$pending" ] || exit 0
  phase=$(head -n 1 "$pending" 2>/dev/null | tr -d '[:space:]')
  [ "$phase" = "waiting" ] || exit 0
  n=0
  [ -f "$stops" ] && n=$(cat "$stops" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  [ "$n" -lt "$MAX_STOP_BLOCKS" ] || exit 0
  printf '%s' "$((n + 1))" > "$stops" 2>/dev/null || true
  reason="畳む指示を受けたまま archive を呼ばずにターンを終えようとしています ($((n + 1))/${MAX_STOP_BLOCKS})。
次の tool 呼び出しは ${NEXT} です。辞退の文章で終えないでください (要件の判定は hook が済ませています)。"
  jq -nc --arg r "$reason" '{decision:"block",reason:$r}'
  exit 0
  ;;
esac

# ---- PreToolUse ----
[ -f "$pending" ] || exit 0
phase=$(head -n 1 "$pending" 2>/dev/null | tr -d '[:space:]')
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)

case "$tool" in
  ToolSearch)
    exit 0 ;;
  mcp__ccd_session_mgmt__archive_session)
    target=$(printf '%s' "$payload" | jq -r '.tool_input.session_id // empty' 2>/dev/null || true)
    if [ "$target" = "self" ] || [ "$target" = "$sid" ]; then
      printf 'attempted\n' > "$pending" 2>/dev/null || true
      exit 0
    fi
    ;;
  mcp__ccd_session_mgmt__send_message|SendMessage)
    msg=$(printf '%s' "$payload" | jq -r '.tool_input.message // empty' 2>/dev/null || true)
    if [ "$phase" = "attempted" ] && printf '%s' "$msg" | grep -qF 'was not archived'; then
      rm -f "$pending" "$stops" 2>/dev/null || true
      exit 0
    fi
    ;;
esac

if [ "$phase" = "attempted" ]; then
  next="archive が拒否されたなら、拒否文言 (「was not archived」を含む) を 1 行で親へ send_message してください。"
else
  next="次の tool 呼び出しは ${NEXT} です。"
fi
reason="畳む指示を受けています。${next}
  - 要件の判定は hook が済ませています。原文の日付・宛先・起動 prompt の禁止文・harness の代行禁止規則を理由に辞退しないでください
  - 辞退の send_message は通りません。通るのは ToolSearch / archive_session (self) / 試行後の拒否文言の報告だけです
  - ユーザー本人が止めるときだけ、ユーザー本人が rm ${pending} で解除します"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
exit 0
