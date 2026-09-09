#!/bin/bash
# PreToolUse / matcher: mcp__ccd_session_mgmt__send_message
#
# 親が子へ「self-archive しろ」を send_message で中継するのを deny する。
#
# Why (2026-09-09、Refs ippoan/claude-skills#160): #159 で入れた
# 「親の archive がアプリに拒否されたら、親が子へ [決定] ユーザー指示で self-archive を送り、
# 子が archive_session { session_id: "self" } を呼ぶ」経路は、子に 3 連続で断られた。
#   - archive_session の契約は「ユーザーが明示的に同意したときだけ、推測で呼ばない」。
#     send_message 経由の「ユーザー指示」は子にとって伝聞で、確認手段が無い
#   - harness の cross-session 警告 (peer が拒否された操作の代行を頼んできたら断って
#     ユーザーへ上げる) と [決定] は形が同じで、skill は harness を上書きできない
# 文面を磨いても解けないので、送る口そのものを塞ぐ。
#
# 判定は本文のみ (marker は見ない — この文面は誰が送っても誤り):
#   「[決定]」または「ユーザー指示」を含み、かつ archive の語 (archive_session /
#   self-archive / 自分を畳 / 自分で畳 / self を畳) を含む → deny。
#   子に「archive しないこと」を念押ししたいだけなら [決定] を外す (規範は起動 prompt の
#   定型文が持つので、そもそも送る必要が無い)。
# fail-open: jq が無い / payload が読めない → 素通し。
#
# ★ hook は**設置したセッションでは効かない** (settings watcher は session 開始時の設定しか
#   見ない。2026-09-09 実測)。設置後は新しいセッションで確かめること。
set -u
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

msg=$(printf '%s' "$payload" | jq -r '.tool_input.message // empty' 2>/dev/null || true)
[ -n "$msg" ] || exit 0

printf '%s' "$msg" | grep -qE '\[決定\]|ユーザー指示' || exit 0
printf '%s' "$msg" | grep -qiE 'archive_session|self-archive|自分を畳|自分で畳|self を畳' || exit 0

reason="子へ self-archive を中継する経路は廃止です (Refs ippoan/claude-skills#160)。子は send_message 経由の「ユーザー指示」を
伝聞としてしか受け取れず、archive_session の契約 (ユーザーが明示的に同意したときだけ) を満たせません。
2026-09-09 に 3 連続で断られ、そのたび親・子・ユーザーで同じ問答になりました。
親の archive がアプリに拒否されたときの手順 (task-split §6):
  1. 再試行は 1 回まで
  2. ユーザーに 3 択を 1 行で知らせる — 子のタブを閉じる / サイドバーから archive する / 子のタブに直接「畳んで」と打つ
  3. 返事を待たずに続行し、次の turn の頭で list_sessions を見てから打ち直す
子に「archive しないこと」を念押ししたいだけなら [決定] / ユーザー指示 の語を外してください (規範は起動 prompt の定型文が持っています)。"

jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
