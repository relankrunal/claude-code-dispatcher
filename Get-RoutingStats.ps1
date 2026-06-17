<#
.SYNOPSIS
    Summarize Claude Code routing decisions for a sprint cost report.

.DESCRIPTION
    Reads ~/.claude-dispatch/sessions.jsonl and reports the routing split,
    plus an estimated saving versus an "all-Opus" baseline.

    The saving estimate uses RELATIVE model weights (Opus = 1.0 baseline).
    These are rough planning multipliers, not a billing figure — adjust
    -OpusWeight/-SonnetWeight/-HaikuWeight to match your current pricing.

.PARAMETER Since
    Only count sessions on/after this date (e.g. '2026-06-01').

.EXAMPLE
    .\Get-RoutingStats.ps1
    .\Get-RoutingStats.ps1 -Since 2026-06-01
#>
[CmdletBinding()]
param(
    [datetime]$Since,
    [double]$OpusWeight   = 1.00,
    [double]$SonnetWeight = 0.20,   # Sonnet ~1/5 of Opus
    [double]$HaikuWeight  = 0.05,   # Haiku ~1/20 of Opus
    [string]$LogPath = (Join-Path $HOME '.claude-dispatch/sessions.jsonl')
)

if (-not (Test-Path $LogPath)) {
    Write-Error "No log found at $LogPath. Run some sessions with ccs first."
    exit 1
}

$rows = @()
foreach ($line in Get-Content $LogPath) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { }
}

if ($Since) {
    $rows = $rows | Where-Object { [datetime]$_.timestamp -ge $Since }
}

$total = $rows.Count
if ($total -eq 0) { Write-Host "No sessions in range."; exit 0 }

function ModelWeight($m) {
    if ($m -match 'opus')   { return $OpusWeight }
    if ($m -match 'sonnet') { return $SonnetWeight }
    if ($m -match 'haiku')  { return $HaikuWeight }
    return $OpusWeight
}

$byModel = $rows | Group-Object model | Sort-Object Count -Descending

Write-Host ""
Write-Host "  Claude Code Routing Report" -ForegroundColor Cyan
if ($Since) { Write-Host "  Since: $($Since.ToString('yyyy-MM-dd'))" -ForegroundColor DarkGray }
Write-Host "  Total sessions: $total" -ForegroundColor DarkGray
Write-Host ""
Write-Host ("  {0,-28} {1,6} {2,8}" -f 'Model', 'Count', 'Share')
Write-Host ("  " + ('-' * 44))
foreach ($g in $byModel) {
    $pct = [Math]::Round(100.0 * $g.Count / $total, 1)
    Write-Host ("  {0,-28} {1,6} {2,7}%" -f $g.Name, $g.Count, $pct)
}

# Cost model: actual weighted vs all-Opus baseline
$actual = 0.0
foreach ($r in $rows) { $actual += (ModelWeight $r.model) }
$baseline = $total * $OpusWeight
$saving = 0.0
if ($baseline -gt 0) { $saving = [Math]::Round(100.0 * ($baseline - $actual) / $baseline, 1) }

Write-Host ""
Write-Host ("  Relative cost vs all-Opus baseline: {0}% of baseline" -f [Math]::Round(100.0*$actual/$baseline,1)) -ForegroundColor Green
Write-Host ("  Estimated saving from routing:      {0}%" -f $saving) -ForegroundColor Green
Write-Host ""
Write-Host "  (Weights are planning estimates — set -OpusWeight/-SonnetWeight/-HaikuWeight to match current pricing.)" -ForegroundColor DarkGray
Write-Host ""
