#!/usr/bin/env bash
# 自分 (claude@) が出した PAM grant が承認待ちを抜けるまで待ち、最終状態を 1 行出して終わる。
# Claude Code で run_in_background に渡すと、承認/却下された瞬間にセッションへ通知が来る。
#   usage: pam-wait-grant.sh <entitlement> <grant-id> [timeout-sec=3600]
set -uo pipefail
ent=$1 id=$2 limit=${3:-3600}
end=$((SECONDS + limit))
while ((SECONDS < end)); do
  st=$(gcloud pam grants search --entitlement="$ent" --caller-relationship=had-created \
        --location=global --project=cloudsql-sv --format=json 2>/dev/null |
       jq -r --arg id "$id" '.[] | select(.name|endswith($id)) | .state')
  case "$st" in
    APPROVAL_AWAITED|"") sleep 15 ;;
    *) echo "$ent/$id: $st"; exit 0 ;;
  esac
done
echo "$ent/$id: TIMEOUT (まだ承認待ち)"; exit 1
