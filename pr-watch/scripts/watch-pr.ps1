#requires -Version 5.1
<#
.SYNOPSIS
  Watch a GitHub PR/Issue from the terminal in DELTA mode: report CI failures,
  new comments, and merge/close, then exit. Uses conditional requests (ETag ->
  304) so idle polls cost zero rate limit and return instantly; comments are
  fetched incrementally via `since`. Runs entirely on your machine (no Claude),
  so it costs zero LLM tokens and survives the session closing.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File watch-pr.ps1 -Repo ippoan/nuxt-pwa-carins -Pr 47
.EXAMPLE
  .\watch-pr.ps1 -Repo owner/repo -Pr 123 -IntervalSec 60
.NOTES
  Requires gh CLI authenticated (gh auth status). Stop with Ctrl+C.
  ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI and corrupts
  non-ASCII bytes, so keep this file ASCII to stay portable.
#>
param(
  [Parameter(Mandatory = $true)][string]$Repo,
  [Parameter(Mandatory = $true)][int]$Pr,
  [int]$IntervalSec = 120,
  [switch]$NoBeep
)

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$tok = (gh auth token 2>$null)
if (-not $tok) { Write-Host "gh not authenticated. Run 'gh auth status' / 'gh auth login'." -ForegroundColor Red; exit 1 }
$H   = @{ Authorization = "Bearer $tok"; 'User-Agent' = 'pr-watch'; Accept = 'application/vnd.github+json' }
$api = 'https://api.github.com'

# Conditional GET. Returns @{changed=<bool>; data=<obj|null>}.
# changed=$false on 304 (not modified) or transient error -> caller skips.
function Get-Cond([string]$Url, [ref]$Etag) {
  $h = $H.Clone()
  if ($Etag.Value) { $h['If-None-Match'] = $Etag.Value }
  try {
    $r = Invoke-WebRequest -Uri $Url -Headers $h -UseBasicParsing -ErrorAction Stop
    if ($r.Headers['ETag']) { $Etag.Value = $r.Headers['ETag'] }
    return @{ changed = $true; data = ($r.Content | ConvertFrom-Json) }
  } catch {
    # 304 = not modified (expected on idle); anything else = transient, retry next cycle.
    return @{ changed = $false; data = $null }
  }
}

# REST (not `gh pr view`, which uses GraphQL) so this stays alive even when the
# separate GraphQL rate pool is exhausted by unrelated `gh` usage in the same session.
$headRef   = (gh api "repos/$Repo/pulls/$Pr" -q .head.ref 2>$null)
$issueUrl  = "$api/repos/$Repo/issues/$Pr"
$checksUrl = if ($headRef) { "$api/repos/$Repo/commits/$headRef/check-runs" } else { $null }

$etIssue = ''; $etChecks = ''; $prevf = ''
$since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# Track id -> updated_at per comment, not just a max-id watermark. A "sticky"
# comment bot (edit-in-place instead of posting new comments, to avoid spam)
# keeps the same id forever; an id-only watermark would silently swallow every
# edit after the first sighting. Comparing updated_at catches edits too.
$seenComments = @{}

# Seed: prime the issue ETag and record existing comments' updated_at so
# pre-existing comments are not re-announced, but future edits to them are.
$seed = Get-Cond $issueUrl ([ref]$etIssue)
$state0 = if ($seed.data) { $seed.data.state } else { '?' }
try {
  $existing = Invoke-RestMethod -Uri "$issueUrl/comments?per_page=100" -Headers $H
  foreach ($c in $existing) { $seenComments[[string]$c.id] = $c.updated_at }
} catch {}
if (-not $checksUrl) { Write-Host "note: head ref not found; CI monitoring disabled (comments/merge still watched)." -ForegroundColor DarkYellow }
Write-Host ("watching {0}#{1}  state={2}  (delta/ETag mode, interval {3}s, Ctrl+C to stop)" -f $Repo, $Pr, $state0, $IntervalSec) -ForegroundColor DarkGray

while ($true) {
  Start-Sleep -Seconds $IntervalSec
  $ts = Get-Date -Format 'HH:mm:ss'

  # --- issue: comments + state + merge/close (ETag-gated; 304 when nothing changed) ---
  $iss = Get-Cond $issueUrl ([ref]$etIssue)
  if ($iss.changed -and $iss.data) {
    try {
      $cs = @(Invoke-RestMethod -Uri "$issueUrl/comments?since=$since&per_page=100" -Headers $H)
      foreach ($c in $cs) {
        $key = [string]$c.id
        $isNew = -not $seenComments.ContainsKey($key)
        $isEdited = (-not $isNew) -and ($seenComments[$key] -ne $c.updated_at)
        if (-not ($isNew -or $isEdited)) { continue }
        $seenComments[$key] = $c.updated_at
        $b = ($c.body -replace '\s+', ' ')
        if ($b.Length -gt 220) { $b = $b.Substring(0, 220) + '...' }
        $tag = if ($isEdited) { 'COMMENT (edited)' } else { 'COMMENT' }
        Write-Host ("[{0}] {1} @{2}: {3}" -f $ts, $tag, $c.user.login, $b) -ForegroundColor Cyan
      }
    } catch {}
    $since = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    if ($iss.data.state -ne 'open') {
      if ($iss.data.pull_request -and $iss.data.pull_request.merged_at) {
        Write-Host ("[{0}] MERGED {1}#{2} at {3}" -f $ts, $Repo, $Pr, $iss.data.pull_request.merged_at) -ForegroundColor Green
      } else {
        Write-Host ("[{0}] CLOSED {1}#{2} (not merged)" -f $ts, $Repo, $Pr) -ForegroundColor Yellow
      }
      if (-not $NoBeep) { [console]::Beep(880, 400) }
      break
    }
  }

  # --- check-runs: CI failures (ETag-gated; REST conclusions are lowercase) ---
  if ($checksUrl) {
    $ck = Get-Cond $checksUrl ([ref]$etChecks)
    if ($ck.changed -and $ck.data) {
      $fails = @($ck.data.check_runs |
        Where-Object { $_.conclusion -in 'failure','timed_out','cancelled','startup_failure','action_required' } |
        ForEach-Object { $_.name })
      $failstr = ($fails | Sort-Object -Unique) -join ', '
      if ($failstr -and $failstr -ne $prevf) { Write-Host ("[{0}] CI-FAIL: {1}" -f $ts, $failstr) -ForegroundColor Red }
      $prevf = $failstr
    }
  }
}
