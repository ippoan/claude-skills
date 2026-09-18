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
# 親の archive_session がアプリに「was not archived: …」で拒否された瞬間に、
# task-split §6 の次の一手を機械的に出す。読了チェックは不読を防ぐだけで、
# **拒否された瞬間に何をするか**は毎回その場で要る。
#
# ★★ **検出**の一致条件は「was not archived」だけ (理由を問わない) — Refs ippoan/claude-skills#167。
#   「pinned or in use」にしか鳴らなかったため、2026-09-10 に「it still has live work
#   (an agent run, a Remote Control client, a queued message or a background task)」の
#   拒否で黙り、親が「ユーザー操作待ち」で 1 時間止まった。文言が増えるたびに**検出**条件を
#   追加する設計は同じ穴を繰り返すので、理由を問わず「was not archived」だけで拾う。
#
# ★★★ **remedy (次の一手) だけは文言で分ける** — 2026-09-18 追加。
#   #167 で「文言を問わない」にしたのは**検出**の話で、**正解の手順は文言ごとに違う**。
#   同じ手順を全文言に流したため、待っても消えない条件にリトライと [決定] 中継を撃ち続け、
#   9/10〜9/18 で 14 対象・計 34 回の拒否を積んだ (~/.claude/state/archive-refused/ の実測)。
#   上流の実装は 4 分岐 (`running` / `losable_work` / `pinned` / `on_screen`) を計算している
#   のに、文言が 2 種に潰れているのが原因 — いずれも open・未修正:
#     - anthropics/claude-code#93259 「pinned or in use」= `pinned` か `on_screen`。
#       **`pinned` は待っても永久に消えない** (unpin が必要)。`set_pinned` の説明は
#       「自動 archive を防ぐ」だが実際は明示的な `archive_session` も塞ぐ。
#       **`on_screen` は `!r` (r = 対象が呼び出し元) で guard されており self では発火しない**
#       ⇒ 対象が self でこの文言なら**原因は `pinned` で確定**。
#     - anthropics/claude-code#93269 「live work」の 4 原因のうち Remote Control client と
#       queued message はセッションから観測できない (だから「ユーザー側が掴んでいる」と誤結論する)。
#     - anthropics/claude-code#93270 **Workflow / agent を mid-run で TaskStop すると
#       agent run が terminal record 無しで残り、そのセッションは生涯 archive 不可になる**
#       (`ps` は空、`TaskStop` は "No task found" を返すのに hold だけ残る)。
#       この leak には再試行も子の self-archive も効かない — **サイドバーからの archive だけ**。
#   ⇒ 分岐は 3 つ。**知らない文言は今までどおりの手順に落ちる** (#167 の穴を開け直さない)。
#     app_hold (pinned or in use) → **先に unpin**。待たない・中継しない
#     live_work                  → 子へ何も送らず 1 回。中継は 2 通で打ち止め、そこから先は leak 扱い
#     unknown                    → 従来どおり (1 回再試行 → [決定] 中継)
#
# ★★ 2 回目以降は「[決定] に何を書くべきか」の指示ではなく、[決定] の**完成形**を
#   そのまま出す (Refs #167)。旧版は箇条書きの要件だけを示し、本文の組み立てを親に
#   残していた — その「組み立てる判断」自体が「ユーザーの判断が要ります」に流れる隙だった
#   (2026-09-10、#p135 第 5 世代の実害)。今回は hook の stdin (PostToolUseFailure の
#   payload) から取れるものを全部埋め、親が埋める空欄は PR 番号 1 か所だけ。
#
# ユーザーの原文の置き方 (★ ここが空だと [決定] は「送らない」を出す):
#   ~/.claude/state/archive-refused/user-quotes.txt に、親が「ユーザーが archive について
#   この案件で打った言葉」を 1 行ずつ、行頭に日付を付けて追記する。
#     例: 2026-09-10 さっさとたため
#         2026-09-10 いつまでもおなじことやってる もう２０回くらいやってる なおせ
#   要約しない・複数行にまたがる発言も 1 行にまとめて貼る。このファイルが無い/空のときは
#   [決定] の本文自体が「原文が無い → 送らない」になる (見出しだけの [決定] を作らせない
#   — Refs #160)。
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

# 「アプリが抱えている」拒否だけを拾う。理由の文言は問わない (★ Refs #167)。
# 成功・archive_session 以外のエラーは素通し。
case "$resp" in
  *"was not archived"*) : ;;
  *) exit 0 ;;
esac

sid=$(printf '%s' "$payload" | jq -r '.session_id // "unknown"' 2>/dev/null || echo unknown)
target=$(printf '%s' "$payload" | jq -r '.tool_input.session_id // "unknown"' 2>/dev/null || echo unknown)

# 拒否文言の原文を抽出する (tool_response が文字列 / content block 配列 / error / tool_error
# のどれでも拾う)。取れなければ resp から拾い、それも空なら resp をそのまま出す。
raw_text=$(printf '%s' "$payload" | jq -r '
  ( .tool_response? // .error? // .tool_error? ) as $r
  | if ($r|type)=="string" then $r
    elif ($r|type)=="array" then ($r | map(.text? // .content? // empty) | map(select(.!=null)) | join(" "))
    elif ($r|type)=="object" then ($r.text? // $r.message? // ($r|tostring))
    else empty end
' 2>/dev/null)
[ -n "$raw_text" ] || raw_text=$(printf '%s' "$resp" | grep -o 'was not archived[^"]*' | head -1)
[ -n "$raw_text" ] || raw_text="$resp"

# --- remedy の分岐 (★ 検出は上で済んでいる。ここは「次の一手」だけを分ける) -------------
case "$raw_text" in
  *"pinned or in use"*)    hold=app_hold ;;
  *"still has live work"*) hold=live_work ;;
  *)                       hold=unknown ;;
esac

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

sent=0
[ -f "$state_dir/sent-$safe" ] && sent=$(cat "$state_dir/sent-$safe" 2>/dev/null || echo 0)
case "$sent" in ''|*[!0-9]*) sent=0 ;; esac

# ---------------------------------------------------------------------------
# 対象が self — 親へ送る話でも、誰かに代行を頼む話でもない
# ---------------------------------------------------------------------------
if [ "$target" = "self" ]; then
  {
    case "$hold" in
      app_hold)
        echo "⚠ [archive] 自分の archive が「pinned or in use」で拒否されました (${n} 回目)。"
        echo "  拒否文言: $raw_text"
        echo "  ★ **原因は pinned で確定**。\`on_screen\` は self では発火しません"
        echo "  (upstream の !r guard。r = 対象が呼び出し元 — anthropics/claude-code#93259)。"
        echo "  **待っても消えません。タブを閉じてもらっても消えません。**"
        if [ "$n" -le 1 ]; then
          echo "  次の一手 (ユーザーに聞かない):"
          echo "    1. ToolSearch: select:mcp__ccd_session_mgmt__get_session,mcp__ccd_sidebar__set_pinned"
          echo "    2. get_session { session_id: \"self\" } で pinned を確かめる"
          echo "    3. pinned: true なら set_pinned で false にして、もう一度 archive_session を打つ"
          echo "    4. pinned: false だったときだけ下の 1 行をユーザーへ伝えて turn を終える"
        else
          echo "  unpin しても通らなかった ⇒ ここから先はアプリ側でしか外せません。"
        fi
        echo "  ユーザーへ 1 行: 『サイドバーから archive してください (pin 中は archive_session が"
        echo "  通りません)』。待たない・再試行を続けない。"
        ;;
      live_work)
        echo "⚠ [archive] 自分の archive が「live work」で拒否されました (${n} 回目)。"
        echo "  拒否文言: $raw_text"
        echo "  4 原因のうち **Remote Control client と queued message はこちらから観測できません**"
        echo "  (anthropics/claude-code#93269)。「ユーザー側が掴んでいる」と決めつけないこと。"
        if [ "$n" -le 1 ]; then
          echo "  次の一手: 自分の背景タスクを先に畳む — Monitor / run_in_background の Bash /"
          echo "  Agent の走行を止め (TaskStop)、止まってから **1 回だけ** 打ち直す。"
          echo "  ★ ただし **Workflow / agent を mid-run で TaskStop した覚えがあるなら再試行しない** —"
          echo "  その agent run は terminal record 無しで残り、このセッションは生涯 archive 不可です"
          echo "  (anthropics/claude-code#93270。ps は空・TaskStop は \"No task found\" を返すのに hold は残る)。"
        else
          echo "  2 回目 ⇒ **#93270 の leak と見なす**。再試行しない (生涯消えません)。"
          echo "  ユーザーへ 1 行: 『サイドバーから archive してください』。これが唯一の復帰手段です。"
        fi
        ;;
      *)
        echo "⚠ [archive] 自分の archive がアプリに拒否されました (${n} 回目)。"
        echo "  拒否文言: $raw_text"
        echo "  再試行しない。ユーザーに 1 行で『サイドバーから archive するか、タブを閉じてから"
        echo "  もう一度「畳んで」と打ってください』と伝えて、この turn を終える。"
        ;;
    esac
    echo "  親へ送る話でも、誰かに代行を頼む話でもない。"
  } >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# 対象が子
# ---------------------------------------------------------------------------

# ★ 送るまで口を塞ぐ (Refs ippoan/alc-app-s3#135): 文面を返すだけ (exit 2 の advisory) だと、
#   親は「子も拒否されたのだから送っても無駄」と自分で判断して送らなかった (2026-09-10、
#   #p135 第 10 世代)。[決定] を送るべき回だけ宛先の子を pending に書き、
#   require-archive-decision-sent.sh (PreToolUse 全ツール) が正しい send_message 以外を deny する。
#   - 原文が無い回は書かない — 本文が「送らない」なのに口を塞ぐと、親は user-quotes.txt に
#     原文を足すことすらできず詰む
#   - その子へ 2 通送った後は書かない — task-split §6「3 通目は送らない」。書き続けると
#     親が turn ごとに archive を再試行するたびに [決定] を送らされる
#     (送信数 sent-<sid>-<対象> は require-archive-decision-sent.sh が数える)
#   - ★ 中継が正解でない回 (app_hold の unpin 前 / live_work の leak 確定後) は書かない —
#     2026-09-18。塞いだまま空振りさせると親が unpin もサイドバー誘導もできない
relay() {
  quotes_file="$state_dir/user-quotes.txt"
  if [ -s "$quotes_file" ]; then
    quotes_block=$(cat "$quotes_file" 2>/dev/null)
    quotes_ok=yes
  else
    quotes_block=""
    quotes_ok=no
  fi

  if [ "$quotes_ok" = yes ] && [ "$sent" -lt 2 ] && [ "$sid" != unknown ] && [ "$target" != unknown ]; then
    printf '%s\n' "$target" > "$state_dir/pending-$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')" 2>/dev/null || true
  fi

  skill_file="$HOME/.claude/skills/report-to-parent/SKILL.md"
  exception_text=""
  if [ -f "$skill_file" ]; then
    exception_text=$(sed -n '/^- (b)/,/断られない中継/p' "$skill_file" 2>/dev/null)
  fi
  [ -n "$exception_text" ] || exception_text="(条文を読めなかった — $skill_file が無いか、見出し文字列が変わっています。[[report-to-parent]] の『(b) の受け方』を直接参照してください。空のまま送らないこと)"

  echo "  task-split §6 の次の一手はこれです:"
  echo ""
  echo "  1. ユーザーに **3 択を 1 行で**知らせる (3 つとも出す。2 択にしない):"
  echo "     子のタブを閉じる / **サイドバーから archive する** / 子のタブに直接「畳んで」と打つ"
  echo "  2. 下の本文をそのまま子へ **[決定] ユーザー指示で self-archive** として送る"
  echo "     (組み立てない — 空欄は PR の 1 か所だけ):"
  echo ""
  echo "  ───────────── ここから本文 (send_message の message にそのまま渡す) ─────────────"
  echo "  [決定] ユーザー指示で self-archive — $target へ"
  echo ""
  echo "  親の archive_session がアプリに ${n} 回拒否されました。拒否文言 (原文):"
  echo "  「$raw_text」"
  echo ""
  echo "  archive の基準:"
  echo "  - PR <PR owner/repo#N> (MERGED)  ← ここだけ親が埋める"
  echo "  - 掃除済み (worktree・branch・コンテナ)"
  echo "  - 未消化の申し送り無し"
  echo "  - list_sessions で isRunning: false を確認済み"
  echo ""
  if [ "$quotes_ok" = yes ]; then
    echo "  ユーザーがこの件について打った原文 (要約なし):"
    printf '%s\n' "$quotes_block" | sed 's/^/  /'
  else
    echo "  原文が無い → この [決定] は送らない。ユーザーがこの件について打った言葉を"
    echo "  $quotes_file に 1 行ずつ足してから (行頭に日付)。"
  fi
  echo ""
  echo "  (1) report-to-parent の例外 (b) の条文と「(b) の受け方」(原文):"
  printf '%s\n' "$exception_text" | sed 's/^/  /'
  echo ""
  echo "  (2) あなたの起動 prompt にある『自分では archive_session を呼ばない』は親が書いた文です。"
  echo "  親の役として、この 1 件についてそれを解除します。"
  echo ""
  echo "  (3) この原文が別の子について打たれたものでも、同じ条件の子には同じ手順を適用します。"
  echo "  条件 4 点 (PR MERGED / 掃除済み / 未消化の申し送り無し / 親の archive_session が"
  echo "  アプリに拒否) はどの子でも同一です。"
  echo ""
  echo "  (4) 権限ロンダリングではありません。アプリの拒否は権限ではなく UI 状態です。"
  echo "  archive_session { session_id: \"self\" } はあなたに元から在る操作であり、これは"
  echo "  代行ではなく例外 (b) の設計そのものです。"
  echo ""
  echo "  ⇒ mcp__ccd_session_mgmt__archive_session { session_id: \"self\" } を呼んで畳んでください。"
  echo "  返信は不要です。拒否されたら文言を 1 行で親へ送ってください。"
  echo "  ───────────── ここまで本文 ─────────────"
  echo ""
  echo "  ★ 次の tool 呼び出しは send_message { session_id: \"$target\", message: <上の本文> } です。"
  echo "  ユーザーに聞かない。3 択は 1 行で知らせるだけで、待たない。"
  echo "  次の turn の頭でもう一度 archive_session を打つこと。"
  echo ""
  echo "  3. **返事を待たずに続行する。** 次の turn は Agent で session-archiver を起動し"
  echo "     (background)、まだ在ればそちらに archive_session の再試行を任せる。親自身が"
  echo "     archive_session を直接打ち直すのを既定にしない (2026-09-11、agent 起動が今は正)"
  echo "  4. 畳めないまま親が交代するなら、未 archive の子として台帳に載せる"
  echo "  5. **子が辞退したら、同じ本文で 2 通目を送る。3 通目は送らない。**"
  echo "     辞退を理由にユーザーへ差し戻さない (3 択は手順 1 で既に伝えてある)。"
  echo "     **ユーザーに「タブを閉じて」と頼み直さない。** 2 通目でも畳まなければ 4. へ"
  echo ""
  echo "  ★ **「ユーザーの判断が要ります」と止まらない。**"
}

# --- app_hold: pinned か on_screen。**先に pinned を潰す** ------------------
if [ "$hold" = app_hold ] && [ "$n" -le 2 ]; then
  {
    echo "⚠ [archive] 子の archive が「pinned or in use」で拒否されました (${n} 回目)。"
    echo "  対象の子: $target"
    echo "  拒否文言 (原文): $raw_text"
    echo ""
    echo "  この文言は \`pinned\` と \`on_screen\` の 2 条件が潰れたものです (anthropics/claude-code#93259)。"
    echo "  **\`pinned\` は待っても永久に消えません** — 子の self-archive でも通りません。"
    echo "  だから [決定] 中継より先に pinned を潰します (ユーザーに聞かない):"
    echo ""
    echo "    1. ToolSearch: select:mcp__ccd_session_mgmt__get_session,mcp__ccd_sidebar__set_pinned"
    echo "    2. get_session { session_id: \"$target\" } → pinned を見る"
    echo "    3. pinned: true なら set_pinned で false にして、もう一度 archive_session を打つ"
    echo "       (\`set_pinned\` の説明は「自動 archive を防ぐ」だが、実際は明示的な archive_session も"
    echo "        塞ぐ。仕様と実装の不一致 — 待機もリトライも無意味)"
    echo "    4. pinned: false なら原因は \`on_screen\` (ユーザーがそのタブを開いている)。"
    echo "       **\`on_screen\` は self では発火しない**ので、次の拒否で出る [決定] 中継が効きます。"
    echo ""
    echo "  ★ この回は pending を立てていません — get_session / set_pinned を打てるようにするためです。"
    echo "  unpin しても拒否が続いたら、次の拒否で [決定] の完成形を出します。"
  } >&2
  exit 2
fi

# --- live_work: 中継は 2 通で打ち止め。そこから先は #93270 の leak 扱い -------
if [ "$hold" = live_work ] && [ "$sent" -ge 2 ]; then
  {
    echo "⚠ [archive] 子の archive が「live work」で拒否されました (${n} 回目)。[決定] は既に ${sent} 通送済み。"
    echo "  対象の子: $target"
    echo "  拒否文言 (原文): $raw_text"
    echo ""
    echo "  ⇒ **anthropics/claude-code#93270 の leak と見なす。**"
    echo "  Workflow / agent を mid-run で TaskStop すると agent run が terminal record 無しで残り、"
    echo "  そのセッションは**生涯 archive 不可**になります。判別は 1 コマンド:"
    echo "  list_sessions で isRunning: false かつ TaskStop が \"No task found\" を返すなら leak 確定。"
    echo ""
    echo "  この状態では **再試行も子の self-archive も通りません** (hold は子の registry 側にある)。"
    echo "  **子へはもう何も送らない** — queued message 自体が live work の 4 原因の 1 つです。"
    echo ""
    echo "  1. ユーザーへ 1 行: 『$target はアプリ側の agent run leak (#93270) で archive_session が"
    echo "     通りません。**サイドバーから archive してください**』 — 両 issue で確認された唯一の復帰手段。"
    echo "  2. 待たずに続行し、未 archive の子として台帳に載せる。"
    echo "  3. **3 通目の [決定] は送らない。**「ユーザーの判断が要ります」と止まらない。"
    echo ""
    echo "  ★ 予防: archive する予定のセッションで **mid-run の TaskStop をしない** (完走を待つ)。"
    echo "  これが永久ブロックの唯一の作り方です。"
  } >&2
  exit 2
fi

if [ "$n" -le 1 ]; then
  {
    echo "⚠ [archive] アプリが子の archive を拒否しました — 1 回目。"
    echo "  拒否文言: $raw_text"
    echo "  task-split §6: **親の再試行は 1 回まで**。もう一度だけ archive_session を打ってよい。"
    echo "  対象: $target"
    if [ "$hold" = live_work ]; then
      echo "  ★ **打ち直す前に子へ何も送らない** — send_message は queued message になり、"
      echo "  それ自体が live work の 4 原因の 1 つです (子のターンも起きる)。"
      echo "  ★ 直前に Workflow / agent を mid-run で TaskStop したなら、再試行は 1 回で打ち切る —"
      echo "  #93270 の leak なら生涯消えず、サイドバーからの archive だけが効きます。"
    fi
  } >&2
  exit 2
fi

# --- 2 回目以降 (unknown / app_hold の unpin 後 / live_work の中継 1〜2 通目) ---
{
  echo "⚠ [archive] アプリが子の archive を拒否しました — ${n} 回目。**この turn ではもう再試行しないこと。**"
  echo "  対象の子: $target"
  echo "  拒否文言 (原文): $raw_text"
  echo ""
  relay
} >&2
exit 2
