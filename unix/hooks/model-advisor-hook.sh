#!/usr/bin/env bash
#
# model-advisor-hook.sh — Claude Code UserPromptSubmit hook (macOS/Linux).
#
# Safety net for people who launch `claude` directly instead of the session
# launcher. Checks ONLY the first prompt of each session: classifies it with a
# fast keyword pass (no API call -> near-zero latency), compares against the
# active model, and prints an advisory if they don't match. It NEVER switches
# the model and never re-checks after the first prompt.
#
# Claude Code invokes this hook with a JSON payload on stdin:
#   { "session_id": "...", "prompt": "...", "cwd": "...", ... }

set -u

# ---- Read hook payload from stdin -----------------------------------------
payload="$(cat)"
[ -z "$payload" ] && exit 0

_have_jq() { command -v jq >/dev/null 2>&1; }
field() { # key  (reads from $payload)
  if _have_jq; then
    printf '%s' "$payload" | jq -r "(.$1 // empty)" 2>/dev/null
  else
    printf '%s' "$payload" | tr -d '\n' \
      | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
      | sed "s/.*:[[:space:]]*\"\([^\"]*\)\".*/\1/"
  fi
}

prompt="$(field prompt)"
session_id="$(field session_id)"
[ -z "$prompt" ] && exit 0

# ---- Sticky check: only the FIRST prompt of a session is evaluated --------
state_dir="$HOME/.claude-dispatch/state"
mkdir -p "$state_dir"
marker="$state_dir/${session_id:-unknown}.checked"
[ -f "$marker" ] && exit 0
: > "$marker"

# ---- Lightweight complexity heuristic (no API call inside a hook) ---------
lc_prompt="$(printf '%s' "$prompt" | tr '[:upper:]' '[:lower:]')"

complex_re='architect|design|refactor|migrat|investigat|root cause|race condition|deadlock|concurren|performance|optimi|security|review the|across|strategy|trade.?off|debug|why is|intermittent'
simple_re='rename|typo|comment|scaffold|boilerplate|format|add a test|add test|unit test|docstring|readme|commit message|explain|what does'

complex_hits="$(printf '%s' "$lc_prompt" | grep -oE "$complex_re" | grep -c . || true)"
simple_hits="$(printf '%s'  "$lc_prompt" | grep -oE "$simple_re"  | grep -c . || true)"

recommended=""
if   [ "$complex_hits" -gt "$simple_hits" ]; then recommended="opus"
elif [ "$simple_hits"  -gt "$complex_hits" ]; then recommended="sonnet"
fi
[ -z "$recommended" ] && exit 0   # ambiguous -> stay quiet

# ---- Determine the session's active model ---------------------------------
# Precedence: env var > project settings > user settings.
active=""
if [ -n "${ANTHROPIC_MODEL:-}" ]; then
  active="$ANTHROPIC_MODEL"
else
  for p in "$(pwd)/.claude/settings.json" "$HOME/.claude/settings.json"; do
    if [ -f "$p" ]; then
      if _have_jq; then
        m="$(jq -r '(.model // empty)' "$p" 2>/dev/null)"
      else
        m="$(tr -d '\n' < "$p" | grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')"
      fi
      [ -n "$m" ] && { active="$m"; break; }
    fi
  done
fi
[ -z "$active" ] && exit 0   # unknown -> don't guess

# ---- Compare and advise (never auto-switch) -------------------------------
mismatch=0
case "$recommended" in
  opus)   printf '%s' "$active" | grep -qi 'opus'   || mismatch=1 ;;
  sonnet) printf '%s' "$active" | grep -qi 'sonnet' || mismatch=1 ;;
esac
[ "$mismatch" -eq 0 ] && exit 0

msg="Model advisor: this session's task looks like a better fit for '$recommended' (currently on '$active'). Switch with: /model $recommended"

# Emit compact JSON with a systemMessage (escape backslashes and quotes)
esc="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
printf '{"systemMessage":"%s"}\n' "$esc"
exit 0
