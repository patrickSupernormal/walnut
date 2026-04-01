#!/bin/bash
# Hook: Relay Check -- SessionStart (startup)
# Probes the GitHub relay for pending .walnut packages and injects a
# notification into the session. Silent when no relay configured or no
# pending packages. Exits 0 on ANY error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/alive-common.sh"

# Read stdin JSON -- extracts session_id, cwd, event name
read_hook_input

# Find world root (needed for alive-common.sh contract, though relay
# config lives at $HOME/.alive/relay/ not under the world)
find_world || exit 0

# Fast path: no relay configured -- exit immediately
RELAY_DIR="$HOME/.alive/relay"
RELAY_CONFIG="$RELAY_DIR/relay.json"
[ -f "$RELAY_CONFIG" ] || exit 0

# Resolve relay-probe.py location
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$SCRIPT_DIR/../.." && pwd)}"
PROBE_SCRIPT="$PLUGIN_ROOT/scripts/relay-probe.py"
[ -f "$PROBE_SCRIPT" ] || exit 0

# Run probe -- writes state.json atomically. Errors are swallowed by
# relay-probe.py internally (it always exits 0).
STATE_JSON="$RELAY_DIR/state.json"
python3 "$PROBE_SCRIPT" --config "$RELAY_CONFIG" --state "$STATE_JSON" 2>/dev/null || exit 0

# Read pending_packages from state.json via inline python3
# (json_field reads HOOK_INPUT, not arbitrary files)
PENDING=$(python3 -c "
import json, sys
try:
    with open('$STATE_JSON') as f:
        print(json.load(f).get('pending_packages', 0))
except Exception:
    print(0)
" 2>/dev/null || echo 0)

# Silent exit if nothing pending
[ "$PENDING" -gt 0 ] 2>/dev/null || exit 0

# Build notification
MSG="You have ${PENDING} walnut package(s) waiting. Run /alive:receive to import."
ESCAPED=$(escape_for_json "$MSG")

cat <<HOOKEOF
{
  "additional_context": "${ESCAPED}",
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "${ESCAPED}"
  }
}
HOOKEOF

exit 0
