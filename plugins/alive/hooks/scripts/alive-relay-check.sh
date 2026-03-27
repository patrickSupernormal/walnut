#!/bin/bash
# Hook: Relay Check — SessionStart (startup + resume)
# Checks the relay repo for new packages and injects a notification.
# Fast exit (<100ms) when no relay configured. Network failures are silent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/alive-common.sh"

# Read stdin JSON
read_hook_input

# Find world root — exit silently if none
if ! find_world; then
  exit 0
fi

RELAY_CONFIG="$WORLD_ROOT/.alive/relay.yaml"

# Fast exit if no relay configured
if [ ! -f "$RELAY_CONFIG" ]; then
  exit 0
fi

# Parse relay.yaml with grep — no PyYAML dependency needed
# Extract repo (owner/name format) and last_commit SHA
RELAY_REPO=$(grep '^ *repo:' "$RELAY_CONFIG" | head -1 | sed 's/^.*repo: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
LAST_COMMIT=$(grep '^ *last_commit:' "$RELAY_CONFIG" | head -1 | sed 's/^.*last_commit: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
GITHUB_USERNAME=$(grep '^ *github_username:' "$RELAY_CONFIG" | head -1 | sed 's/^.*github_username: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
RELAY_LOCAL=$(grep '^ *local:' "$RELAY_CONFIG" | head -1 | sed 's/^.*local: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')

# Need a repo to check
if [ -z "$RELAY_REPO" ]; then
  exit 0
fi

# Build the remote URL
REMOTE_URL="https://github.com/${RELAY_REPO}.git"

# Resolve local clone path (relative to world root)
if [ -n "$RELAY_LOCAL" ]; then
  CLONE_DIR="$WORLD_ROOT/$RELAY_LOCAL"
else
  CLONE_DIR="$WORLD_ROOT/.alive/relay/"
fi

# git ls-remote with 5-second hard timeout — silent on network failure
# Use `timeout` (Linux/coreutils) or `gtimeout` (Homebrew) if available,
# otherwise fall back to a background process with kill timer (portable macOS).
run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout &>/dev/null; then
    timeout "$secs" "$@" 2>/dev/null
  elif command -v gtimeout &>/dev/null; then
    gtimeout "$secs" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null &
    local pid=$!
    ( sleep "$secs"; kill "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local ret=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $ret
  fi
}

REMOTE_HEAD=$(run_with_timeout 5 git ls-remote "$REMOTE_URL" HEAD | awk '{print $1}' | head -1)

# Network failure or timeout — exit silently
if [ -z "$REMOTE_HEAD" ]; then
  exit 0
fi

# No new commits — exit silently
if [ "$REMOTE_HEAD" = "$LAST_COMMIT" ]; then
  exit 0
fi

# New commits detected — fetch in the sparse clone
if [ -d "$CLONE_DIR/.git" ]; then
  (cd "$CLONE_DIR" && git fetch --quiet 2>/dev/null && git reset --hard origin/main --quiet 2>/dev/null) || true
fi

# Count .walnut files in own inbox
INBOX_DIR="$CLONE_DIR/inbox/${GITHUB_USERNAME}"
PACKAGE_COUNT=0
if [ -d "$INBOX_DIR" ]; then
  PACKAGE_COUNT=$(find "$INBOX_DIR" -name "*.walnut" -type f 2>/dev/null | wc -l | tr -d ' ')
fi

# Portable sed -i (macOS vs GNU)
sed_inplace() {
  if sed --version >/dev/null 2>&1; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

# Update last-seen commit SHA in relay.yaml
if [ -n "$LAST_COMMIT" ]; then
  sed_inplace "s/last_commit: *\"*${LAST_COMMIT}\"*/last_commit: \"${REMOTE_HEAD}\"/" "$RELAY_CONFIG" 2>/dev/null || true
else
  # No last_commit yet — insert it after last_sync line
  sed_inplace "/last_sync:/a\\
\\  last_commit: \"${REMOTE_HEAD}\"" "$RELAY_CONFIG" 2>/dev/null || true
fi

# Update last_sync timestamp
SYNC_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
if grep -q 'last_sync:' "$RELAY_CONFIG" 2>/dev/null; then
  sed_inplace "s/last_sync: *\"*[^\"]*\"*/last_sync: \"${SYNC_TIMESTAMP}\"/" "$RELAY_CONFIG" 2>/dev/null || true
fi

# No packages — exit silently (but SHA was updated)
if [ "$PACKAGE_COUNT" -eq 0 ]; then
  exit 0
fi

# Build notification
if [ "$PACKAGE_COUNT" -eq 1 ]; then
  NOTIFICATION="You have 1 walnut package waiting on the relay. Run /alive:relay pull or /alive:receive to import it."
else
  NOTIFICATION="You have ${PACKAGE_COUNT} walnut package(s) waiting on the relay. Run /alive:relay pull or /alive:receive to import them."
fi

ESCAPED=$(escape_for_json "$NOTIFICATION")

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
