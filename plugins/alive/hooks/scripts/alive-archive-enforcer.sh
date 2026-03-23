#!/bin/bash
# Hook: Archive Enforcer — PreToolUse (Bash)
# Blocks rm/rmdir/unlink when targeting files inside the ALIVE world.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/alive-common.sh"

read_hook_input
find_world || exit 0

COMMAND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // empty')

# Check for destructive commands
if ! echo "$COMMAND" | grep -qE '(^|\s|;|&&|\|)(rm|rmdir|unlink)\s'; then
  exit 0
fi

# Extract target paths after the rm/rmdir/unlink command
TARGET=$(echo "$COMMAND" | sed -E 's/.*\b(rm|rmdir|unlink)\s+(-[^ ]+ )*//' | tr ' ' '\n' | grep -v '^-')

# Use cwd from JSON input for resolving relative paths
RESOLVE_DIR="${HOOK_CWD:-$PWD}"

while IFS= read -r path; do
  [ -z "$path" ] && continue

  # Resolve relative paths against the session's cwd
  if [[ "$path" != /* ]]; then
    resolved="$RESOLVE_DIR/$path"
  else
    resolved="$path"
  fi

  # Check if resolved path is inside the World (protect entire root, not just subdirs)
  case "$resolved" in
    "$WORLD_ROOT"|"$WORLD_ROOT"/*)
      # Rename to (Marked for Deletion) instead of blocking
      if [ -e "$resolved" ]; then
        DIRNAME=$(dirname "$resolved")
        BASENAME=$(basename "$resolved")
        MARKED="${DIRNAME}/${BASENAME} (Marked for Deletion)"
        python3 -c "import os,sys; os.rename(sys.argv[1], sys.argv[2])" "$resolved" "$MARKED" 2>/dev/null || true
        open "$DIRNAME" 2>/dev/null || true
        REASON="Renamed to (Marked for Deletion). Review in Finder and delete manually if intended."
      else
        REASON="Deletion blocked inside ALIVE world. File not found at path — may already be removed."
      fi
      REASON_ESCAPED=$(echo "$REASON" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))" 2>/dev/null || echo "\"Deletion blocked inside ALIVE world.\"")
      echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":${REASON_ESCAPED}}}"
      exit 0
      ;;
  esac
done <<< "$TARGET"

exit 0
