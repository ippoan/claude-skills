#!/bin/bash
# PostToolUse / matcher: mcp__ccd_session_mgmt__archive_session
#
# 親の archive_session がアプリに「was not archived: the app is keeping it for the user
# (pinned or in use)」で拒否された瞬間に、task-split §6 の次の一手を機械的に出す。
# 読了チェックは不読を防ぐだけで、**拒否された瞬間に何をするか**は毎回その場で要る。
#
# Why (2026-09-09、Refs ippoan/claude-skills#160): 拒否を受けた親が
#   - 「ユーザーの判断が要ります」と止まる
#   - 3 択のうち「サイドバーから archive」を落として 2 択にする
#   - 子へ send_message で「[決定] ユーザー指示で self-archive」を送る (廃止済みの中継。
#     子は tool 契約と harness の警告を理由に 3 連続で断り、そのたび三者で同じ問答になった)
#   のどれかをやった。hook は「1 回目 = 再試行 1 回まで」「2 回目以降 = 3 択を 1 行で
#   知らせて待たずに続行」を出し、中継の経路は出さない (send_message 側は
#   block-archive-relay.sh が deny する)。
#
# 判定の鍵は session_id と tool_input.session_id の組 (証跡: ~/.claude/state/archive-refused/)。
# fail-open: jq が無い / payload が読めない / 拒否文言でない → 黙って素通し。
#
# ★ hook は**設置したセッションでは効かない** (settings watcher は session 開始時の設定しか
#   見ない。2026-09-09 実測)。設置後は新しいセッションで確かめること。

set -u
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

resp=$(printf '%s' "$payload" | jq -r '(.tool_response // empty) | if type=="string" then . else tojson end' 2>/dev/null || true)
[ -n "$resp" ] || exit 0

# 「アプリが抱えている」拒否だけを拾う。成功・他のエラーは素通し
case "$resp" in
  *"was not archived"*) : ;;
  *) exit 0 ;;
esac
case "$resp" in
  *"pinned or in use"*|*"keeping it for the user"*) : ;;
  *) exit 0 ;;
esac

sid=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
target=$(printf '%s' "$payload" | jq -r '.tool_input.session_id // "unknown"' 2>/dev/null || echo unknown)

# 自分を畳もうとして拒否された = ユーザーがこのタブを開いている。再試行しても同じ
if [ "$target" = "self" ]; then
  {
    echo "⚠ [archive] 自分の archive がアプリに拒否されました (pinned or in use = ユーザーがこのタブを開いている)。"
    echo "  再試行しない。ユーザーに 1 行で『サイドバーから archive するか、タブを閉じてから"
    echo "  もう一度「畳んで」と打ってください』と伝えて、この turn を終える。"
    echo "  親へ送る話でも、誰かに代行を頼む話でもない。"
  } >&2
  exit 2
fi

state_dir="$HOME/.claude/state/archive-refused"
mkdir -p "$state_dir" 2>/dev/null || true
safe=$(printf '%s-%s' "$sid" "$target" | tr -c 'A-Za-z0-9._-' '_')
counter="$state_dir/$safe"
n=0
[ -f "$counter" ] && n=$(cat "$counter" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
printf '%s' "$n" > "$counter" 2>/dev/null || true

# 7 日より古い証跡は掃く
find "$state_dir" -type f -mtime +7 -delete 2>/dev/null || true

if [ "$n" -le 1 ]; then
  {
    echo "⚠ [archive] アプリが子の archive を拒否しました (pinned or in use) — 1 回目。"
    echo "  task-split §6: **親の再試行は 1 回まで**。もう一度だけ archive_session を打ってよい。"
    echo "  対象: $target"
  } >&2
  exit 2
fi

{
  echo "⚠ [archive] アプリが子の archive を拒否しました — ${n} 回目。**この turn ではもう再試行しないこと。**"
  echo "  対象の子: $target"
  echo ""
  echo "  task-split §6 の次の一手はこれです:"
  echo ""
  echo "  1. ユーザーに **3 択を 1 行で**知らせる (3 つとも出す。2 択にしない):"
  echo "     子のタブを閉じる / **サイドバーから archive する** / 子のタブに直接「畳んで」と打つ"
  echo "  2. **返事を待たずに続行する。** 次の turn の頭で list_sessions を見て、まだ在れば"
  echo "     もう一度 archive_session を打つ (また拒否されたら 1 行だけ繰り返す)"
  echo "  3. 畳めないまま親が交代するなら、未 archive の子として台帳に載せる"
  echo ""
  echo "  ★ **子へ send_message で「[決定] ユーザー指示で self-archive」を送らない** (中継は廃止。"
  echo "     子は伝聞で archive_session を呼べない — tool 契約と harness の警告で 3 連続で断られた。"
  echo "     Refs ippoan/claude-skills#160)。**「ユーザーの判断が要ります」と止まらない。**"
} >&2
exit 2
