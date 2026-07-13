#!/usr/bin/env bash
# Watch a GitHub PR/Issue in DELTA mode (Git Bash / Linux / macOS).
# Conditional requests (ETag -> 304) make idle polls free (no rate cost) and fast;
# comments fetched incrementally via `since`. No Claude, no LLM tokens.
# Usage: ./watch-pr.sh <owner/repo> <pr-number> [interval-sec]
# Requires: gh CLI authenticated. Uses gh's built-in jq (-q), no external jq. Ctrl+C to stop.
set -u
repo="${1:?usage: watch-pr.sh <owner/repo> <pr> [interval]}"
pr="${2:?usage: watch-pr.sh <owner/repo> <pr> [interval]}"
interval="${3:-120}"

# REST (not `gh pr view`, which uses GraphQL) so this stays alive even when the
# separate GraphQL rate pool is exhausted by unrelated `gh` usage in the same session.
headref=$(gh api "repos/$repo/pulls/$pr" -q .head.ref 2>/dev/null)
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# et_issue/et_checks are read/written via nameref indirection (${!2}, printf -v)
# inside cond_get(), which shellcheck's static analysis can't trace.
# shellcheck disable=SC2034
et_issue=""
# shellcheck disable=SC2034
et_checks=""
prevf=""

# Track id -> updated_at per comment, not just a max-id watermark. A "sticky"
# comment bot (edit-in-place instead of posting new comments, to avoid spam)
# keeps the same id forever; an id-only watermark would silently swallow every
# edit after the first sighting. Comparing updated_at catches edits too.
declare -A seen_comments
while IFS=$'\t' read -r cid cupdated; do
  [ -n "$cid" ] && seen_comments["$cid"]="$cupdated"
done < <(gh api "repos/$repo/issues/$pr/comments?per_page=100" -q '.[] | "\(.id)\t\(.updated_at)"' 2>/dev/null)

# Conditional GET via gh api --include. Prints "304" on not-modified, else body JSON.
# Updates the named etag var (nameref) from the response headers.
cond_get() { # $1=url  $2=etag-varname
  local url="$1" var="$2" cur="${!2}" out status body newet
  if [ -n "$cur" ]; then
    out=$(gh api "$url" -H "If-None-Match: $cur" --include 2>/dev/null)
  else
    out=$(gh api "$url" --include 2>/dev/null)
  fi
  status=$(printf '%s\n' "$out" | head -1)
  case "$status" in *" 304 "*) echo "304"; return 0;; esac
  newet=$(printf '%s\n' "$out" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{print $2}')
  [ -n "$newet" ] && printf -v "$var" '%s' "$newet"
  # body = everything after the first blank line
  body=$(printf '%s\n' "$out" | awk 'f{print} /^\r?$/{f=1}')
  printf '%s' "$body"
}

state0=$(gh api "repos/$repo/pulls/$pr" -q .state 2>/dev/null)
[ -z "$headref" ] && echo "note: head ref not found; CI monitoring disabled."
echo "watching ${repo}#${pr}  state=${state0}  (delta/ETag mode, interval ${interval}s, Ctrl+C to stop)"

while :; do
  sleep "$interval"
  ts=$(date +%H:%M:%S)

  # issue: comments + state + merge/close
  body=$(cond_get "repos/$repo/issues/$pr" et_issue)
  if [ "$body" != "304" ] && [ -n "$body" ]; then
    # new or edited comments (edited = same id, changed updated_at -- catches
    # sticky/edit-in-place bots that a plain id watermark would miss)
    while IFS=$'\t' read -r cid cupdated clogin cbody; do
      [ -z "$cid" ] && continue
      prev="${seen_comments[$cid]:-}"
      if [ -z "$prev" ]; then
        tag="COMMENT"
      elif [ "$prev" != "$cupdated" ]; then
        tag="COMMENT (edited)"
      else
        continue
      fi
      seen_comments["$cid"]="$cupdated"
      echo "[$ts] ${tag} @${clogin}: ${cbody:0:220}"
    done < <(gh api "repos/$repo/issues/$pr/comments?since=$since&per_page=100" \
               -q '.[] | "\(.id)\t\(.updated_at)\t\(.user.login)\t\((.body // "") | gsub("[\n\r]+";" "))"' 2>/dev/null)
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # issue changed -> check terminal state (small extra call, only on change; REST not GraphQL)
    read -r state merged < <(gh api "repos/$repo/pulls/$pr" \
                               -q '"\(.state) \(.merged_at // "-")"' 2>/dev/null)
    if [ -n "${state:-}" ] && [ "$state" != "open" ]; then
      if [ "${merged:-}" != "-" ] && [ -n "${merged:-}" ]; then echo "[$ts] MERGED ${repo}#${pr} at ${merged}"; else echo "[$ts] CLOSED ${repo}#${pr} (not merged)"; fi
      break
    fi
  fi

  # check-runs: CI failures
  if [ -n "$headref" ]; then
    cbody=$(cond_get "repos/$repo/commits/$headref/check-runs" et_checks)
    if [ "$cbody" != "304" ] && [ -n "$cbody" ]; then
      fails=$(gh api "repos/$repo/commits/$headref/check-runs" \
                -q '[.check_runs[] | select(.conclusion=="failure" or .conclusion=="timed_out" or .conclusion=="cancelled" or .conclusion=="startup_failure" or .conclusion=="action_required") | .name] | unique | join(", ")' 2>/dev/null)
      if [ -n "$fails" ] && [ "$fails" != "$prevf" ]; then echo "[$ts] CI-FAIL: $fails"; fi
      prevf="$fails"
    fi
  fi
done
