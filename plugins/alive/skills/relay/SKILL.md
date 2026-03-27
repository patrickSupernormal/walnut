---
description: "Set up and manage a private GitHub relay for automatic .walnut package delivery between peers. Handles relay creation (private repo + RSA keypair), peer invitations, invitation acceptance, and status. The transport layer for P2P sharing -- extends alive:share and alive:receive with push/pull."
user-invocable: true
---

# Relay

Private inbox relay for automatic .walnut package delivery. Each person owns their own relay repo on GitHub. Others push to it via the Contents API. You pull from it via a local sparse clone.

No daemon. No server. Just a private GitHub repo as a mailbox, RSA encryption for confidentiality, and `gh` CLI for everything.

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

## Prerequisites

**GitHub CLI (`gh`) must be authenticated.** Every subcommand starts by checking auth:

```bash
gh auth status 2>&1
```

If the exit code is non-zero, guide the human through authentication:

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

**GitHub username discovery:** After confirming auth, get the authenticated username:

```bash
gh api user --jq '.login'
```

Store this as `GITHUB_USERNAME` for use throughout the skill.

---

## /alive:relay setup

One-time relay initialization. Creates the private GitHub repo, generates an RSA-4096 keypair, commits the public key, configures sparse checkout, and writes `.alive/relay.yaml`.

### Step 1 -- Check for existing relay

```bash
test -f .alive/relay.yaml && echo "EXISTS" || echo "NEW"
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

If "Reconfigure", warn that this is destructive (existing peers lose push access) and require explicit confirmation before proceeding.

### Step 2 -- Create private relay repo

```bash
gh repo create walnut-relay --private --description "Walnut P2P relay inbox" 2>&1
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

If reusing, skip repo creation and proceed to Step 3.

### Step 3 -- Generate RSA-4096 keypair

Generate the keypair using openssl (zero dependencies, pre-installed on macOS and Linux):

```bash
RELAY_DIR=".alive/relay"
mkdir -p "$RELAY_DIR"

# Generate private key (stays local, never committed)
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$RELAY_DIR/private.pem" 2>&1

# Extract public key
openssl rsa -in "$RELAY_DIR/private.pem" -pubout -out "$RELAY_DIR/public.pem" 2>&1

# Lock down private key permissions
chmod 600 "$RELAY_DIR/private.pem"
chmod 644 "$RELAY_DIR/public.pem"
```

Verify the private key permissions after generation:

```bash
stat -f '%Lp' "$RELAY_DIR/private.pem"
```

If not `600`, warn:

```
╭─ 🐿️ heads up
│
│  Private key permissions are too open (<actual>). Should be 600.
│  Run: chmod 600 .alive/relay/private.pem
╰─
```

### Step 4 -- Clone relay repo with sparse checkout

Clone the relay repo into `.alive/relay/repo/` using sparse checkout. Only the human's own inbox and the `keys/` directory are checked out locally.

```bash
RELAY_REPO_DIR=".alive/relay/repo"

# Clone with sparse checkout (blob filtering for efficiency)
git clone --filter=blob:none --sparse "https://github.com/$GITHUB_USERNAME/walnut-relay.git" "$RELAY_REPO_DIR" 2>&1

# Configure sparse checkout for own inbox + keys
cd "$RELAY_REPO_DIR" && git sparse-checkout set "inbox/$GITHUB_USERNAME" "keys" 2>&1
```

### Step 5 -- Commit initial structure to relay repo

Push the public key and initial README to the relay repo:

```bash
cd "$RELAY_REPO_DIR"

# Create directory structure
mkdir -p "keys" "inbox/$GITHUB_USERNAME"

# Copy public key into keys/
cp "../../public.pem" "keys/$GITHUB_USERNAME.pem"

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

# Create .gitkeep for inbox
touch "inbox/$GITHUB_USERNAME/.gitkeep"

# Commit and push
git add -A
git commit -m "Initialize walnut relay"
git push origin main 2>&1
```

If the repo was just created and has no commits yet, `git push` may need to set upstream:

```bash
git push -u origin main 2>&1
```

If the default branch is not `main` (some accounts default to `master`), detect and use the correct branch:

```bash
git branch --show-current
```

### Step 6 -- Write .alive/relay.yaml

Write the relay configuration. This is the canonical config file for all relay operations.

```bash
cat > .alive/relay.yaml << YAMLEOF
relay:
  repo: "$GITHUB_USERNAME/walnut-relay"
  local: ".alive/relay/repo"
  github_username: "$GITHUB_USERNAME"
  private_key: ".alive/relay/private.pem"
  public_key: ".alive/relay/public.pem"
  last_sync: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  last_commit: "$(cd .alive/relay/repo && git rev-parse HEAD)"
peers: []
YAMLEOF
```

### Step 7 -- Confirm

```
╭─ 🐿️ relay ready
│
│  Repo:        <username>/walnut-relay (private)
│  Local clone: .alive/relay/repo/
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
test -f .alive/relay.yaml && echo "CONFIGURED" || echo "NOT_CONFIGURED"
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

Validate the username exists on GitHub:

```bash
gh api "users/<peer-username>" --jq '.login' 2>&1
```

If the API returns an error, the username doesn't exist:

```
╭─ 🐿️ unknown user
│
│  GitHub user "<peer-username>" not found. Check the spelling.
╰─
```

### Step 3 -- Check for duplicate peer

Read `.alive/relay.yaml` and check if a peer with this github username already exists.

```bash
python3 -c "
import sys, re
with open('.alive/relay.yaml') as f:
    text = f.read()
# Simple check for the github username in peers section
if '  github: \"$PEER_USERNAME\"' in text or \"  github: '$PEER_USERNAME'\" in text or '  github: $PEER_USERNAME' in text:
    print('DUPLICATE')
else:
    print('NEW')
"
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

### Step 4 -- Invite as collaborator

Invite the peer as a collaborator on your relay repo with push permission:

```bash
gh api "repos/$GITHUB_USERNAME/walnut-relay/collaborators/$PEER_USERNAME" \
  -X PUT -f permission=push 2>&1
```

**Rate limit note:** GitHub limits collaborator invitations to 50 per 24 hours. If the API returns a rate limit error, surface it:

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

### Step 6 -- Create inbox directory for the peer

Push an inbox directory for the peer to the relay repo:

```bash
cd .alive/relay/repo
mkdir -p "inbox/$PEER_USERNAME"
touch "inbox/$PEER_USERNAME/.gitkeep"
git add "inbox/$PEER_USERNAME/.gitkeep"
git commit -m "Add inbox for $PEER_USERNAME"
git push 2>&1
```

### Step 7 -- Update .alive/relay.yaml

Append the new peer to the `peers:` list in relay.yaml. Use Python to safely append without corrupting the file:

```bash
python3 -c "
import datetime
peer_entry = '''  - github: \"$PEER_USERNAME\"
    name: \"$PEER_NAME\"
    relay: \"$PEER_USERNAME/walnut-relay\"
    person_walnut: \"02_Life/people/$PEER_SLUG\"
    added: \"$(date +%Y-%m-%d)\"
    status: \"pending\"'''

with open('.alive/relay.yaml') as f:
    text = f.read()

# If peers is empty list, replace it
if 'peers: []' in text:
    text = text.replace('peers: []', 'peers:\n' + peer_entry)
else:
    # Append to existing peers list
    text = text.rstrip() + '\n' + peer_entry + '\n'

with open('.alive/relay.yaml', 'w') as f:
    f.write(text)
"
```

### Step 8 -- Create or update person walnut

Check if a person walnut exists for this peer:

```bash
find 02_Life/people -name "key.md" -path "*/_core/key.md" 2>/dev/null | while read f; do
  dir=$(dirname "$(dirname "$f")")
  echo "$dir"
done
```

Search for a matching walnut by name or github username. If found, update `key.md` frontmatter to add `github:` and `relay:` fields using the Edit tool. If not found, create a minimal person walnut:

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

### Step 9 -- Confirm

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

If multiple invitations, list them:

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

### Step 2 -- Accept the invitation

For each selected invitation:

```bash
gh api "/user/repository_invitations/$INVITATION_ID" -X PATCH 2>&1
```

### Step 3 -- Fetch the peer's public key

After accepting, fetch the inviter's public key from their relay:

```bash
gh api "repos/$PEER_OWNER/walnut-relay/contents/keys/$PEER_OWNER.pem" \
  --jq '.content' | base64 -d > ".alive/relay/peer-keys/$PEER_OWNER.pem"
```

Create the peer-keys directory if needed:

```bash
mkdir -p .alive/relay/peer-keys
```

### Step 4 -- Check if own relay exists

```bash
test -f .alive/relay.yaml && echo "HAS_RELAY" || echo "NO_RELAY"
```

If the human doesn't have their own relay yet, offer to set one up:

```
╭─ 🐿️ relay setup
│
│  You accepted <peer-owner>'s relay invite.
│  They can now push packages to you.
│
│  To send packages back, you need your own relay.
│
│  ▸ Create your relay now?
│  1. Yes -- run /alive:relay setup
│  2. Later -- I'll set it up when I need to send
╰─
```

If yes, run the setup flow (Step 2 through Step 7 of `/alive:relay setup`). After setup completes, push your public key to the peer's relay and add yourself as a peer on your own relay.

### Step 5 -- Push own public key to peer's relay

If the human has their own relay (either pre-existing or just created), push their public key to the peer's relay repo via the Contents API so the peer can encrypt packages for them:

```bash
PUBLIC_KEY_B64=$(base64 < .alive/relay/public.pem | tr -d '\n')
gh api "repos/$PEER_OWNER/walnut-relay/contents/keys/$GITHUB_USERNAME.pem" \
  -X PUT \
  -f message="Add public key for $GITHUB_USERNAME" \
  -f content="$PUBLIC_KEY_B64" 2>&1
```

If the key already exists (API returns 422), the peer already has your key. Skip silently.

### Step 6 -- Update relay.yaml with new peer

Add the inviter to the local peer list in `.alive/relay.yaml` (same append logic as peer add, Step 7), with status `"accepted"`.

### Step 7 -- Create or update person walnut

Same as peer add Step 8 -- check if a person walnut exists for the inviter, create or update it with `github:` and `relay:` fields.

### Step 8 -- Confirm

```
╭─ 🐿️ relay connected
│
│  Accepted invite from <peer-owner>.
│  Their public key saved for encryption.
│  Your public key pushed to their relay.
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
test -f .alive/relay.yaml && echo "CONFIGURED" || echo "NOT_CONFIGURED"
```

If not configured:

```
╭─ 🐿️ no relay
│
│  No relay configured. Run /alive:relay setup to create one.
╰─
```

### Step 2 -- Read relay config

Read `.alive/relay.yaml` and parse the relay and peers sections.

### Step 3 -- Check peer invitation status

For each peer, check if they've accepted by querying the collaborators list:

```bash
gh api "repos/$GITHUB_USERNAME/walnut-relay/collaborators" \
  --jq '[.[] | .login]' 2>&1
```

Compare against the peer list. Update `status:` for any peers who have accepted since last check.

### Step 4 -- Count pending packages

Check the local sparse clone for packages in your inbox:

```bash
cd .alive/relay/repo && git pull --quiet 2>&1
find "inbox/$GITHUB_USERNAME" -name "*.walnut" 2>/dev/null | wc -l
```

### Step 5 -- Show status

```
╭─ 🐿️ relay status
│
│  Relay:     <username>/walnut-relay
│  Clone:     .alive/relay/repo/
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
  local: ".alive/relay/repo"

  # Authenticated GitHub username
  github_username: "patrickSupernormal"

  # Path to RSA private key (relative to world root, never committed anywhere)
  private_key: ".alive/relay/private.pem"

  # Path to RSA public key (relative to world root)
  public_key: ".alive/relay/public.pem"

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
- `relay.private_key` -- the RSA-4096 private key. Permissions must be 600. Never leaves the local machine. Never committed to any repo.
- `relay.public_key` -- the RSA-4096 public key. Committed to `keys/<username>.pem` in the relay repo. Peers fetch it to encrypt packages for you.
- `peers[].relay` -- the peer's relay repo. Used by `alive:share` to push packages via the Contents API.
- `peers[].person_walnut` -- canonical location of the peer's person walnut. The person walnut holds the authoritative identity; relay.yaml caches for speed.
- `peers[].status` -- `"pending"` until the peer accepts the collaborator invitation, then `"accepted"`.

**What is NOT stored here:**

- Passphrases. Relay encryption uses RSA keypairs. No passphrases involved.
- Private keys of peers. Only your own private key path is stored. Peer public keys are fetched from their relay repos and cached locally at `.alive/relay/peer-keys/<username>.pem`.
- Full person walnut data. Only the path is cached; the person walnut is the source of truth.

---

## Filesystem Layout

After setup, the relay creates this structure under `.alive/`:

```
.alive/
  relay.yaml                    Config file (schema above)
  relay/
    private.pem                 RSA-4096 private key (chmod 600)
    public.pem                  RSA-4096 public key
    peer-keys/                  Cached peer public keys
      benflint.pem              Fetched from benflint's relay
      carol-smith.pem           Fetched from carol-smith's relay
    repo/                       Sparse clone of own relay repo
      .git/
      keys/
        patrickSupernormal.pem  Own public key (committed)
        benflint.pem            Peer's public key (committed by peer)
      inbox/
        patrickSupernormal/     Own inbox (sparse checkout)
          .gitkeep
```

**Key separation:** The private key lives at `.alive/relay/private.pem`, outside the git-managed `repo/` directory. It is never committed anywhere. The `repo/` directory is a sparse clone -- only `inbox/<own-username>/` and `keys/` are checked out.

**Peer keys directory:** `.alive/relay/peer-keys/` caches peer public keys fetched from their relay repos. These are used by `alive:share` to encrypt packages. They are separate from the `repo/keys/` directory which is the git-managed exchange point.

---

## Edge Cases

**gh not installed:** If `gh` command is not found, tell the human to install it: `brew install gh` (macOS) or see https://cli.github.com/

**Relay repo force-pushed (compaction):** The local sparse clone handles this gracefully:

```bash
cd .alive/relay/repo && git fetch origin && git reset --hard origin/main 2>&1
```

**Private key permissions too open:** Check on every relay operation, not just setup. Warn if not 600.

**Peer hasn't created their own relay:** When checking status, if a peer's relay repo doesn't exist yet (`gh api repos/<peer>/walnut-relay` returns 404), show their status as "no relay" rather than erroring.

**Network failure during setup:** If any step fails (repo creation, clone, push), clean up partial state and show what failed with guidance to retry.

**Multiple GitHub accounts:** The skill uses whatever account `gh auth status` reports. If the human has multiple accounts, they manage switching via `gh auth switch` outside the skill.

**Offline operation:** All subcommands except `status` require network. If offline, detect early (`gh api user` fails) and surface clearly: "Can't reach GitHub. Try again when online."

---

## Security Notes

- **Private key never leaves local machine.** Not committed. Not pushed. Not shared. chmod 600.
- **Encryption is automatic.** When `alive:share` pushes via relay, it encrypts with the recipient's RSA public key. When `alive:receive` pulls, it decrypts with the local RSA private key. No passphrase needed.
- **Relay repo is private.** Only invited collaborators can see it.
- **Contents API for push.** The sender never clones the recipient's repo. One API call per package, zero disk usage per peer.
- **Sparse checkout for pull.** Only your inbox and keys are checked out locally.
- **Collaborator permissions.** GitHub personal repo collaborators get push access. They can push to any path in the repo, not just their designated inbox. This is acceptable for trusted peers. Unknown pushers are flagged by the session-start hook.
