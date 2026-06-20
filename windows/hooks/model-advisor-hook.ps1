<#
.SYNOPSIS
    Claude Code UserPromptSubmit hook: first-prompt model advisor.

.DESCRIPTION
    Safety net for teammates who launch `claude` directly instead of the
    session launcher. Checks ONLY the first prompt of each session:
      - classifies it (fast keyword pass; no API call, so the hook adds
        near-zero latency),
      - compares against the session's active model,
      - prints an advisory if they don't match ("consider /model opus").

    It NEVER switches the model itself and never re-checks after the
    first prompt — sticky sessions stay sticky.

    State: one marker file per session_id under ~/.claude-dispatch/state/

.NOTES
    Claude Code invokes this hook with a JSON payload on stdin:
      { "session_id": "...", "prompt": "...", "cwd": "...", ... }
#>

$ErrorActionPreference = 'SilentlyContinue'

# ---- Read hook payload from stdin -----------------------------------------
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
if (-not $payload -or -not $payload.prompt) { exit 0 }

$sessionId = $payload.session_id
$prompt    = $payload.prompt

# ---- Sticky check: only the FIRST prompt of a session gets evaluated ------
$stateDir  = Join-Path $HOME '.claude-dispatch/state'
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$marker = Join-Path $stateDir "$sessionId.checked"
if (Test-Path $marker) { exit 0 }          # already advised this session
New-Item -ItemType File -Path $marker -Force | Out-Null

# ---- Lightweight complexity heuristic (no API call inside a hook) ---------
# Hooks run synchronously before every prompt; a Haiku round-trip here
# would add 1-2s of latency to the user's FIRST message. Keywords are
# good enough for an advisory.
$complexSignals = @(
    'architect', 'design', 'refactor', 'migrate', 'migration',
    'investigate', 'root cause', 'race condition', 'deadlock', 'concurren',
    'performance', 'optimi[sz]e', 'security', 'review the', 'across',
    'strategy', 'trade-?off', 'debug', 'why is', 'intermittent'
)
$simpleSignals = @(
    'rename', 'typo', 'comment', 'scaffold', 'boilerplate', 'format',
    'add (a )?test', 'unit test', 'docstring', 'readme', 'commit message',
    'explain', 'what does'
)

$complexHits = ($complexSignals | Where-Object { $prompt -imatch $_ }).Count
$simpleHits  = ($simpleSignals  | Where-Object { $prompt -imatch $_ }).Count

$recommended =
    if     ($complexHits -gt $simpleHits) { 'opus' }
    elseif ($simpleHits  -gt $complexHits) { 'sonnet' }
    else   { $null }                        # ambiguous -> stay quiet

if (-not $recommended) { exit 0 }

# ---- Determine the session's active model ---------------------------------
# Precedence: env var (set per-session) > project settings > user settings.
function Get-ActiveModel {
    if ($env:ANTHROPIC_MODEL) { return $env:ANTHROPIC_MODEL }
    foreach ($p in @(
        (Join-Path (Get-Location) '.claude/settings.json'),
        (Join-Path $HOME '.claude/settings.json')
    )) {
        if (Test-Path $p) {
            $s = Get-Content $p -Raw | ConvertFrom-Json
            if ($s.model) { return $s.model }
        }
    }
    return $null
}

$active = Get-ActiveModel
if (-not $active) { exit 0 }                # unknown -> don't guess

$mismatch =
    ($recommended -eq 'opus'   -and $active -inotmatch 'opus') -or
    ($recommended -eq 'sonnet' -and $active -inotmatch 'sonnet')

if (-not $mismatch) { exit 0 }

# ---- Advise the user (never auto-switch) -----------------------------------
$msg = "Model advisor: this session's task looks like a better fit for " +
       "'$recommended' (currently on '$active'). Switch with: /model $recommended"

@{ systemMessage = $msg } | ConvertTo-Json -Compress
exit 0
