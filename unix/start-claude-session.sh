#!/usr/bin/env bash
#
# start-claude-session.sh — session-level model dispatcher for Claude Code (macOS/Linux).
#
# Describe your task once; a fast Haiku classifier judges TASK COMPLEXITY
# (not prompt length) and launches an interactive Claude Code session on the
# right model, locked for the whole session.
#
#   TRIVIAL  -> Haiku    (explain code, quick Q&A)
#   SIMPLE   -> Sonnet   (tests, renames, scaffolding, well-specified edits)
#   COMPLEX  -> Opus     (architecture, debugging, cross-cutting changes)
#
# Fail-strong: low-confidence classifications bump UP one tier.
#
# Usage:
#   ccs "investigate the intermittent deadlock on save"     # -> opus
#   ccs "add unit tests for OrderValidator.Validate"        # -> sonnet
#   ccs "what does the AuthMiddleware class do?"            # -> haiku
#   ccs -m opus "anything"                                  # force a model
#   ccs "!sonnet rename getUserData"                         # inline force
#   ccs --dry-run "some task"                               # show decision only
#
# jq is used when present; a portable fallback parser is used otherwise.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/dispatch-config.json"
# Fall back to the parent dir: in the repo the shared config lives one level up
# (root); a flat user install keeps it next to this script.
[ -f "$CONFIG_FILE" ] || CONFIG_FILE="$(dirname "$SCRIPT_DIR")/dispatch-config.json"

# ---- Defaults (overridden by dispatch-config.json) ------------------------
ROUTER_MODEL="haiku"
TRIVIAL_MODEL="haiku"
SIMPLE_MODEL="sonnet"
COMPLEX_MODEL="opus"
CONFIDENCE_FLOOR="0.6"
LOG_DIR="$HOME/.claude-dispatch"

# ---- JSON helpers (jq if available, else grep/sed on unique keys) ----------
_have_jq() { command -v jq >/dev/null 2>&1; }

# string field by unique key from a JSON string
json_str() { # key, json
  if _have_jq; then
    printf '%s' "$2" | jq -r "(.$1 // empty)" 2>/dev/null
  else
    printf '%s' "$2" | tr -d '\n' \
      | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | head -1 \
      | sed "s/.*:[[:space:]]*\"\([^\"]*\)\".*/\1/"
  fi
}
# number field by unique key from a JSON string
json_num() { # key, json
  if _have_jq; then
    printf '%s' "$2" | jq -r "(.$1 // empty)" 2>/dev/null
  else
    printf '%s' "$2" | tr -d '\n' \
      | grep -o "\"$1\"[[:space:]]*:[[:space:]]*[0-9.]*" | head -1 \
      | sed "s/.*:[[:space:]]*//"
  fi
}

# ---- Load config ----------------------------------------------------------
if [ -f "$CONFIG_FILE" ]; then
  cfg="$(cat "$CONFIG_FILE")"
  if _have_jq; then
    v=$(printf '%s' "$cfg" | jq -r '(.models.router  // empty)'); [ -n "$v" ] && ROUTER_MODEL="$v"
    v=$(printf '%s' "$cfg" | jq -r '(.models.trivial // empty)'); [ -n "$v" ] && TRIVIAL_MODEL="$v"
    v=$(printf '%s' "$cfg" | jq -r '(.models.simple  // empty)'); [ -n "$v" ] && SIMPLE_MODEL="$v"
    v=$(printf '%s' "$cfg" | jq -r '(.models.complex // empty)'); [ -n "$v" ] && COMPLEX_MODEL="$v"
    v=$(printf '%s' "$cfg" | jq -r '(.confidenceFloor // empty)'); [ -n "$v" ] && CONFIDENCE_FLOOR="$v"
    v=$(printf '%s' "$cfg" | jq -r '(.logDir // empty)'); [ -n "$v" ] && LOG_DIR="$v"
  else
    # keys are unique across the file, so flat extraction is safe
    v=$(json_str router  "$cfg"); [ -n "$v" ] && ROUTER_MODEL="$v"
    v=$(json_str trivial "$cfg"); [ -n "$v" ] && TRIVIAL_MODEL="$v"
    v=$(json_str simple  "$cfg"); [ -n "$v" ] && SIMPLE_MODEL="$v"
    v=$(json_str complex "$cfg"); [ -n "$v" ] && COMPLEX_MODEL="$v"
    v=$(json_num confidenceFloor "$cfg"); [ -n "$v" ] && CONFIDENCE_FLOOR="$v"
    v=$(json_str logDir "$cfg"); [ -n "$v" ] && LOG_DIR="$v"
  fi
fi

# ---- Preflight ------------------------------------------------------------
if ! command -v claude >/dev/null 2>&1; then
  echo "ERROR: Claude Code CLI ('claude') not found on PATH. Install it, then retry." >&2
  exit 1
fi

# ---- Parse args -----------------------------------------------------------
MODEL_FORCE=""
DRY_RUN=0
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -m|--model) MODEL_FORCE="${2:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    --)         shift; while [ $# -gt 0 ]; do ARGS+=("$1"); shift; done ;;
    *)          ARGS+=("$1"); shift ;;
  esac
done
TASK="${ARGS[*]:-}"

# inline override:  !haiku / !sonnet / !opus  at the start of the task
if [[ "$TASK" =~ ^!(haiku|sonnet|opus)([[:space:]]+(.*))?$ ]]; then
  MODEL_FORCE="${BASH_REMATCH[1]}"
  TASK="${BASH_REMATCH[3]:-}"
fi

# trim leading/trailing whitespace
TASK="$(printf '%s' "$TASK" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

if [ -z "$TASK" ]; then
  echo "ERROR: No task provided. Usage: ccs \"describe your task\"" >&2
  exit 1
fi

mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/sessions.jsonl"

# ---- Classification -------------------------------------------------------
classify() { # task -> "TIER|CONF|REASON"
  local task="$1"
  local instruction
  instruction='You are a model-routing classifier for a software engineering session.
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
{"tier":"TRIVIAL|SIMPLE|COMPLEX","confidence":0.0-1.0,"reason":"<=12 words"}'

  local payload raw json tier conf reason
  payload="$instruction

<task>
$task
</task>"

  raw="$(claude --model "$ROUTER_MODEL" -p "$payload" 2>/dev/null || true)"
  if [ -z "$raw" ]; then echo "COMPLEX|0.0|classifier-empty-fallback"; return; fi

  raw="$(printf '%s' "$raw" | sed 's/```json//g; s/```//g')"
  json="$(printf '%s' "$raw" | tr -d '\n' | grep -o '{.*}' | head -1 || true)"
  if [ -z "$json" ]; then echo "COMPLEX|0.0|classifier-noparse-fallback"; return; fi

  tier="$(json_str tier "$json" | tr '[:lower:]' '[:upper:]')"
  conf="$(json_num confidence "$json")"
  reason="$(json_str reason "$json")"

  case "$tier" in
    TRIVIAL|SIMPLE|COMPLEX) ;;
    *) echo "COMPLEX|0.0|bad-tier-fallback"; return ;;
  esac
  [ -z "$conf" ] && conf="0.0"
  [ -z "$reason" ] && reason="(no reason)"
  echo "$tier|$conf|$reason"
}

below_floor() { awk "BEGIN{exit !($1 < $2)}"; }  # true (0) if $1 < $2

# ---- Resolve model --------------------------------------------------------
if [ -n "$MODEL_FORCE" ]; then
  case "$MODEL_FORCE" in
    haiku)  CHOICE="trivial" ;;
    sonnet) CHOICE="simple" ;;
    opus)   CHOICE="complex" ;;
    *) echo "ERROR: -m must be haiku|sonnet|opus" >&2; exit 1 ;;
  esac
  TIER="FORCED"; CONF="1.0"; REASON="user override -> $MODEL_FORCE"
else
  IFS='|' read -r TIER CONF REASON <<< "$(classify "$TASK")"
  case "$TIER" in
    TRIVIAL) CHOICE="trivial" ;;
    SIMPLE)  CHOICE="simple" ;;
    *)       CHOICE="complex" ;;
  esac
  # fail-strong: low-confidence cheaper tiers bump UP one level
  if below_floor "$CONF" "$CONFIDENCE_FLOOR"; then
    if   [ "$CHOICE" = "trivial" ]; then CHOICE="simple";  REASON="low-conf TRIVIAL bumped ($REASON)";
    elif [ "$CHOICE" = "simple"  ]; then CHOICE="complex"; REASON="low-conf SIMPLE bumped ($REASON)"; fi
  fi
fi

case "$CHOICE" in
  trivial) WORKER="$TRIVIAL_MODEL" ;;
  simple)  WORKER="$SIMPLE_MODEL" ;;
  complex) WORKER="$COMPLEX_MODEL" ;;
esac

# ---- Log ------------------------------------------------------------------
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
head_task="$(printf '%s' "$TASK" | cut -c1-120)"
printf '{"timestamp":"%s","model":"%s","tier":"%s","confidence":%s,"reason":"%s","taskHead":"%s"}\n' \
  "$ts" "$WORKER" "$TIER" "${CONF:-0}" "$(esc "$REASON")" "$(esc "$head_task")" >> "$LOG_FILE"

printf '\n  [dispatch] %s (conf %s) -> %s\n' "$TIER" "$CONF" "$WORKER"
printf '  [dispatch] %s\n\n' "$REASON"

[ "$DRY_RUN" -eq 1 ] && exit 0

# ---- Launch interactive session, task as opening prompt, model locked -----
exec claude --model "$WORKER" "$TASK"
