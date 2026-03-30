---
description: "Set up and manage a private GitHub relay for automatic .walnut package delivery between peers. Handles relay creation (private repo + RSA keypair), peer invitations, invitation acceptance, and status. The transport layer for P2P sharing -- extends alive:share and alive:receive with push/pull."
user-invocable: true
---

# Relay

Private inbox relay for automatic .walnut package delivery. Each person owns their own relay repo on GitHub. Others push to it via the Contents API. You pull from it via a local sparse clone.

No daemon. No server. Just a private GitHub repo as a mailbox, RSA encryption for confidentiality, and `gh` CLI for everything.

**Encryption model (epic decision #4/#5):** RSA-4096 keypairs generated during setup. Public keys exchanged via relay repos. Encryption is automatic -- no passphrases needed for relay transport. Passphrase mode remains available for manual shares only (via alive:share).

---

## Subcommands

Four subcommands. If invoked without one, show the menu:

```
╭─ 🐿️ relay
│
│  ▸ What do you need?
│  1. Setup -- create your relay
│  2. Peer add -- invite someone
│  3. Peer accept -- accept an invitation
│  4. Status -- show relay state
╰─
```

---

## Prerequisites (every subcommand)

### World root discovery

Before any relay operation, discover the world root. Walk up from the current working directory looking for the ALIVE folder structure (`01_Archive/`, `02_Life/`, etc.) or the `.alive/` directory:

```bash
WORLD_ROOT=""
CHECK_DIR="$(pwd)"
while [ "$CHECK_DIR" != "/" ]; do
  if [ -d "$CHECK_DIR/.alive" ] || [ -d "$CHECK_DIR/01_Archive" ]; then
    WORLD_ROOT="$CHECK_DIR"
    break
  fi
  CHECK_DIR="$(dirname "$CHECK_DIR")"
done

if [ -z "$WORLD_ROOT" ]; then
  echo "NO_WORLD_ROOT"
else
  echo "WORLD_ROOT=$WORLD_ROOT"
fi
```

If no world root found:

```
╭─ 🐿️ no world found
│
│  Can't find the ALIVE world root.
│  Run this from inside your world directory.
╰─
```

**All paths in this skill are relative to `$WORLD_ROOT`.** After discovering the world root, `cd "$WORLD_ROOT"` before proceeding.

### GitHub CLI check

```bash
command -v gh >/dev/null 2>&1 && echo "GH_FOUND" || echo "GH_MISSING"
```

If `gh` is not installed:

```
╭─ 🐿️ gh not found
│
│  The GitHub CLI is required for relay operations.
│  Install: brew install gh (macOS) or https://cli.github.com/
╰─
```

### GitHub auth check

```bash
gh auth status 2>&1
```

If the exit code is non-zero:

```
╭─ 🐿️ gh auth required
│
│  The GitHub CLI isn't authenticated. Run this in your terminal:
│
│  gh auth login --web
│
│  Then come back and try again.
╰─
```

Do not proceed until `gh auth status` succeeds. After authentication, run `gh auth setup-git` to configure the credential helper for git operations.

### GitHub username discovery

```bash
gh api user --jq '.login'
```

Store this as `GITHUB_USERNAME` for use throughout the skill.

### Network check

If `gh api user` fails with a connection error (not an auth error), the machine is offline:

```
╭─ 🐿️ offline
│
│  Can't reach GitHub. Try again when online.
╰─
```

---

## /alive:relay setup

One-time relay initialization. Creates the private GitHub repo, generates an RSA-4096 keypair, commits the public key, configures sparse checkout, and writes `.alive/relay.yaml`.

### Step 1 -- Check for existing relay

```bash
test -f "$WORLD_ROOT/.alive/relay.yaml" && echo "EXISTS" || echo "NEW"
```

If a relay.yaml already exists:

```
╭─ 🐿️ relay already configured
│
│  Relay: <repo> (local clone at <local-path>)
│  Peers: <count>
│
│  ▸ What to do?
│  1. Show status -- /alive:relay status
│  2. Reconfigure -- wipe and start fresh
│  3. Cancel
╰─
```

If "Reconfigure":

```
╭─ 🐿️ confirm reconfigure
│
│  This will delete your local keypair and relay config.
│  Existing peers will lose push access until re-invited.
│  The relay repo on GitHub will NOT be deleted.
│
│  ▸ Proceed?
│  1. Yes -- wipe local config and reconfigure
│  2. Cancel
╰─
```

### Step 2 -- Confirm repo creation

This creates a public-facing resource on GitHub. Confirm before proceeding:

```
╭─ 🐿️ create relay repo
│
│  This will create a private repo: <username>/walnut-relay
│  on your GitHub account.
│
│  ▸ Proceed?
│  1. Yes -- create the repo
│  2. Cancel
╰─
```

After confirmation, create the repo:

```bash
gh repo create walnut-relay --private --confirm \
  --description "Walnut P2P relay inbox" 2>&1
```

If the repo already exists (exit code non-zero, message contains "already exists"), offer to reuse it:

```
╭─ 🐿️ repo exists
│
│  walnut-relay already exists on your GitHub account.
│
│  ▸ Reuse it?
│  1. Yes -- configure as relay
│  2. Cancel
╰─
```

Then clone with sparse checkout (whether newly created or reused):

```bash
RELAY_CLONE_DIR="$WORLD_ROOT/.alive/relay"
mkdir -p "$(dirname "$RELAY_CLONE_DIR")"

git clone --filter=blob:none --sparse \
  "https://github.com/$GITHUB_USERNAME/walnut-relay.git" \
  "$RELAY_CLONE_DIR" 2>&1
```

### Step 3 -- Generate RSA-4096 keypair

Generate the keypair using openssl (zero dependencies, pre-installed on macOS and Linux):

```bash
RELAY_KEYS_DIR="$WORLD_ROOT/.alive/relay-keys"
mkdir -p "$RELAY_KEYS_DIR"

# Generate private key (stays local, never committed)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out "$RELAY_KEYS_DIR/private.pem" 2>&1

# Extract public key
openssl rsa -in "$RELAY_KEYS_DIR/private.pem" -pubout \
  -out "$RELAY_KEYS_DIR/public.pem" 2>&1

# Lock down private key permissions
chmod 600 "$RELAY_KEYS_DIR/private.pem"
chmod 644 "$RELAY_KEYS_DIR/public.pem"
```

Verify private key permissions (portable check):

```bash
# Works on both macOS and Linux
ls -l "$RELAY_KEYS_DIR/private.pem" | awk '{print $1}'
```

If the output does not start with `-rw-------`, warn:

```
╭─ 🐿️ heads up
│
│  Private key permissions are too open. Should be 600 (owner read/write only).
│  Run: chmod 600 .alive/relay-keys/private.pem
╰─
```

### Step 4 -- Configure sparse checkout

Configure the clone for sparse checkout. Only the human's own inbox and the `keys/` directory are checked out locally:

```bash
cd "$RELAY_CLONE_DIR" && \
  git sparse-checkout init --cone && \
  git sparse-checkout set "inbox/$GITHUB_USERNAME" "keys" 2>&1
```

### Step 5 -- Commit initial structure to relay repo

Push the public key and initial README:

```bash
cd "$RELAY_CLONE_DIR"

# Create directory structure
mkdir -p "keys" "inbox/$GITHUB_USERNAME"

# Copy public key into keys/
cp "$WORLD_ROOT/.alive/relay-keys/public.pem" "keys/$GITHUB_USERNAME.pem"

# Create README
cat > README.md << 'READMEEOF'
# walnut-relay

Private inbox relay for Walnut P2P sharing.

This repo is managed by the ALIVE plugin. Do not edit manually.

## Structure

```
keys/           Public keys for relay participants
inbox/<user>/   Incoming .walnut packages for each participant
```
READMEEOF

# Create .gitkeep for inbox with non-empty content
printf 'Inbox for %s\n' "$GITHUB_USERNAME" > "inbox/$GITHUB_USERNAME/.gitkeep"

# Detect default branch name
BRANCH=$(git branch --show-current 2>/dev/null)
if [ -z "$BRANCH" ]; then
  BRANCH="main"
fi

# Commit and push
git add -A
git commit -m "Initialize walnut relay"
git push -u origin "$BRANCH" 2>&1
```

### Step 6 -- Write .alive/relay.yaml

Write the relay configuration using Python to avoid shell quoting issues:

```bash
python3 - "$WORLD_ROOT" "$GITHUB_USERNAME" << 'PYEOF'
import sys, datetime, subprocess, os

world_root = sys.argv[1]
username = sys.argv[2]
repo_dir = os.path.join(world_root, ".alive", "relay")

# Get current commit hash
commit = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=repo_dir
).decode().strip()

now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

yaml_content = f"""relay:
  repo: "{username}/walnut-relay"
  local: ".alive/relay/"
  github_username: "{username}"
  private_key: ".alive/relay-keys/private.pem"
  public_key: ".alive/relay-keys/public.pem"
  last_sync: "{now}"
  last_commit: "{commit}"
peers: []
"""

config_path = os.path.join(world_root, ".alive", "relay.yaml")
with open(config_path, "w") as f:
    f.write(yaml_content)

print(f"Written: {config_path}")
PYEOF
```

### Step 7 -- Confirm

```
╭─ 🐿️ relay ready
│
│  Repo:        <username>/walnut-relay (private)
│  Local clone: .alive/relay/
│  Keypair:     RSA-4096 (public key committed to relay)
│  Sparse:      inbox/<username>/ + keys/
│
│  Your relay is live. Add peers with /alive:relay peer add <github-username>.
╰─
```

Stash the setup event:

```
╭─ 🐿️ +1 stash (N)
│  Relay created: <username>/walnut-relay
│  → drop?
╰─
```

---

## /alive:relay peer add <github-username>

Invite a peer to push packages to your relay. Creates or updates their person walnut.

### Step 1 -- Validate relay exists

```bash
test -f "$WORLD_ROOT/.alive/relay.yaml" && echo "CONFIGURED" || echo "NOT_CONFIGURED"
```

If not configured:

```
╭─ 🐿️ no relay
│
│  Set up your relay first: /alive:relay setup
╰─
```

### Step 2 -- Parse the github username argument

If no argument was provided, ask:

```
╭─ 🐿️ peer add
│
│  ▸ GitHub username of the peer?
╰─
```

**Username validation:** Sanitize the input -- GitHub usernames contain only alphanumeric characters and hyphens, 1-39 characters long, cannot start/end with a hyphen:

```bash
python3 -c "
import sys, re
username = sys.argv[1]
if re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?', username):
    print('VALID')
else:
    print('INVALID')
" "$PEER_USERNAME"
```

If invalid, ask again with guidance.

Verify the username exists on GitHub:

```bash
gh api "users/$PEER_USERNAME" --jq '.login' 2>&1
```

If the API returns an error:

```
╭─ 🐿️ unknown user
│
│  GitHub user "<peer-username>" not found. Check the spelling.
╰─
```

### Step 3 -- Check for duplicate peer

Read `.alive/relay.yaml` and check if a peer with this github username already exists. Pass values via sys.argv to avoid shell injection:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$PEER_USERNAME" << 'PYEOF'
import sys

config_path = sys.argv[1]
peer_username = sys.argv[2]

with open(config_path) as f:
    text = f.read().lower()

# Normalize both sides to lowercase for comparison
peer_username = peer_username.lower()

# Check for the peer in the YAML (simple text scan)
# Look for github: followed by the username on the same line
# Matches both list items (- github:) and continuation (github:) forms
import re
pattern = re.compile(r'^\s*-?\s*github:\s*["\']?' + re.escape(peer_username) + r'["\']?\s*$', re.MULTILINE)
if pattern.search(text):
    print("DUPLICATE")
else:
    print("NEW")
PYEOF
```

If duplicate:

```
╭─ 🐿️ already a peer
│
│  <peer-username> is already in your peer list (status: <status>).
│
│  ▸ What to do?
│  1. Re-invite -- send a fresh collaboration invite
│  2. Cancel
╰─
```

### Step 4 -- Confirm and invite as collaborator

Inviting a collaborator is an external action. Confirm first:

```
╭─ 🐿️ invite collaborator
│
│  This will send a GitHub collaborator invitation to <peer-username>
│  for your relay repo (<username>/walnut-relay).
│  They'll get push access to the repo.
│
│  ▸ Proceed?
│  1. Yes -- send the invite
│  2. Cancel
╰─
```

After confirmation:

```bash
gh api "repos/$GITHUB_USERNAME/walnut-relay/collaborators/$PEER_USERNAME" \
  -X PUT -f permission=push 2>&1
```

**Rate limit note:** GitHub limits collaborator invitations to 50 per 24 hours. If the API returns a rate limit error:

```
╭─ 🐿️ rate limited
│
│  GitHub limits collaborator invites to 50 per day.
│  Try again later, or share a .walnut package manually.
╰─
```

### Step 5 -- Ask for peer's display name

```
╭─ 🐿️ peer info
│
│  ▸ What's their name? (for the person walnut -- e.g. "Ben Flint")
╰─
```

### Step 6 -- Derive peer slug

Convert the display name to a walnut-compatible slug (kebab-case, lowercase, alphanumeric + hyphens):

```bash
PEER_SLUG=$(python3 -c "
import sys, re, unicodedata
name = sys.argv[1]
# Normalize unicode, strip accents
name = unicodedata.normalize('NFKD', name).encode('ascii', 'ignore').decode()
# Lowercase, replace non-alnum with hyphens, collapse runs, strip edges
slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
print(slug)
" "$PEER_NAME")
echo "PEER_SLUG=$PEER_SLUG"
```

### Step 7 -- Create inbox directory for the peer

Create the peer's inbox via the GitHub Contents API (avoids sparse checkout conflicts -- the local clone only checks out own inbox + keys):

```bash
# Use a non-empty placeholder to avoid empty-content API issues
GITKEEP_CONTENT=$(printf 'Inbox for %s\n' "$PEER_USERNAME" | base64 | tr -d '\n')
gh api "repos/$GITHUB_USERNAME/walnut-relay/contents/inbox/$PEER_USERNAME/.gitkeep" \
  -X PUT \
  -f message="Add inbox for $PEER_USERNAME" \
  -f content="$GITKEEP_CONTENT" 2>&1
```

Then pull the latest into the local clone:

```bash
cd "$WORLD_ROOT/.alive/relay" && git pull --quiet 2>&1
```

### Step 8 -- Update .alive/relay.yaml

Append the new peer to the `peers:` list. All values passed via sys.argv to prevent injection. Name is sanitized to a single-line YAML-safe string:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$PEER_USERNAME" "$PEER_NAME" "$PEER_SLUG" << 'PYEOF'
import sys, datetime, re

config_path = sys.argv[1]
peer_github = sys.argv[2]
peer_name = sys.argv[3]
peer_slug = sys.argv[4]
today = datetime.date.today().isoformat()

# Sanitize name: single line, escape quotes, strip control chars
safe_name = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', peer_name)
safe_name = safe_name.replace('\\', '\\\\').replace('"', '\\"')
safe_name = safe_name.strip()[:100]  # Cap length

peer_entry = (
    f'  - github: "{peer_github}"\n'
    f'    name: "{safe_name}"\n'
    f'    relay: "{peer_github}/walnut-relay"\n'
    f'    person_walnut: "02_Life/people/{peer_slug}"\n'
    f'    added: "{today}"\n'
    f'    status: "pending"'
)

with open(config_path) as f:
    text = f.read()

if "peers: []" in text:
    text = text.replace("peers: []", "peers:\n" + peer_entry)
else:
    # Ensure clean separation from existing entries
    text = text.rstrip() + "\n" + peer_entry + "\n"

with open(config_path, "w") as f:
    f.write(text)

print("UPDATED")
PYEOF
```

### Step 9 -- Create or update person walnut

Check if a person walnut exists for this peer:

```bash
find "$WORLD_ROOT/02_Life/people" -name "key.md" -path "*/_core/key.md" 2>/dev/null | \
  while read f; do
    dir=$(dirname "$(dirname "$f")")
    echo "$dir"
  done
```

Search for a matching walnut by name or github username. If found, update `key.md` frontmatter to add `github:` and `relay:` fields using the Edit tool. If not found, create a minimal person walnut at `$WORLD_ROOT/02_Life/people/<peer-slug>/`:

```
02_Life/people/<peer-slug>/
  _core/
    key.md
    now.md
    log.md
    insights.md
    tasks.md
```

The person walnut's `key.md` frontmatter includes:

```yaml
---
type: person
goal: "<peer-name>"
created: <today>
github: "<peer-username>"
relay: "<peer-username>/walnut-relay"
tags: [person, relay-peer]
links: []
---
```

### Step 10 -- Confirm

```
╭─ 🐿️ peer invited
│
│  Invited <peer-name> (<peer-username>) as collaborator.
│  Status: pending (they need to accept the invite)
│
│  Tell them to run /alive:relay peer accept to join.
│  Or share a .walnut package manually -- the relay: field
│  in the manifest will prompt them to connect.
╰─
```

Stash the event:

```
╭─ 🐿️ +1 stash (N)
│  Added relay peer: <peer-name> (<peer-username>) -- invite pending
│  → drop?
╰─
```

---

## /alive:relay peer accept

Accept a pending relay invitation from another peer. For the joining side of the connection.

### Step 1 -- Check for pending invitations

```bash
gh api /user/repository_invitations --jq '
  [.[] | select(.repository.name == "walnut-relay") |
   {id: .id, owner: .repository.owner.login, repo: .repository.full_name}]
' 2>&1
```

If no relay invitations found:

```
╭─ 🐿️ no invitations
│
│  No pending walnut-relay invitations found.
│  Ask the person who wants to share with you to run:
│  /alive:relay peer add <your-github-username>
╰─
```

If one invitation, show it with confirmation. If multiple, list them:

```
╭─ 🐿️ relay invitations
│
│  Pending invitations:
│  1. patrickSupernormal/walnut-relay
│  2. benflint/walnut-relay
│
│  ▸ Accept which? (number, "all", or "cancel")
╰─
```

### Step 2 -- Confirm and accept the invitation

Accepting modifies external state. Confirm:

```
╭─ 🐿️ accept invitation
│
│  This will accept the collaborator invitation from <peer-owner>
│  for their relay repo (<peer-owner>/walnut-relay).
│  You'll get push access to their relay.
│
│  ▸ Accept?
│  1. Yes
│  2. Cancel
╰─
```

After confirmation, for each selected invitation:

```bash
gh api "/user/repository_invitations/$INVITATION_ID" -X PATCH 2>&1
```

### Step 3 -- Fetch peer's public key from their relay

After accepting, fetch the peer's public key via the Contents API (no full clone needed for just one file):

```bash
mkdir -p "$WORLD_ROOT/.alive/relay-keys/peers"
gh api "repos/$PEER_OWNER/walnut-relay/contents/keys/$PEER_OWNER.pem" \
  --jq '.content' | base64 -d > "$WORLD_ROOT/.alive/relay-keys/peers/$PEER_OWNER.pem" 2>&1
```

If the key file doesn't exist yet (peer hasn't finished setup), warn but continue:

```
╭─ 🐿️ heads up
│
│  <peer-owner>'s public key isn't on their relay yet.
│  They may not have finished setup. Encryption won't work until
│  their key is available. Check again with /alive:relay status.
╰─
```

### Step 4 -- Check if own relay exists

**Persist PEER_OWNER before the setup detour** -- the full `/alive:relay setup` flow may change context, so write `PEER_OWNER` to a temp file first:

```bash
echo "$PEER_OWNER" > "$WORLD_ROOT/.alive/.peer_accept_pending"
```

Check for a **real** relay (not just a minimal relay.yaml from a previous "Later" choice). A real relay has a non-empty `relay.repo` in relay.yaml AND the public key exists:

```bash
HAS_REAL_RELAY="NO"
if [ -f "$WORLD_ROOT/.alive/relay.yaml" ]; then
  RELAY_REPO=$(python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    m = re.search(r'repo:\s*\"([^\"]+)\"', f.read())
    print(m.group(1) if m else '')
" "$WORLD_ROOT/.alive/relay.yaml")
  if [ -n "$RELAY_REPO" ] && [ -f "$WORLD_ROOT/.alive/relay-keys/public.pem" ]; then
    HAS_REAL_RELAY="YES"
  fi
fi
echo "$HAS_REAL_RELAY"
```

If `HAS_REAL_RELAY` is `NO`, offer to set one up:

```
╭─ 🐿️ relay setup
│
│  You accepted <peer-owner>'s relay invite.
│  They can push packages to your inbox on their relay.
│
│  To send packages back, you need your own relay.
│
│  ▸ Create your relay now?
│  1. Yes -- run /alive:relay setup
│  2. Later -- I'll set it up when I need to send
╰─
```

If yes, run the full `/alive:relay setup` flow (Steps 2 through 7). After setup completes, read back `PEER_OWNER` and mark relay as real:

```bash
PEER_OWNER=$(cat "$WORLD_ROOT/.alive/.peer_accept_pending" 2>/dev/null)
HAS_REAL_RELAY="YES"
```

Continue to Step 5.

**If "Later":** No relay means no keys to push and no repo to invite into. Show the guidance note, clean up the persistence file, then skip Steps 5 and 6 -- jump directly to Step 7 (display name prompt):

```
╭─ 🐿️ heads up
│
│  To send packages back to <peer-owner>, set up your relay:
│  /alive:relay setup
│  Then invite them: /alive:relay peer add <peer-owner>
╰─
```

```bash
rm -f "$WORLD_ROOT/.alive/.peer_accept_pending"
```

### Step 5 -- Push own public key to peer's relay

**Only runs when `HAS_REAL_RELAY` is `YES`** (pre-existing or just created in Step 4). If "Later" was chosen, this step was already skipped per Step 4 instructions.

Push the public key to the peer's relay via the Contents API so the peer can encrypt packages:

```bash
PUBLIC_KEY_B64=$(base64 < "$WORLD_ROOT/.alive/relay-keys/public.pem" | tr -d '\n')

gh api "repos/$PEER_OWNER/walnut-relay/contents/keys/$GITHUB_USERNAME.pem" \
  -X PUT \
  -f message="Add public key for $GITHUB_USERNAME" \
  -f content="$PUBLIC_KEY_B64" 2>&1
```

If the key already exists (API returns 422), the peer already has your key. Skip silently.

### Step 6 -- Auto-invite peer back

**Gating (all must be true before proceeding):**

1. Receiver has a real relay (`HAS_REAL_RELAY` from Step 4 is `YES`, either pre-existing or just created)
2. `PEER_OWNER` is non-empty (read back from persistence file if setup ran)

```bash
if [ "$HAS_REAL_RELAY" != "YES" ] || [ -z "$PEER_OWNER" ]; then
  # No real relay or no peer owner -- show guidance and skip to Step 7
  # Show the "heads up" block below, then proceed directly to Step 7
  SKIP_INVITE="true"
else
  SKIP_INVITE="false"
fi
```

**If `SKIP_INVITE` is `true`:** This is an edge case (e.g., `PEER_OWNER` was lost despite persistence). Clean up and skip to Step 7:

```bash
rm -f "$WORLD_ROOT/.alive/.peer_accept_pending"
```

**If `SKIP_INVITE` is `false`:** Check collaborator state. Parse only the HTTP status line (starts with `HTTP/`):

```bash
RESPONSE=$(gh api "repos/$GITHUB_USERNAME/walnut-relay/collaborators/$PEER_OWNER" -i --silent 2>&1)
HTTP_STATUS=$(echo "$RESPONSE" | grep -E '^HTTP/' | head -1 | grep -oE '[0-9]{3}')
```

- **204:** Already a collaborator -- skip silently, log "already connected"
- **404:** Not a collaborator -- proceed to confirmation prompt
- **Empty or other:** Skip with note ("couldn't check collaborator state -- try /alive:relay peer add <peer-owner> later")

**Confirmation (external action -- MUST confirm before executing):**

```
╭─ 🐿️ invite back
│
│  To receive packages from <peer-owner>, they need
│  push access to your relay.
│
│  ▸ Invite <peer-owner> as collaborator?
│  1. Yes -- send the invite
│  2. Later -- run /alive:relay peer add <peer-owner> when ready
╰─
```

**After confirmation:** Capture the HTTP status from the PUT to branch on response codes:

```bash
INVITE_RESPONSE=$(gh api "repos/$GITHUB_USERNAME/walnut-relay/collaborators/$PEER_OWNER" \
  -X PUT -f permission=push -i --silent 2>&1)
INVITE_STATUS=$(echo "$INVITE_RESPONSE" | grep -E '^HTTP/' | head -1 | grep -oE '[0-9]{3}')
```

Handle response codes:
- **201:** Invitation sent successfully
- **422:** Already invited -- skip silently
- **429 / rate limit:** Show rate-limit guidance, don't block the flow
- **Empty or other:** Show note ("invite may not have sent -- verify with /alive:relay status")

Then create an inbox directory for the peer on the receiver's relay (capture status for 422 handling):

```bash
GITKEEP_CONTENT=$(printf 'Inbox for %s\n' "$PEER_OWNER" | base64 | tr -d '\n')
INBOX_RESPONSE=$(gh api "repos/$GITHUB_USERNAME/walnut-relay/contents/inbox/$PEER_OWNER/.gitkeep" \
  -X PUT \
  -f message="Add inbox for $PEER_OWNER" \
  -f content="$GITKEEP_CONTENT" -i --silent 2>&1)
INBOX_STATUS=$(echo "$INBOX_RESPONSE" | grep -E '^HTTP/' | head -1 | grep -oE '[0-9]{3}')
```

If the `.gitkeep` already exists (422), skip silently.

**Clean up the persistence file** at the end of this step (regardless of path taken):

```bash
rm -f "$WORLD_ROOT/.alive/.peer_accept_pending"
```

### Step 7 -- Display name prompt

**Only prompt when creating a new person walnut.** First, search for an existing person walnut by BOTH path AND `github:` field in key.md frontmatter (case-insensitive):

```bash
# Search by github field in key.md frontmatter (exact match, case-insensitive)
# Uses Python to avoid substring false positives (e.g., "ben" matching "benflint")
EXISTING_BY_GITHUB=$(python3 - "$WORLD_ROOT" "$PEER_OWNER" << 'PYEOF'
import sys, os, re, glob

world_root = sys.argv[1]
peer = sys.argv[2].lower()

for key_file in glob.glob(os.path.join(world_root, "02_Life/people/*/\_core/key.md")):
    with open(key_file) as f:
        for line in f:
            m = re.match(r'^\s*github:\s*["\']?([^"\'\s]+)["\']?\s*$', line)
            if m and m.group(1).lower() == peer:
                print(key_file)
                sys.exit(0)
            if line.strip() == '---' and not line.startswith('---'):
                break  # past frontmatter
PYEOF
)

# Search by slug match (GitHub username as slug, lowercased)
PEER_SLUG_DEFAULT=$(echo "$PEER_OWNER" | tr '[:upper:]' '[:lower:]')
EXISTING_BY_PATH=""
if [ -d "$WORLD_ROOT/02_Life/people/$PEER_SLUG_DEFAULT" ]; then
  EXISTING_BY_PATH="$WORLD_ROOT/02_Life/people/$PEER_SLUG_DEFAULT"
fi
```

**If an existing walnut is found** (by either method), extract `PEER_NAME` and `PEER_SLUG` from it -- do NOT prompt:

```bash
# Determine the walnut directory from whichever search matched
if [ -n "$EXISTING_BY_GITHUB" ]; then
  WALNUT_DIR=$(dirname "$(dirname "$EXISTING_BY_GITHUB")")
elif [ -n "$EXISTING_BY_PATH" ]; then
  WALNUT_DIR="$EXISTING_BY_PATH"
fi

# Extract slug from directory name
PEER_SLUG=$(basename "$WALNUT_DIR")

# Extract display name from goal: field in key.md
PEER_NAME=$(python3 -c "
import sys, re
with open(sys.argv[1]) as f:
    m = re.search(r'goal:\s*\"?([^\"\n]+)\"?', f.read())
    print(m.group(1).strip() if m else sys.argv[2])
" "$WALNUT_DIR/_core/key.md" "$PEER_OWNER")
```

**If no existing walnut found**, prompt for a display name:

```
╭─ 🐿️ peer info
│
│  ▸ What's their name? (default: <peer-owner>)
╰─
```

- **Enter / empty:** Use the GitHub username as both display name and slug
- **Name provided:** Use as display name; derive slug via the same logic as peer add Step 6

After the prompt, set `PEER_NAME` and `PEER_SLUG` explicitly:

```bash
# If empty/skipped, default to GitHub username
if [ -z "$PEER_NAME" ]; then
  PEER_NAME="$PEER_OWNER"
fi

# Derive slug from the display name (same logic as peer add Step 6)
PEER_SLUG=$(python3 -c "
import sys, re, unicodedata
name = sys.argv[1]
name = unicodedata.normalize('NFKD', name).encode('ascii', 'ignore').decode()
slug = re.sub(r'[^a-z0-9]+', '-', name.lower()).strip('-')
print(slug)
" "$PEER_NAME")
```

### Step 8 -- Write or update .alive/relay.yaml

**If the human just ran setup (Step 4 → yes):** relay.yaml already exists. Add the peer to the peer list using the same Python append logic as peer add Step 8, with status `"accepted"`. Use `PEER_NAME` from Step 7 for the `name:` field and `PEER_SLUG` for the `person_walnut:` path.

**If relay.yaml already existed before this flow:** Add the peer to the existing peer list with status `"accepted"`.

**If the human chose "Later" in Step 4 and no relay.yaml exists:** Write a minimal relay.yaml that records the peer relationship even without a full relay setup. This ensures the peer is tracked:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$GITHUB_USERNAME" "$PEER_OWNER" "$PEER_NAME" "$PEER_SLUG" << 'PYEOF'
import sys, datetime, re

config_path = sys.argv[1]
username = sys.argv[2]
peer_owner = sys.argv[3]
peer_name = sys.argv[4]
peer_slug = sys.argv[5]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
today = datetime.date.today().isoformat()

# Sanitize name: single line, escape quotes, strip control chars
safe_name = re.sub(r'[\x00-\x1f\x7f-\x9f]', '', peer_name)
safe_name = safe_name.replace('\\', '\\\\').replace('"', '\\"')
safe_name = safe_name.strip()[:100]

yaml_content = f"""relay:
  repo: ""
  local: ""
  github_username: "{username}"
  private_key: ""
  public_key: ""
  last_sync: "{now}"
  last_commit: ""
peers:
  - github: "{peer_owner}"
    name: "{safe_name}"
    relay: "{peer_owner}/walnut-relay"
    person_walnut: "02_Life/people/{peer_slug}"
    added: "{today}"
    status: "accepted"
"""

with open(config_path, "w") as f:
    f.write(yaml_content)

print(f"Written: {config_path}")
PYEOF
```

This partial config allows `/alive:relay setup` to detect it later and fill in the missing fields while preserving the peer list.

### Step 9 -- Create or update person walnut

Same as peer add Step 9 -- check if a person walnut exists for the inviter (using the search from Step 7), create or update it with `github:` and `relay:` fields. Use the display name from Step 7 for the walnut goal and relay.yaml `name:` field.

### Step 10 -- Confirm

**Final cleanup** (belt-and-suspenders -- remove persistence file if any path missed it):

```bash
rm -f "$WORLD_ROOT/.alive/.peer_accept_pending"
```

```
╭─ 🐿️ relay connected
│
│  Accepted invite from <peer-owner>.
│  Their public key saved locally for encryption.
│  Your public key pushed to their relay for decryption.
│
│  Relay is bidirectional. Packages will be encrypted automatically.
╰─
```

Stash:

```
╭─ 🐿️ +1 stash (N)
│  Accepted relay invite from <peer-owner> -- bidirectional relay active
│  → drop?
╰─
```

---

## /alive:relay status

Show the current state of the relay -- config, peers, pending packages, last sync.

### Step 1 -- Check relay exists

```bash
test -f "$WORLD_ROOT/.alive/relay.yaml" && echo "CONFIGURED" || echo "NOT_CONFIGURED"
```

If not configured:

```
╭─ 🐿️ no relay
│
│  No relay configured. Run /alive:relay setup to create one.
╰─
```

### Step 2 -- Read relay config

Read `$WORLD_ROOT/.alive/relay.yaml` and parse the relay and peers sections.

### Step 3 -- Pull latest and check peer invitation status

Sync the local clone and update relay metadata:

```bash
cd "$WORLD_ROOT/.alive/relay" && git pull --quiet 2>&1
```

For each peer, check if they've accepted by querying the collaborators list and capturing the result:

```bash
COLLABORATORS_JSON=$(gh api "repos/$GITHUB_USERNAME/walnut-relay/collaborators" \
  --jq '[.[] | .login]' 2>&1)
echo "$COLLABORATORS_JSON"
```

Compare against the peer list. Update `status:`, `last_sync`, and `last_commit` in relay.yaml:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$WORLD_ROOT/.alive/relay" << 'PYEOF'
import sys, datetime, subprocess, re, os

config_path = sys.argv[1]
repo_dir = sys.argv[2]

with open(config_path) as f:
    text = f.read()

# Update last_sync
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
text = re.sub(r'(last_sync:\s*)"[^"]*"', f'\\1"{now}"', text)

# Update last_commit
try:
    commit = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], cwd=repo_dir
    ).decode().strip()
    text = re.sub(r'(last_commit:\s*)"[^"]*"', f'\\1"{commit}"', text)
except Exception:
    pass

with open(config_path, "w") as f:
    f.write(text)

print("SYNCED")
PYEOF
```

Update peer status from pending to accepted based on the collaborators list:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$COLLABORATORS_JSON" << 'PYEOF'
import sys, json, re

config_path = sys.argv[1]
collaborators_json = sys.argv[2]

collaborators = json.loads(collaborators_json)
collab_set = set(c.lower() for c in collaborators)

with open(config_path) as f:
    text = f.read()

# Find peer blocks and update status for accepted collaborators
lines = text.split('\n')
updated_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    updated_lines.append(line)

    # Detect a peer github line
    m = re.match(r'^(\s+github:\s*)"?([^"\s]+)"?\s*$', line)
    if m:
        peer_gh = m.group(2).lower()
        # Look ahead for the status line within this peer block
        j = i + 1
        while j < len(lines) and lines[j].startswith('    ') and not lines[j].strip().startswith('- '):
            if 'status:' in lines[j] and peer_gh in collab_set:
                lines[j] = re.sub(r'status:\s*"pending"', 'status: "accepted"', lines[j])
            j += 1
    i += 1

with open(config_path, 'w') as f:
    f.write('\n'.join(lines))

print("STATUS_UPDATED")
PYEOF
```

Where `$COLLABORATORS_JSON` is the output from the `gh api` call above.

### Step 4 -- Count pending packages

Check the local sparse clone for packages in your inbox:

```bash
find "$WORLD_ROOT/.alive/relay/inbox/$GITHUB_USERNAME" \
  -name "*.walnut" -type f 2>/dev/null | wc -l
```

List package details (filename, sender from path, modification date):

```bash
find "$WORLD_ROOT/.alive/relay/inbox/$GITHUB_USERNAME" \
  -name "*.walnut" -type f 2>/dev/null -exec ls -lh {} \;
```

### Step 5 -- Verify private key permissions

```bash
ls -l "$WORLD_ROOT/.alive/relay-keys/private.pem" | awk '{print $1}'
```

If not `-rw-------`, include a warning in the status output.

### Step 6 -- Show status

```
╭─ 🐿️ relay status
│
│  Relay:     <username>/walnut-relay
│  Clone:     .alive/relay/
│  Keypair:   RSA-4096 (private key local, public key on relay)
│  Last sync: <timestamp>
│
│  Peers:
│    <name> (<github>) -- accepted
│    <name> (<github>) -- pending
│
│  Inbox: <N> packages waiting
╰─
```

If packages are waiting:

```
╭─ 🐿️ packages available
│
│  <N> packages in your inbox:
│  1. <filename> (from <sender>, <date>)
│  2. <filename> (from <sender>, <date>)
│
│  ▸ Import now?
│  1. Import all
│  2. Pick specific packages
│  3. Later
╰─
```

If "Import all" or specific packages selected, invoke `/alive:receive` for each package path in the local sparse clone.

---

## .alive/relay.yaml Schema

The relay config file. Lives at `.alive/relay.yaml` in the world root. Created by `/alive:relay setup`, updated by peer operations.

**Full schema:**

```yaml
# Relay configuration
relay:
  # GitHub repo in owner/name format
  repo: "patrickSupernormal/walnut-relay"

  # Path to the local sparse clone (relative to world root)
  local: ".alive/relay/"

  # Authenticated GitHub username
  github_username: "patrickSupernormal"

  # Path to RSA private key (relative to world root, never committed anywhere)
  private_key: ".alive/relay-keys/private.pem"

  # Path to RSA public key (relative to world root)
  public_key: ".alive/relay-keys/public.pem"

  # Last time the relay was synced (ISO 8601 UTC)
  last_sync: "2026-03-27T12:00:00Z"

  # Last known commit hash on the relay repo
  last_commit: "abc123def456"

# Peer list (cached from person walnuts for fast hook lookups)
peers:
  - # Peer's GitHub username
    github: "benflint"

    # Display name
    name: "Ben Flint"

    # Peer's relay repo (owner/name format)
    relay: "benflint/walnut-relay"

    # Path to their person walnut (relative to world root)
    person_walnut: "02_Life/people/ben-flint"

    # Date peer was added
    added: "2026-03-27"

    # Invitation status: pending | accepted
    status: "accepted"
```

**Field notes:**

- `relay.repo` -- always `<username>/walnut-relay`. Convention, like `.ssh`.
- `relay.local` -- the sparse clone directory. Only checks out `inbox/<own-username>/` and `keys/`.
- `relay.private_key` -- the RSA-4096 private key at `.alive/relay-keys/private.pem`. Permissions must be 600. Never leaves the local machine. Never committed to any repo.
- `relay.public_key` -- the RSA-4096 public key at `.alive/relay-keys/public.pem`. Committed to `keys/<username>.pem` in the relay repo. Peers fetch it to encrypt packages for you.
- `peers[].relay` -- the peer's relay repo. Used by `alive:share` to push packages via the Contents API.
- `peers[].person_walnut` -- canonical location of the peer's person walnut. The person walnut holds the authoritative identity; relay.yaml caches for speed.
- `peers[].status` -- `"pending"` until the peer accepts the collaborator invitation, then `"accepted"`.

**What is NOT stored here:**

- Passphrases. Relay encryption uses RSA keypairs (epic decision #4). No passphrases involved in relay transport. Passphrase encryption remains available for manual shares via alive:share.
- Private keys of peers. Only your own private key path is stored. Peer public keys are fetched from their relay repos and cached locally at `.alive/relay-keys/peers/<username>.pem`.
- Full person walnut data. Only the path is cached; the person walnut is the source of truth.

---

## Filesystem Layout

After setup, the relay creates this structure under `.alive/`:

```
.alive/
  relay.yaml                      Config file (schema above)
  relay/                          Sparse clone of own relay repo
    .git/
    keys/
      patrickSupernormal.pem      Own public key (committed)
      benflint.pem                Peer's public key (committed by peer)
    inbox/
      patrickSupernormal/         Own inbox (sparse checkout)
        .gitkeep
  relay-keys/                     Local key storage (NOT in git)
    private.pem                   RSA-4096 private key (chmod 600)
    public.pem                    RSA-4096 public key
    peers/                        Cached peer public keys
      benflint.pem                Fetched from benflint's relay
      carol-smith.pem             Fetched from carol-smith's relay
```

**Key separation:** `.alive/relay/` is the sparse git clone -- only `inbox/<own-username>/` and `keys/` are checked out. `.alive/relay-keys/` holds local key material, completely separate from the git-managed directory. The private key never enters any git repo.

**Peer keys directory:** `.alive/relay-keys/peers/` caches peer public keys fetched from their relay repos. These are used by `alive:share` to encrypt packages. The `relay/keys/` directory inside the clone is the git-managed exchange point where peers commit their public keys.

---

## Edge Cases

**gh not installed:** Caught in prerequisites. Guide to install.

**Relay repo force-pushed (compaction):** The local sparse clone handles this:

```bash
cd "$WORLD_ROOT/.alive/relay" && \
  git fetch origin && \
  BRANCH=$(git branch --show-current) && \
  git reset --hard "origin/$BRANCH" 2>&1
```

**Private key permissions too open:** Checked on every relay operation (prerequisites check in status, verified during setup). Warn if not 600.

**Peer hasn't created their own relay:** When checking status, if a peer's relay repo doesn't exist yet (`gh api repos/<peer>/walnut-relay` returns 404), show their status as "no relay" rather than erroring.

**Network failure during setup:** If any step fails (repo creation, clone, push), clean up partial state and show what failed with guidance to retry:

```
╭─ 🐿️ setup failed
│
│  <step> failed: <error message>
│
│  Partial state has been cleaned up.
│  Fix the issue and run /alive:relay setup again.
╰─
```

**Multiple GitHub accounts:** The skill uses whatever account `gh auth status` reports. If the human has multiple accounts, they manage switching via `gh auth switch` outside the skill.

**Offline operation:** Caught in prerequisites. All subcommands require network access.

**Username with special characters:** GitHub usernames are validated to `[a-zA-Z0-9-]` pattern before use in API calls, file paths, and YAML writes. Reject anything else.

---

## Security Notes

- **Private key never leaves local machine.** Not committed. Not pushed. Not shared. chmod 600.
- **Encryption is automatic.** When `alive:share` pushes via relay, it encrypts with the recipient's RSA public key. When `alive:receive` pulls, it decrypts with the local RSA private key. No passphrase needed.
- **Relay repo is private.** Only invited collaborators can see it.
- **Contents API for push.** The sender never clones the recipient's repo. One API call per package, zero disk usage per peer.
- **Sparse checkout for pull.** Only your inbox and keys are checked out locally.
- **Collaborator permissions.** GitHub personal repo collaborators get push access. They can push to any path in the repo, not just their designated inbox. This is acceptable for trusted peers. Unknown pushers are flagged by the session-start hook.
- **Input sanitization.** All peer-provided values (usernames, names) are validated and passed to Python via sys.argv, never via shell interpolation. YAML writes escape special characters.
- **Confirm before external actions.** Repo creation, collaborator invitations, and invitation acceptance all require explicit human confirmation before executing.
