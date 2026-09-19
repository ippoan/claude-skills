#!/bin/bash
# PreToolUse / matcher: mcp__ccd_session__spawn_task
# spawn_task の title を task-split/SKILL.md §1 の命名規約 (正本) の 4 形
# (枝の子 / 自 issue の子 / 後継の親 / 別案件の新しい親) に照らして検査し、
# 当たらなければ deny する。
#
# Why (2026-09-12〜14、Refs ippoan/alc-app-s3#135): #p135 の監督 (親) が spawn_task の
# title に `[S] #p135-c-skills-pending …` `[S] #p135-c-kiosk-measurements …`
# `[S] #p135-c-tenko-video …` を付けた。`c` の後ろが番号でなく語で、どの形にも当たらない
# (前の世代も `#p135-c-dtako` 等で同じことをしていた)。
#
# 既知の穴 (承知の上で入れている):
# (a) marker が無い親 (set_session_title 前・「#p135-監督」のような誤った親名) は
#     全部素通しする。marker が立つのは、親が手順 0 で正しく `#p<issue> ` を名乗った
#     後だけ
# (b) marker は session-role-log.sh の `find -mtime +7` で掃かれ、書き直すのは
#     改名時 (set_session_title を打った瞬間) だけなので、7 日を超えて続く親では
#     この検査が外れる
#
# ★ \S は bash の [[ =~ ]] で効かない。空白以外は [^[:space:]] で書く。
set -u

PARENT_DIR="${HOME}/.claude/state/parent-role"

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
[ -n "$sid" ] || exit 0
title=$(printf '%s' "$payload" | jq -r '.tool_input.title // empty' 2>/dev/null || true)
[ -n "$title" ] || exit 0

sid_safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')
marker="${PARENT_DIR}/${sid_safe}"
[ -e "$marker" ] || exit 0

reason_forms="spawn_task の title は task-split/SKILL.md §1 の命名規約 (正本) の 4 形のどれかに完全に当たる必要があります:
 1. 枝の子:          [S]/[O] #c<親issue>-<分岐番号> <題>   例: [S] #c135-18 題
 2. 自 issue の子:    [S]/[O] #p<親issue>-c<子issue> <題>   例: [S] #p874-c987 題
 3. 後継の親:         #p<issue> <題>                         例: #p135 題
 4. 別案件の新しい親: [S]/[O] #p<issue> <題>                 例: [S] #p353 題
分岐番号は台帳で使用済みの最大 + 1 にしてください。"

branch_re='^\[(S|O)\] #c([0-9]+)-[0-9]+ [^[:space:]]'
ownissue_re='^\[(S|O)\] #p([0-9]+)-c[0-9]+(-[0-9]+)? [^[:space:]]'
successor_re='^#p([0-9]+) [^[:space:]]'
newparent_re='^\[(S|O)\] #p([0-9]+) [^[:space:]]'

parent_issue=""
skip_number_check=0
if [[ "$title" =~ $branch_re ]]; then
  parent_issue="${BASH_REMATCH[2]}"
elif [[ "$title" =~ $ownissue_re ]]; then
  parent_issue="${BASH_REMATCH[2]}"
elif [[ "$title" =~ $newparent_re ]]; then
  # 形4: 別案件の新しい親。既存の marker (同じ案件の issue) との番号照合は
  # 意味を成さない (別案件だから当然不一致になる) ので飛ばす。
  parent_issue="${BASH_REMATCH[2]}"
  skip_number_check=1
elif [[ "$title" =~ $successor_re ]]; then
  parent_issue="${BASH_REMATCH[1]}"
else
  reason="spawn_task の title「${title}」は命名規約に当たりません。
${reason_forms}"
  jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
fi

# 親の marker (自分のタイトル。session-role-log.sh が書く) と issue 番号を突き合わせる。
# marker が空 (改名前に立った古い marker 等) や形4 (別案件の新しい親) ならこの照合は飛ばす。
if [ "$skip_number_check" -eq 0 ]; then
  parent_title=$(cat "$marker" 2>/dev/null || true)
  if [ -n "$parent_title" ]; then
    parent_marker_re='^#p([0-9]+) '
    if [[ "$parent_title" =~ $parent_marker_re ]]; then
      marker_issue="${BASH_REMATCH[1]}"
      if [ -n "$parent_issue" ] && [ "$parent_issue" != "$marker_issue" ]; then
        reason="spawn_task の title「${title}」の issue 番号 (${parent_issue}) が、
このセッションの親 issue (#p${marker_issue}) と一致しません (別案件の番号の取り違え)。
${reason_forms}"
        jq -nc --arg r "$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
        exit 0
      fi
    fi
  fi
fi

exit 0
