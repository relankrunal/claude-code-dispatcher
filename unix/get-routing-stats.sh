#!/usr/bin/env bash
#
# get-routing-stats.sh — summarize Claude Code routing decisions (macOS/Linux).
#
# Reads ~/.claude-dispatch/sessions.jsonl and reports the routing split plus an
# estimated saving vs an all-Opus baseline. Weights are planning estimates
# (Opus=1.0); override with --opus/--sonnet/--haiku to match current pricing.
#
# Usage:
#   ccrep
#   ccrep --since 2026-06-01
#   ccrep --opus 1.0 --sonnet 0.2 --haiku 0.05

set -euo pipefail

LOG_FILE="$HOME/.claude-dispatch/sessions.jsonl"
SINCE=""
OPUS_W="1.0"; SONNET_W="0.2"; HAIKU_W="0.05"

while [ $# -gt 0 ]; do
  case "$1" in
    --since)  SINCE="${2:-}"; shift 2 ;;
    --opus)   OPUS_W="${2:-}"; shift 2 ;;
    --sonnet) SONNET_W="${2:-}"; shift 2 ;;
    --haiku)  HAIKU_W="${2:-}"; shift 2 ;;
    --log)    LOG_FILE="${2:-}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -f "$LOG_FILE" ]; then
  echo "No log found at $LOG_FILE. Run some sessions with ccs first." >&2
  exit 1
fi

# Optionally filter by date (ISO timestamps sort lexicographically)
rows() {
  if [ -n "$SINCE" ]; then
    while IFS= read -r line; do
      ts=$(printf '%s' "$line" | grep -o '"timestamp":"[^"]*"' | head -1 | sed 's/.*:"\([^"]*\)".*/\1/')
      [ -n "$ts" ] && [ "${ts%%T*}" \> "$SINCE" -o "${ts%%T*}" = "$SINCE" ] && printf '%s\n' "$line"
    done < "$LOG_FILE"
  else
    grep -v '^[[:space:]]*$' "$LOG_FILE"
  fi
}

models="$(rows | grep -o '"model":"[^"]*"' | sed 's/"model":"\([^"]*\)"/\1/')"
total="$(printf '%s\n' "$models" | grep -c . || true)"

if [ "${total:-0}" -eq 0 ]; then echo "No sessions in range."; exit 0; fi

echo ""
echo "  Claude Code Routing Report"
[ -n "$SINCE" ] && echo "  Since: $SINCE"
echo "  Total sessions: $total"
echo ""
printf "  %-28s %6s %8s\n" "Model" "Count" "Share"
printf "  %s\n" "--------------------------------------------"
printf '%s\n' "$models" | sort | uniq -c | sort -rn | while read -r count name; do
  pct="$(awk "BEGIN{printf \"%.1f\", 100*$count/$total}")"
  printf "  %-28s %6s %7s%%\n" "$name" "$count" "$pct"
done

# Weighted cost vs all-Opus baseline
actual="$(printf '%s\n' "$models" | awk -v o="$OPUS_W" -v s="$SONNET_W" -v h="$HAIKU_W" '
  /opus/{a+=o; next} /sonnet/{a+=s; next} /haiku/{a+=h; next} {a+=o} END{printf "%.4f", a}')"
baseline="$(awk "BEGIN{printf \"%.4f\", $total*$OPUS_W}")"
pct_of="$(awk "BEGIN{printf \"%.1f\", 100*$actual/$baseline}")"
saving="$(awk "BEGIN{printf \"%.1f\", 100*($baseline-$actual)/$baseline}")"

echo ""
echo "  Relative cost vs all-Opus baseline: ${pct_of}% of baseline"
echo "  Estimated saving from routing:      ${saving}%"
echo ""
echo "  (Weights are planning estimates — pass --opus/--sonnet/--haiku to match current pricing.)"
echo ""
