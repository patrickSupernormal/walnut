#!/bin/bash
# Hook: Context Watch — UserPromptSubmit
# Two jobs:
# 1. Context % re-injection — at every 20% threshold, re-inject rules + context
# 2. External change detection — if another session modified walnut state files

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/alive-common.sh"

read_hook_input
find_world || exit 0

SESSION_ID="${HOOK_SESSION_ID}"
[ -z "$SESSION_ID" ] && exit 0

# ── CONTEXT % RE-INJECTION ──────────────────────────────────────

CTX_FILE="$WORLD_ROOT/.alive/.context_pct"
if [ -f "$CTX_FILE" ]; then
  CTX_PCT=$(cat "$CTX_FILE" 2>/dev/null | tr -d '[:space:]')

  if [ -n "$CTX_PCT" ] && [ "$CTX_PCT" -gt 0 ] 2>/dev/null; then
    # Check each 20% threshold — fire once per session per threshold
    for THRESHOLD in 20 40 60 80; do
      MARKER="/tmp/alive-ctx-${SESSION_ID}-${THRESHOLD}"
      if [ "$CTX_PCT" -ge "$THRESHOLD" ] && [ ! -f "$MARKER" ]; then
        touch "$MARKER"

        # Build injection content based on threshold level
        if [ "$THRESHOLD" -le 40 ]; then
          # Condensed refresh
          REFRESH="<ALIVE_REFRESH threshold=\"${THRESHOLD}%\">
Context is at ${CTX_PCT}%. Refreshing core behaviours:
- Stash decisions, tasks, and notes. Surface on change.
- Verify past context via subagent before asserting. Never guess from memory.
- Capsule awareness: deliverable or future audience = capsule. Prefer capsules over loose files.
- Read before speaking. Never answer from memory about file contents.
- Check the world key (injected at start) for walnut registry, people, credentials.
</ALIVE_REFRESH>"
        else
          # Full re-injection at 60%+ — read world key and index
          WORLD_KEY=""
          [ -f "$WORLD_ROOT/.alive/key.md" ] && WORLD_KEY=$(cat "$WORLD_ROOT/.alive/key.md")
          WORLD_INDEX=""
          [ -f "$WORLD_ROOT/.alive/_index.yaml" ] && WORLD_INDEX=$(cat "$WORLD_ROOT/.alive/_index.yaml")

          REFRESH="<ALIVE_REFRESH threshold=\"${THRESHOLD}%\">
Context is at ${CTX_PCT}%. Full context refresh:
- Stash decisions, tasks, and notes. Surface on change.
- Verify past context via subagent before asserting. Never guess from memory.
- Capsule awareness: deliverable or future audience = capsule.
- Read before speaking. Never answer from memory about file contents.

World Key:
${WORLD_KEY}

World Index:
${WORLD_INDEX}
</ALIVE_REFRESH>"
        fi

        # Scan active squirrel stashes for cross-pollination
        ACTIVE_STASHES=""
        if command -v python3 &>/dev/null; then
          ACTIVE_STASHES=$(python3 -c "
import os, glob, re
sid = '$SESSION_ID'
squirrels = glob.glob('$WORLD_ROOT/.alive/_squirrels/*.yaml')
for f in squirrels:
    with open(f) as fh:
        content = fh.read()
    # Skip our own session
    if sid in content:
        continue
    # Check if ended: null (still active)
    if 'ended: null' not in content:
        continue
    # Extract walnut and stash
    walnut = ''
    m = re.search(r'^walnut:\s*(.+)', content, re.M)
    if m:
        walnut = m.group(1).strip()
    if walnut == 'null' or not walnut:
        continue
    # Extract stash items
    stash_items = re.findall(r'content:\s*\"?(.+?)\"?\s*$', content, re.M)
    if stash_items:
        print(f'Active session on {walnut}: ' + '; '.join(stash_items[:5]))
" 2>/dev/null || true)
        fi

        if [ -n "$ACTIVE_STASHES" ]; then
          REFRESH="${REFRESH}

<ACTIVE_SQUIRRELS>
${ACTIVE_STASHES}
</ACTIVE_SQUIRRELS>"
        fi

        REFRESH_ESCAPED=$(escape_for_json "$REFRESH")

        cat <<REFRESHEOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "${REFRESH_ESCAPED}"
  }
}
REFRESHEOF
        exit 0
      fi
    done
  fi
fi

# ── EXTERNAL CHANGE DETECTION ───────────────────────────────────

# Find which walnut this session is working on
SQUIRRELS_DIR="$WORLD_ROOT/.alive/_squirrels"
ENTRY="$SQUIRRELS_DIR/$SESSION_ID.yaml"
[ ! -f "$ENTRY" ] && exit 0

WALNUT=$(grep '^walnut:' "$ENTRY" 2>/dev/null | sed 's/walnut: *//' || true)
[ -z "${WALNUT:-}" ] || [ "$WALNUT" = "null" ] && exit 0

# Find walnut's state files directory — check _core/ first, fall back to walnut root
WALNUT_DIR=$(find "$WORLD_ROOT" -path "*/01_Archive" -prune -o -type d -name "$WALNUT" -print -quit 2>/dev/null || true)
[ -z "${WALNUT_DIR:-}" ] || [ ! -d "$WALNUT_DIR" ] && exit 0

if [ -d "$WALNUT_DIR/_core" ]; then
  WALNUT_CORE="$WALNUT_DIR/_core"
else
  WALNUT_CORE="$WALNUT_DIR"
fi

# Timestamp file tracks when this session last checked
LASTCHECK="/tmp/alive-lastcheck-${SESSION_ID}"

# On first run, just create the timestamp and exit
if [ ! -f "$LASTCHECK" ]; then
  date +%s > "$LASTCHECK"
  exit 0
fi

LAST_CHECK_TIME=$(cat "$LASTCHECK" 2>/dev/null || echo "0")

# Check if now.md or log.md were modified after our last check
CHANGED=""
for file in "$WALNUT_CORE/now.md" "$WALNUT_CORE/log.md" "$WALNUT_CORE/tasks.md"; do
  if [ -f "$file" ]; then
    # Get file mtime as epoch seconds
    if stat --version >/dev/null 2>&1; then
      MTIME=$(stat -c %Y "$file" 2>/dev/null || echo "0")
    else
      MTIME=$(stat -f %m "$file" 2>/dev/null || echo "0")
    fi
    if [ "$MTIME" -gt "$LAST_CHECK_TIME" ] 2>/dev/null; then
      CHANGED="${CHANGED} $(basename "$file")"
    fi
  fi
done

# Update timestamp
date +%s > "$LASTCHECK"

# If nothing changed, exit silently
[ -z "${CHANGED:-}" ] && exit 0

# Check if the change was made by US (same session_id in now.md squirrel field)
LAST_SQUIRREL=$(grep '^squirrel:' "$WALNUT_CORE/now.md" 2>/dev/null | sed 's/squirrel: *//' || true)
if [ "${LAST_SQUIRREL:-}" = "$SESSION_ID" ]; then
  exit 0
fi

# Another session modified the walnut — notify
jq -n --arg files "$CHANGED" --arg walnut "$WALNUT" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ("Another session just saved to " + $walnut + ". Changed:" + $files + ". You should re-read _core/now.md, _core/tasks.md and _core/log.md before continuing — your context may be stale. Ask the human if they want you to refresh.")
  }
}'
exit 0
