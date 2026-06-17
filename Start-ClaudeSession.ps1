<#
.SYNOPSIS
    Start-ClaudeSession — session-level intelligent model dispatcher for Claude Code.

.DESCRIPTION
    Describe your task once. A fast Haiku classifier judges TASK COMPLEXITY
    (not prompt length) and launches an interactive Claude Code session on the
    right model. The model stays locked for the whole session.

    Three tiers:
        TRIVIAL  -> Haiku    (explain code, quick Q&A, one-line lookups)
        SIMPLE   -> Sonnet   (tests, renames, scaffolding, well-specified edits)
        COMPLEX  -> Opus     (architecture, debugging, cross-cutting changes)

    Fail-strong: low-confidence classifications bump UP one tier.

.PARAMETER Task
    The task description (positional). One sentence is enough.

.PARAMETER Model
    Force a model (haiku|sonnet|opus), skipping classification.

.PARAMETER ClaudeArgs
    Extra args passed straight to `claude` (e.g. --add-dir, --allowedTools).

.PARAMETER DryRun
    Show the routing decision without launching the session.

.EXAMPLE
    ccs "investigate why the cache invalidation fails under concurrent writes"
    # -> Opus session

.EXAMPLE
    ccs "add unit tests for the OrderValidator.Validate method"
    # -> Sonnet session

.EXAMPLE
    ccs "what does the AuthMiddleware class do?"
    # -> Haiku session

.EXAMPLE
    ccs -Model opus "anything"                  # force a model
    ccs "!sonnet rename getUserData to fetchUser"  # inline force via prefix
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Task,

    [ValidateSet('haiku', 'sonnet', 'opus')]
    [string]$Model,

    [string[]]$ClaudeArgs = @(),

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Defaults (overridden by dispatch-config.json next to this script)
# ---------------------------------------------------------------------------
$defaults = @{
    models = @{
        router  = 'haiku'    # classifier model (alias resolves to current Haiku)
        trivial = 'haiku'
        simple  = 'sonnet'
        complex = 'opus'
    }
    # Minimum confidence to TRUST a cheaper classification.
    # Below this, the tier is bumped up one level (fail-strong).
    confidenceFloor = 0.6
    logDir = (Join-Path $HOME '.claude-dispatch')
}

function Get-Config {
    $cfg = @{
        models = @{
            router  = $defaults.models.router
            trivial = $defaults.models.trivial
            simple  = $defaults.models.simple
            complex = $defaults.models.complex
        }
        confidenceFloor = $defaults.confidenceFloor
        logDir = $defaults.logDir
    }
    $cfgPath = Join-Path $PSScriptRoot 'dispatch-config.json'
    if (Test-Path $cfgPath) {
        try {
            $json = Get-Content $cfgPath -Raw | ConvertFrom-Json
            if ($json.models) {
                foreach ($k in @('router','trivial','simple','complex')) {
                    if ($json.models.$k) { $cfg.models[$k] = $json.models.$k }
                }
            }
            if ($null -ne $json.confidenceFloor) { $cfg.confidenceFloor = [double]$json.confidenceFloor }
            if ($json.logDir) { $cfg.logDir = $json.logDir }
        }
        catch {
            Write-Warning "Could not parse dispatch-config.json; using defaults. ($($_.Exception.Message))"
        }
    }
    return $cfg
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Error "Claude Code CLI ('claude') not found on PATH. Install it, then retry."
    exit 1
}

$TaskText = ''
if ($Task) { $TaskText = ($Task -join ' ').Trim() }
if ([string]::IsNullOrWhiteSpace($TaskText)) {
    Write-Error "No task provided. Usage: ccs ""describe your task"""
    exit 1
}

$cfg = Get-Config
if (-not (Test-Path $cfg.logDir)) { New-Item -ItemType Directory -Path $cfg.logDir -Force | Out-Null }
$logFile = Join-Path $cfg.logDir 'sessions.jsonl'

# ---------------------------------------------------------------------------
# Inline override: leading !haiku / !sonnet / !opus
# ---------------------------------------------------------------------------
$forced = $null
if ($TaskText -match '^\s*!(haiku|sonnet|opus)\b') {
    $forced = $Matches[1].ToLower()
    $TaskText = ($TaskText -replace '^\s*!(haiku|sonnet|opus)\b', '').Trim()
}
if ($Model) { $forced = $Model }

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------
function Invoke-Classifier {
    param([string]$UserTask, $Cfg)

    $instruction = @'
You are a model-routing classifier for a software engineering session.
Judge the TASK, not the wording or length. A long, well-specified prompt
can still be SIMPLE. A short prompt demanding design judgment is COMPLEX.

TRIVIAL  - explaining existing code, quick factual lookups, "what does X do",
           formatting, single-line comments, trivial Q&A. No code change, or
           a change so small it needs no reasoning.
SIMPLE   - mechanical or well-specified: renames, scaffolding, boilerplate,
           writing tests for clearly described behavior, single-component edits,
           applying an already-decided fix.
COMPLEX  - architecture, design decisions, trade-off analysis, cross-cutting
           changes across layers/projects, debugging with unknown root cause,
           concurrency/race conditions, performance or security work, ambiguous
           requirements needing interpretation.

Respond with ONLY a JSON object. No markdown, no fences, no prose:
{"tier":"TRIVIAL|SIMPLE|COMPLEX","confidence":0.0-1.0,"reason":"<=12 words"}
'@

    $payload = "$instruction`n`n<task>`n$UserTask`n</task>"

    try {
        $raw = & claude --model $Cfg.models.router -p $payload 2>$null
        if (-not $raw) { throw 'empty classifier response' }

        $text = ($raw -join "`n") -replace '```json', '' -replace '```', ''
        if ($text -match '(?s)\{.*\}') { $text = $Matches[0] }

        $v = $text | ConvertFrom-Json
        $tier = "$($v.tier)".ToUpper()
        if ($tier -notin @('TRIVIAL','SIMPLE','COMPLEX')) { throw "bad tier '$tier'" }

        $conf = 0.0
        if ($null -ne $v.confidence) { $conf = [double]$v.confidence }

        return [pscustomobject]@{ tier = $tier; confidence = $conf; reason = "$($v.reason)" }
    }
    catch {
        Write-Warning "Classifier failed ($($_.Exception.Message)); defaulting to COMPLEX/Opus."
        return [pscustomobject]@{ tier = 'COMPLEX'; confidence = 0.0; reason = 'classifier-failure-fallback' }
    }
}

# Resolve choice -----------------------------------------------------------
if ($forced) {
    # Map a forced model alias to its tier key so config custom IDs still apply.
    switch ($forced) {
        'haiku'  { $choice = 'trivial' }
        'sonnet' { $choice = 'simple' }
        'opus'   { $choice = 'complex' }
    }
    $tier   = 'FORCED'
    $reason = "user override -> $forced"
    $conf   = 1.0
}
else {
    $verdict = Invoke-Classifier -UserTask $TaskText -Cfg $cfg
    $tier   = $verdict.tier
    $conf   = $verdict.confidence
    $reason = $verdict.reason

    if ($tier -eq 'TRIVIAL') { $choice = 'trivial' }
    elseif ($tier -eq 'SIMPLE') { $choice = 'simple' }
    else { $choice = 'complex' }

    # Fail-strong: low-confidence cheaper tiers bump UP one level
    if ($conf -lt $cfg.confidenceFloor) {
        if ($choice -eq 'trivial') { $choice = 'simple'; $reason = "low-conf TRIVIAL bumped ($reason)" }
        elseif ($choice -eq 'simple') { $choice = 'complex'; $reason = "low-conf SIMPLE bumped ($reason)" }
    }
}

$workerModel = $cfg.models[$choice]

# ---------------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------------
$headLen = [Math]::Min(120, $TaskText.Length)
$entry = [ordered]@{
    timestamp  = (Get-Date).ToString('o')
    model      = $workerModel
    tier       = $tier
    confidence = $conf
    reason     = $reason
    taskHead   = $TaskText.Substring(0, $headLen)
} | ConvertTo-Json -Compress
Add-Content -Path $logFile -Value $entry

Write-Host ""
Write-Host "  [dispatch] $tier (conf $conf) -> $workerModel" -ForegroundColor Cyan
Write-Host "  [dispatch] $reason" -ForegroundColor DarkGray
Write-Host ""

if ($DryRun) { return }

# ---------------------------------------------------------------------------
# Launch interactive session, task as opening prompt, model locked.
# ---------------------------------------------------------------------------
& claude --model $workerModel @ClaudeArgs $TaskText
exit $LASTEXITCODE
