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
# Extract repo (owner/name format), last_commit SHA, github_username, local clone path
RELAY_REPO=$(grep '^ *repo:' "$RELAY_CONFIG" | head -1 | sed 's/^.*repo: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
LAST_COMMIT=$(grep '^ *last_commit:' "$RELAY_CONFIG" | head -1 | sed 's/^.*last_commit: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
GITHUB_USERNAME=$(grep '^ *github_username:' "$RELAY_CONFIG" | head -1 | sed 's/^.*github_username: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
RELAY_LOCAL=$(grep '^ *local:' "$RELAY_CONFIG" | head -1 | sed 's/^.*local: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')

# Need repo and username to proceed
if [ -z "$RELAY_REPO" ] || [ -z "$GITHUB_USERNAME" ]; then
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

# Prevent git from prompting for credentials (would hang the hook)
export GIT_TERMINAL_PROMPT=0

# git ls-remote with 5-second hard timeout — silent on network failure.
# Tries: timeout (Linux/coreutils), gtimeout (Homebrew), then perl alarm fallback.
# The perl fallback sends SIGKILL to the process group for a hard ceiling.
if command -v timeout &>/dev/null; then
  REMOTE_HEAD=$(timeout 5 git ls-remote "$REMOTE_URL" HEAD 2>/dev/null | awk '{print $1}' | head -1)
elif command -v gtimeout &>/dev/null; then
  REMOTE_HEAD=$(gtimeout 5 git ls-remote "$REMOTE_URL" HEAD 2>/dev/null | awk '{print $1}' | head -1)
else
  # Perl alarm fallback — kills entire process group on timeout (hard ceiling)
  REMOTE_HEAD=$(perl -e '
    use POSIX ":sys_wait_h";
    $SIG{ALRM} = sub { kill 9, -$$; exit 124 };
    alarm(5);
    my $pid = open(my $fh, "-|", "git", "ls-remote", $ARGV[0], "HEAD") or exit 1;
    my $line = <$fh>;
    close $fh;
    alarm(0);
    if ($line && $line =~ /^([0-9a-f]+)/) { print $1 }
  ' "$REMOTE_URL" 2>/dev/null)
fi

# Network failure or timeout — exit silently
if [ -z "$REMOTE_HEAD" ]; then
  exit 0
fi

# No new commits — exit silently
if [ "$REMOTE_HEAD" = "$LAST_COMMIT" ]; then
  exit 0
fi

# New commits detected — fetch and reset to the exact remote HEAD in the sparse clone.
# Only update relay.yaml if the clone was successfully updated.
CLONE_UPDATED=false
if [ -d "$CLONE_DIR/.git" ]; then
  if (cd "$CLONE_DIR" && git fetch --quiet 2>/dev/null && git reset --hard "$REMOTE_HEAD" --quiet 2>/dev/null); then
    CLONE_UPDATED=true
  fi
fi

# If clone update failed (or clone doesn't exist), don't update last_commit.
# This ensures the next session re-attempts the fetch rather than silently
# acknowledging commits we never actually pulled.
if [ "$CLONE_UPDATED" != "true" ]; then
  exit 0
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

# Update last-seen commit SHA in relay.yaml (only reached if clone updated successfully)
if grep -q 'last_commit:' "$RELAY_CONFIG" 2>/dev/null; then
  sed_inplace "s/last_commit: *\"*[^\"]*\"*/last_commit: \"${REMOTE_HEAD}\"/" "$RELAY_CONFIG" 2>/dev/null || true
else
  # No last_commit line yet — use python3 to insert it safely (avoids sed append portability issues)
  python3 -c "
import sys
config = sys.argv[1]
sha = sys.argv[2]
with open(config) as f:
    lines = f.readlines()
out = []
for line in lines:
    out.append(line)
    if line.strip().startswith('last_sync:'):
        out.append('  last_commit: \"' + sha + '\"\n')
with open(config, 'w') as f:
    f.writelines(out)
" "$RELAY_CONFIG" "$REMOTE_HEAD" 2>/dev/null || true
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
