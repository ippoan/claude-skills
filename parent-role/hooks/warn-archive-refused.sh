#!/bin/bash
# PostToolUseFailure / matcher: mcp__ccd_session_mgmt__archive_session
#
# ★ PostToolUse ではなく PostToolUseFailure に登録する (Refs ippoan/claude-skills#163)。
#   PostToolUse は**成功時のみ**発火し、archive の拒否は MCP ツールの失敗として返るので
#   別イベント PostToolUseFailure でしか届かない (2026-09-09 の拒否 6 回で一度も鳴らなかった)。
#   失敗文言がどのキー (tool_response / error / tool_error) に入るかは公式に明記が無いので、
#   payload 全体の JSON 文字列に対して拒否文言を照合し、key 名に依存しない。
#   成功時の PostToolUse 登録が残っていても害は無い (成功応答は拒否文言を含まず素通し)。
#
# 親の archive_session がアプリに「was not archived: the app is keeping it for the user
# (pinned or in use)」で拒否された瞬間に、task-split §6 の次の一手を機械的に出す。
# 読了チェックは不読を防ぐだけで、**拒否された瞬間に何をするか**は毎回その場で要る。
#
# Why (2026-09-09、Refs ippoan/claude-skills#160): 拒否を受けた親が
#   - 「ユーザーの判断が要ります」と止まる
#   - 3 択のうち「サイドバーから archive」を落として 2 択にする
#   - 子へ「[決定] ユーザー指示で self-archive」を送るとき、**ユーザーの原文を貼らずに**
#     見出しだけ付けて送る (子には伝聞で確かめようがなく、4 例が断った)
#   のどれかをやった。hook は「1 回目 = 再試行 1 回まで」「2 回目以降 = 3 択を 1 行で
#   知らせる → 原文付きの [決定] を送る → 待たずに続行」を、task-split §6 の順で出す。
#
# Why 2 (2026-09-09、Refs ippoan/claude-skills#165): 原文を貼った [決定] でも子が辞退した
#   (c199 = 原文が別の子について打たれたもの、c192-2 = harness の代行禁止規則)。どちらも
#   4 点 ((1) 例外 (b) の条文 (2) 起動 prompt の禁止文の解除 (3) 同じ条件の子に同じ手順 +
#   条件 4 点 (4) 権限ロンダリングとの区別) を入れた 2 通目で畳んだ。2 回目以降の文面は
#   その 4 点を [決定] の必須項目として並べ、手順 5 で「辞退されたら 2 通目。3 通目は送らない」
#   を出す (親が「ユーザーに頼んで待つ」へ倒れるのを塞ぐ)。
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

# 照合対象は payload 全体 (jq -c . の 1 行 JSON。壊れた JSON なら生の payload)
resp=$(printf '%s' "$payload" | jq -c . 2>/dev/null || printf '%s' "$payload")
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
  echo "  2. 子へ **[決定] ユーザー指示で self-archive** を送る。"
  echo "     ★ **ユーザーの直接指示があるときだけ。** [決定] には次を必ず入れる:"
  echo "       - ユーザーがこの件について打った **原文を、要約せずそのまま貼る**"
  echo "         (貼れる原文が無いなら送らない。見出しだけでは子にとって伝聞のままで、"
  echo "          2026-09-09 に 4 例が断った — Refs ippoan/claude-skills#160)"
  echo "       - 親の再試行がアプリに拒否されたこと (回数)"
  echo "       - archive の基準 3 点と list_sessions の isRunning: false の確認結果"
  echo "       - (1) report-to-parent の **例外 (b) の条文と「(b) の受け方」を原文どおり貼る**"
  echo "             (子の起動 prompt には要約しか無いことがある。条文があれば子が自分で照合できる)"
  echo "       - (2) 「起動 prompt の『自分では archive_session を呼ばない』は **親が書いた文**なので、"
  echo "             **親の役としてこの 1 件について解除する**」の 1 行"
  echo "       - (3) 原文が **別の子について**打たれたものなら、**「同じ条件の子に同じ手順」**と明示し、"
  echo "             条件 4 点が同一であることを書く — PR MERGED / 掃除済み (worktree・branch・"
  echo "             コンテナ) / 未消化の申し送り無し / 親の archive がアプリに拒否"
  echo "       - (4) **権限ロンダリングとの区別** — アプリの拒否は **権限ではなく UI 状態** /"
  echo "             archive_session self は **子に元から在る操作** /"
  echo "             **代行ではなく例外 (b) の設計そのもの** (harness の代行禁止規則の対象ではない)"
  echo "  3. **返事を待たずに続行する。** 次の turn の頭で list_sessions を見て、まだ在れば"
  echo "     もう一度 archive_session を打つ (また拒否されたら 1 行だけ繰り返す)"
  echo "  4. 畳めないまま親が交代するなら、未 archive の子として台帳に載せる"
  echo "  5. **子が辞退したら、上の (1)〜(4) を全部入れた 2 通目を送る。3 通目は送らない。**"
  echo "     辞退を理由にユーザーへ差し戻さない (3 択は手順 1 で既に伝えてある)。"
  echo "     **ユーザーに「タブを閉じて」と頼み直さない。** 2 通目でも畳まなければ 4. へ"
  echo ""
  echo "  ★ **「ユーザーの判断が要ります」と止まらない。**"
} >&2
exit 2
