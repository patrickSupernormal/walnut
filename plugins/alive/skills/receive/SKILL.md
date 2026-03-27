---
description: "Import a .walnut package into the world. Supports direct file import, inbox scan delegation, and relay pull (automatic fetch from git-based relay inbox). Detects encryption (passphrase or RSA), validates integrity (checksums + path safety), previews contents, and routes into a new walnut (full scope), existing walnut capsules (capsule scope), or read-only view (snapshot scope). Detects relay bootstrap invitations in manifests."
user-invocable: true
---

# Receive

Import walnut context from someone else. The import side of P2P sharing.

A `.walnut` file is always a single gzip-compressed tar archive. Three scopes: full walnut handoff (creates new walnut), capsule-level import (into existing walnut), or a snapshot for read-only viewing. Handles encryption detection and integrity validation before writing anything.

**Encrypted packages** contain `manifest.yaml` (cleartext, for preview) alongside `payload.enc` (the encrypted content). Decryption uses `openssl` -- fully session-driven, no terminal interaction. **Unencrypted packages** contain `manifest.yaml` alongside the content files directly.

**Relay packages** are pulled from the local relay inbox (`.alive/relay/inbox/<username>/`). They use RSA encryption (`payload.enc` + `payload.key`) and are auto-decrypted using the local private key -- no passphrase prompt needed. When a manually-received package contains a `relay:` field in its manifest, the skill offers to bootstrap a relay connection with the sender.

**Relay encryption model (epic decisions #4/#5):** Relay transport uses RSA-4096 keypairs, NOT stored passphrases. Public keys are exchanged via relay repos; encryption/decryption is automatic. The `relay.yaml` schema does not include peer passphrases -- this is by design. Passphrase-based encryption remains available for manual shares only (via `alive:share` without relay). When this skill detects `payload.key` alongside `payload.enc`, it uses RSA decryption. When only `payload.enc` is present (manual share), it prompts for a passphrase.

---

## Prerequisites

Read the format spec before processing any package. The template lives relative to the plugin install path:

```
templates/walnut-package/format-spec.md    -- full format specification
templates/walnut-package/manifest.yaml     -- manifest template with field docs
```

The squirrel MUST read both files before importing. Do not reconstruct the manifest schema from memory. Do NOT spawn an Explore agent or search for these files -- the paths above are authoritative.

**World root discovery (all entry points):** The world root is the ALIVE folder containing `01_Archive/`, `02_Life/`, `03_Inputs/`, `04_Ventures/`, `05_Experiments/`. Discover it by walking up from the current walnut's path or by reading the `.alive/` directory location. All target paths for import MUST resolve inside this root. The squirrel MUST discover and persist `WORLD_ROOT` in conversation state before processing any package -- it is needed by bootstrap detection (Step 1), RSA decryption (Step 2), target selection (Step 6), and cleanup (Step 8).

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

**Installed plugin version:** Read the plugin version from `walnut.manifest.yaml` at the plugin root. If the version cannot be determined, warn the human and skip the plugin version compatibility check in Step 4b -- do not assume a default version.

---

## Entry Points

Three ways this skill gets invoked:

### 1. Direct invocation

The human runs `/alive:receive` with a file path argument (or the squirrel asks for it):

```
/alive:receive ~/Desktop/nova-station-capsule-2026-03-26.walnut
```

If no path argument, ask:

```
╭─ 🐿️ receive
│
│  Where's the .walnut file?
│  ▸ Path?
╰─
```

### 2. Inbox scan delegation

The capture skill's inbox scan detects a `.walnut` file in `03_Inputs/` and delegates here. When delegated, the file path is already known -- skip the path prompt and proceed to Step 1.

### 3. Relay pull

Fetch packages from the local relay inbox. Triggered by:

- `/alive:receive --relay` (explicit)
- The squirrel acting on the session-start hook notification ("N packages waiting on the relay")
- The relay skill passing individual package paths via `/alive:receive <path>` (from status or pull flows). The auto-detection in 3d sets `RELAY_SOURCE` based on the path being inside the relay inbox.

**Note:** The relay skill (fn-2-edx.1) does not yet define a `pull` subcommand. The session-start hook notification mentions `/alive:receive` directly. If a `pull` subcommand is added to the relay skill later, it should delegate to `/alive:receive --relay`.

**Relay pull flow:**

#### 3a. Discover world root and validate relay config

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

If no world root:

```
╭─ 🐿️ no world found
│
│  Can't find the ALIVE world root.
│  Run this from inside your world directory.
╰─
```

Check relay config. A relay is "configured for pull" when relay.yaml exists AND has a non-empty `relay.repo` and `relay.local`, the local path is safe (relative, no `..`, resolves under world root), and the clone directory exists. A partial relay.yaml (from bootstrap, with empty `repo`/`local`) is NOT sufficient for relay pull.

Parse and validate config via Python (safer than grep for YAML-like content):

```bash
python3 - "$WORLD_ROOT" << 'PYEOF'
import sys, os, re

world_root = sys.argv[1]
config_path = os.path.join(world_root, ".alive", "relay.yaml")

if not os.path.isfile(config_path):
    print("NOT_CONFIGURED")
    sys.exit(0)

with open(config_path) as f:
    text = f.read()

# Accept both quoted and unquoted YAML scalar values
def yaml_val(key, text):
    m = re.search(rf'{key}:\s*"([^"\n]+)"', text)
    if not m:
        m = re.search(rf"{key}:\s*'([^'\n]+)'", text)
    if not m:
        m = re.search(rf'{key}:\s*([^\s\n#]+)', text)
    return m.group(1).strip() if m else ""

repo = yaml_val('repo', text)
local = yaml_val('local', text)
username = yaml_val('github_username', text)

if not repo or not local:
    print("PARTIAL_CONFIG")
    sys.exit(0)

# Validate local path: must be relative, no .., resolve under world root
if os.path.isabs(local) or ".." in local.split(os.sep):
    print("INVALID_LOCAL_PATH")
    sys.exit(0)

resolved = os.path.realpath(os.path.join(world_root, local))
if not resolved.startswith(os.path.realpath(world_root) + os.sep):
    print("INVALID_LOCAL_PATH")
    sys.exit(0)

if not os.path.isdir(os.path.join(resolved, ".git")):
    print("CLONE_MISSING")
    sys.exit(0)

# Validate username
if not username or not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?', username):
    print("INVALID_USERNAME")
    sys.exit(0)

print(f"CONFIGURED RELAY_LOCAL={local} GITHUB_USERNAME={username}")
PYEOF
```

Parse the output to extract `RELAY_LOCAL` and `GITHUB_USERNAME`. Persist both in conversation state -- they are used for pull, inbox listing, and cleanup throughout entry point 3.

If not configured:

```
╭─ 🐿️ no relay
│
│  No relay configured. Run /alive:relay setup to create one.
╰─
```

If partial config (from bootstrap, empty repo/local):

```
╭─ 🐿️ relay setup incomplete
│
│  You have peer connections saved but no relay configured for pull.
│  Run /alive:relay setup to create your relay and enable automatic delivery.
╰─
```

If clone missing:

```
╭─ 🐿️ relay clone missing
│
│  Relay is configured but the local clone is missing.
│  Run /alive:relay setup to reconfigure.
╰─
```

If invalid local path or invalid username:

```
╭─ 🐿️ relay config invalid
│
│  The relay.yaml config has invalid values.
│  Run /alive:relay setup to reconfigure.
╰─
```

#### 3b. Pull latest from relay clone

Pull with credential prompts disabled and check exit code. Use `--ff-only` to prevent merge commits; if the remote was force-pushed (compaction), fall back to fetch+reset. Use `$RELAY_LOCAL` from 3a:

```bash
CLONE_DIR="$WORLD_ROOT/$RELAY_LOCAL"

# Prevent git from prompting for credentials (would hang)
export GIT_TERMINAL_PROMPT=0

# Try fast-forward pull first
if git -C "$CLONE_DIR" pull --ff-only --quiet 2>&1; then
  echo "PULLED"
else
  # Fast-forward failed (force push, diverged) -- fetch and reset to remote HEAD
  if git -C "$CLONE_DIR" fetch --quiet origin 2>/dev/null; then
    # Derive the remote default branch deterministically
    REMOTE_HEAD=$(git -C "$CLONE_DIR" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')
    if [ -z "$REMOTE_HEAD" ]; then
      # Fallback: try current branch, then "main"
      REMOTE_HEAD=$(git -C "$CLONE_DIR" branch --show-current 2>/dev/null)
      [ -z "$REMOTE_HEAD" ] && REMOTE_HEAD="main"
    fi
    if git -C "$CLONE_DIR" reset --hard "origin/$REMOTE_HEAD" --quiet 2>/dev/null; then
      echo "RESET_TO_REMOTE"
    else
      echo "PULL_FAILED"
    fi
  else
    echo "PULL_FAILED"
  fi
fi
```

If pull fails (network error, auth expired):

```
╭─ 🐿️ relay sync failed
│
│  Couldn't sync with the remote relay (network or auth issue).
│  Proceeding with local clone state -- packages from before
│  the last successful sync are still available.
│
│  If this persists, check: gh auth status
╰─
```

Continue with whatever is in the local clone. Do not abort -- stale-but-present packages are still importable.

`GITHUB_USERNAME` was already extracted and validated in step 3a.

#### 3c. List packages in own inbox

```bash
find "$WORLD_ROOT/$RELAY_LOCAL/inbox/$GITHUB_USERNAME" \
  -name "*.walnut" -type f 2>/dev/null | LC_ALL=C sort
```

If no packages:

```
╭─ 🐿️ relay inbox empty
│
│  No packages in your relay inbox.
╰─
```

If packages found, present them:

```
╭─ 🐿️ relay packages
│
│  <N> packages in your relay inbox:
│  1. <filename> (<size>)
│  2. <filename> (<size>)
│
│  ▸ Import?
│  1. Import all
│  2. Pick specific packages
│  3. Cancel
╰─
```

#### 3d. Process each package

For each selected package, set a flag `RELAY_SOURCE=true` in conversation state along with the package file path. Then feed into the existing flow starting at Step 1 (extract + read manifest).

The `RELAY_SOURCE` flag tells Step 2 to attempt RSA auto-decryption and tells Step 8 to skip filesystem archival (git cleanup happens in 3e instead).

**Auto-detection for non-relay entry points:** If entry points 1 or 2 receive a package path that resolves inside the relay inbox (`$WORLD_ROOT/<relay.local>/inbox/`), automatically set `RELAY_SOURCE=true`. This ensures cleanup works correctly regardless of how the receive skill was invoked:

```bash
python3 -c "
import sys, os, re
world_root = sys.argv[1]
package_path = sys.argv[2]

config_path = os.path.join(world_root, '.alive', 'relay.yaml')
if not os.path.isfile(config_path):
    print('NOT_RELAY')
    sys.exit(0)

with open(config_path) as f:
    text = f.read()

m = re.search(r'local:\s*\"([^\"\\n]+)\"', text)
if not m:
    print('NOT_RELAY')
    sys.exit(0)

relay_local = m.group(1).strip()
if not relay_local or os.path.isabs(relay_local) or '..' in relay_local.split(os.sep):
    print('NOT_RELAY')
    sys.exit(0)

inbox_real = os.path.realpath(os.path.join(world_root, relay_local, 'inbox'))
package_real = os.path.realpath(package_path)

if package_real.startswith(inbox_real + os.sep):
    print('RELAY_SOURCE')
else:
    print('NOT_RELAY')
" "$WORLD_ROOT" "<package-path>"
```

Process packages sequentially. Between packages, confirm continuation:

```
╭─ 🐿️ next package
│
│  Imported 1 of <N>. Continue with <next-filename>?
│  1. Yes
│  2. Skip this one
│  3. Stop -- import the rest later
╰─
```

#### 3e. Git cleanup after successful import

After each package is successfully imported via the full receive flow (Steps 1-9), clean up the relay inbox. Use git operations (not shell deletion) so the archive enforcer is not triggered.

If multiple packages are imported in sequence, batch the git cleanup -- remove all successfully imported packages in a single commit:

Derive repo-relative paths from the full package paths returned by `find` in step 3c. Use basenames to construct the inbox-relative path. Use `--ignore-unmatch` so already-removed files don't break the batch:

```bash
cd "$WORLD_ROOT/$RELAY_LOCAL"

# Prevent git from prompting for credentials
export GIT_TERMINAL_PROMPT=0

# Loop over successfully imported package paths (stored in conversation state)
for pkg in "<full-path-1>" "<full-path-2>"; do
  git rm --ignore-unmatch -- "inbox/$GITHUB_USERNAME/$(basename "$pkg")" 2>&1 || true
done

# Only commit and push if there are staged changes
if ! git diff --cached --quiet 2>/dev/null; then
  git commit -m "relay: received" 2>&1
  git push 2>&1
else
  echo "NO_CHANGES_TO_COMMIT"
fi
```

**Commit message:** Always `"relay: received"` -- opaque, no walnut names or sender identity in the commit message.

If the push fails (network error), warn but don't block:

```
╭─ 🐿️ heads up
│
│  Import succeeded but couldn't push cleanup to the relay.
│  The packages are still in your remote inbox -- they'll be
│  cleaned up next time. Run: cd <relay-local-path> && git push
╰─
```

#### 3f. Update relay.yaml after pull

After processing all packages, update `last_sync` and `last_commit` in relay.yaml:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$WORLD_ROOT/$RELAY_LOCAL" << 'PYEOF'
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

---

## Flow

### Step 1 -- Extract Outer Archive and Read Manifest

Every `.walnut` file is a tar.gz. Extract it to a staging directory first:

```bash
STAGING=$(mktemp -d "/tmp/walnut-import-XXXXXXXX")
```

Extract the outer archive safely using the Python tarfile validation (same security validation used throughout -- see the full validation script in the reference section at the end of this file):

```bash
python3 -c '<SAFE_EXTRACT_SCRIPT>' "$STAGING" "<package-path>"
```

**Agent state note:** Shell variables do not persist between separate Bash tool calls. The squirrel MUST store the staging directory path in its own conversation state (note it after creation) and explicitly clean up staging in every abort path and at the end of Step 8.

After extraction, read `$STAGING/manifest.yaml`. This is always cleartext, even in encrypted packages. Show a preview:

```
╭─ 🐿️ package preview
│
│  Source:   nova-station
│  Scope:    capsule (shielding-review, safety-brief)
│  Created:  2026-03-26
│  Files:    8
│  Encrypted: no
│
│  Note: "Two capsules from the shielding review -- one still in draft."
│
│  ▸ Import?
│  1. Yes
│  2. Cancel
╰─
```

#### Bootstrap detection (relay invitation)

After reading the manifest and showing the preview, check for the optional `relay:` field. This field is present when the sender has a relay configured and indicates the package was created via a relay-connected share.

**Skip this check if:**
- The package was pulled from the relay (entry point 3 / `RELAY_SOURCE=true`) -- the connection already exists
- A local relay is already configured and the sender is already a peer. Detect this by parsing `peers[].github` from `.alive/relay.yaml`:

```bash
python3 -c "
import sys, re
config_path = sys.argv[1]
sender = sys.argv[2].lower()
try:
    with open(config_path) as f:
        text = f.read()
    peers = re.findall(r'github:\s*\"?([^\"\\n]+)\"?', text)
    if any(p.strip().lower() == sender for p in peers):
        print('ALREADY_PEER')
    else:
        print('NEW_SENDER')
except FileNotFoundError:
    print('NO_CONFIG')
" "$WORLD_ROOT/.alive/relay.yaml" "<relay.sender>" 2>/dev/null
```

If `ALREADY_PEER`, skip bootstrap and proceed to Step 2.

**Validate manifest relay fields before use (untrusted input):**

The `relay.sender` and `relay.repo` fields come from the manifest, which is untrusted. Before using them in filesystem paths, API calls, or git operations, validate strictly:

```bash
python3 -c "
import sys, re
sender = sys.argv[1]
repo = sys.argv[2]

# Validate sender: GitHub username pattern (alphanumeric + hyphens, 1-39 chars)
if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?', sender):
    print('INVALID_SENDER')
    sys.exit(0)

# Validate repo: must be owner/name format, both parts alphanumeric + hyphens
parts = repo.split('/')
if len(parts) != 2:
    print('INVALID_REPO')
    sys.exit(0)
owner, name = parts
if not re.fullmatch(r'[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?', owner):
    print('INVALID_REPO')
    sys.exit(0)
if not re.fullmatch(r'[a-zA-Z0-9._-]{1,100}', name):
    print('INVALID_REPO')
    sys.exit(0)

print('VALID')
" "<relay.sender>" "<relay.repo>"
```

If validation fails, skip bootstrap silently and continue with the import. Do not surface the relay invitation prompt for malformed values.

**If `relay:` is present, validated, and no local relay is configured** (no `.alive/relay.yaml`), or the sender is not in the peer list:

```
╭─ 🐿️ relay invitation
│
│  This package includes a relay connection:
│  <relay.repo> (from <relay.sender>)
│
│  Joining means you can accept their relay invitation
│  and set up keys for encrypted package exchange.
│  To receive packages automatically, you'll also need
│  your own relay (/alive:relay setup).
│
│  ▸ Connect to this relay?
│  1. Yes -- join the relay
│  2. No -- just import this package
╰─
```

**If the human chooses "Yes -- join the relay":**

Run the peer accept flow from alive:relay. The steps:

1. **Check gh auth and discover local GitHub username:**

```bash
gh auth status 2>&1
```

If not authenticated, guide them to `gh auth login --web` and pause.

After auth check, discover the local GitHub username (needed for relay.yaml and key push):

```bash
GITHUB_USERNAME=$(gh api user --jq '.login' 2>&1)
if [ -z "$GITHUB_USERNAME" ] || echo "$GITHUB_USERNAME" | grep -q "error"; then
  echo "USERNAME_FAILED"
else
  echo "GITHUB_USERNAME=$GITHUB_USERNAME"
fi
```

If username discovery fails (network error despite auth success), warn and abort bootstrap:

```
╭─ 🐿️ couldn't detect GitHub username
│
│  Authenticated but couldn't fetch your GitHub username.
│  Skipping relay bootstrap. Try again later with /alive:relay peer accept.
│
│  Continuing with package import.
╰─
```

2. **Check for pending invitation from the sender:**

Use the validated `relay.repo` to match against pending invitations. Parse the owner and repo name from the manifest's `relay.repo` field:

```bash
# Extract owner and repo name from relay.repo (already validated as owner/name format)
RELAY_OWNER=$(echo "<relay.repo>" | cut -d'/' -f1)
RELAY_REPO_NAME=$(echo "<relay.repo>" | cut -d'/' -f2)

INVITATIONS_JSON=$(gh api /user/repository_invitations --jq "
  [.[] | select(.repository.name == \"$RELAY_REPO_NAME\" and .repository.owner.login == \"$RELAY_OWNER\") |
   {id: .id, owner: .repository.owner.login, repo: .repository.full_name}]
" 2>/dev/null)
GH_EXIT=$?
```

If `gh api` failed (exit code non-zero or empty output), distinguish network/API errors from "no invitations":

```bash
if [ $GH_EXIT -ne 0 ] || [ -z "$INVITATIONS_JSON" ]; then
  echo "API_ERROR"
fi
```

If `API_ERROR`, warn and skip invitation acceptance (continue with import):

```
╭─ 🐿️ couldn't check invitations
│
│  GitHub API call failed (network or auth issue).
│  Skipping relay invitation check. Try /alive:relay peer accept later.
│
│  Continuing with package import.
╰─
```

Parse the result. If the JSON array is non-empty, extract the invitation ID:

```bash
INVITATION_ID=$(echo "$INVITATIONS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if data:
    print(data[0]['id'])
else:
    print('')
" 2>/dev/null)
```

If `INVITATION_ID` is non-empty, accept it (confirm first -- this is an external action):

```
╭─ 🐿️ accept invitation
│
│  Accept collaborator invitation from <relay.sender>
│  for their relay repo (<relay.repo>)?
│
│  ▸ Accept?
│  1. Yes
│  2. No -- just import the package
╰─
```

```bash
gh api "/user/repository_invitations/$INVITATION_ID" -X PATCH 2>&1
```

If no invitation exists, inform the human:

```
╭─ 🐿️ no invitation yet
│
│  No pending relay invitation from <relay.sender>.
│  They may not have invited you yet. Ask them to run:
│  /alive:relay peer add <your-github-username>
│
│  Continuing with package import.
╰─
```

3. **Fetch sender's public key from their relay:**

Use the validated `relay.repo` from the manifest (not a hardcoded repo name):

```bash
mkdir -p "$WORLD_ROOT/.alive/relay-keys/peers"
PEER_PEM="$WORLD_ROOT/.alive/relay-keys/peers/<relay.sender>.pem"

# Fetch key -- redirect stderr to console, only stdout goes to file
gh api "repos/<relay.repo>/contents/keys/<relay.sender>.pem" \
  --jq '.content' 2>/dev/null | (base64 -d 2>/dev/null || base64 -D) > "$PEER_PEM"

# Validate the fetched key file
if [ -s "$PEER_PEM" ] && head -1 "$PEER_PEM" | grep -q "BEGIN PUBLIC KEY"; then
  echo "KEY_FETCHED"
else
  rm -f "$PEER_PEM"
  echo "KEY_FAILED"
fi
```

If the key fetch fails (404, network error, or invalid key content), warn but continue -- the peer may not have committed their public key yet:

```
╭─ 🐿️ heads up
│
│  Couldn't fetch <relay.sender>'s public key from their relay.
│  Encryption won't work until their key is available.
│  Check again later with /alive:relay status.
╰─
```

4. **Add sender as peer in relay.yaml** (create relay.yaml if it doesn't exist):

If no relay.yaml exists, write a minimal config that records the peer relationship. Note: `relay.repo` and `relay.local` are left empty because the user's own relay doesn't exist yet. This config tracks the peer connection only -- automatic pull requires `/alive:relay setup` to populate the full config:

```bash
python3 - "$WORLD_ROOT/.alive/relay.yaml" "$GITHUB_USERNAME" "<relay.sender>" "<relay.repo>" << 'PYEOF'
import sys, datetime, re

config_path = sys.argv[1]
username = sys.argv[2]
peer_owner = sys.argv[3]
peer_relay = sys.argv[4]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
today = datetime.date.today().isoformat()

# Sanitize peer values (already validated, but defense in depth)
safe_owner = re.sub(r'[^a-zA-Z0-9-]', '', peer_owner)[:39]
safe_relay = re.sub(r'[^a-zA-Z0-9./_-]', '', peer_relay)[:100]

yaml_content = f"""relay:
  repo: ""
  local: ""
  github_username: "{username}"
  private_key: ""
  public_key: ""
  last_sync: "{now}"
  last_commit: ""
peers:
  - github: "{safe_owner}"
    name: "{safe_owner}"
    relay: "{safe_relay}"
    person_walnut: ""
    added: "{today}"
    status: "accepted"
"""

with open(config_path, "w") as f:
    f.write(yaml_content)

print(f"Written: {config_path}")
PYEOF
```

If relay.yaml already exists but the sender isn't a peer, append them to the peer list using the same Python append logic from the relay skill.

5. **Create or update sender's person walnut** at `02_Life/people/<sender-slug>/` with `github:` and `relay:` fields in key.md. Same as relay peer add Step 9.

6. **Offer to create own relay:**

```
╭─ 🐿️ relay setup
│
│  You've accepted <relay.sender>'s relay invite and saved their key.
│  They can push encrypted packages to you once you have your own relay.
│
│  To receive packages automatically (and send back), create your relay:
│
│  ▸ Create your relay now?
│  1. Yes -- run /alive:relay setup
│  2. Later -- I'll set it up when I need to
╰─
```

If yes, run the full `/alive:relay setup` flow. Setup will populate the empty `relay.repo`, `relay.local`, `private_key`, and `public_key` fields in relay.yaml while preserving the existing peer list. After setup completes, push own public key to the sender's relay:

```bash
PUBLIC_KEY_B64=$(base64 < "$WORLD_ROOT/.alive/relay-keys/public.pem" | tr -d '\n')
gh api "repos/<relay.repo>/contents/keys/$GITHUB_USERNAME.pem" \
  -X PUT \
  -f message="Add public key for $GITHUB_USERNAME" \
  -f content="$PUBLIC_KEY_B64" 2>&1
```

7. **Confirm and continue with import:**

If own relay was created (full setup completed):

```
╭─ 🐿️ relay connected
│
│  Connected to <relay.sender>'s relay.
│  Bidirectional relay active -- packages will be encrypted automatically.
│
│  Continuing with package import...
╰─
```

If "Later" was chosen (peer tracked, but no own relay yet):

```
╭─ 🐿️ peer saved
│
│  Saved <relay.sender> as a relay peer.
│  Run /alive:relay setup when you're ready for automatic delivery.
│
│  Continuing with package import...
╰─
```

Stash the bootstrap event:

```
╭─ 🐿️ +1 stash (N)
│  Joined relay from <relay.sender> via bootstrap -- <relay.repo>
│  → drop?
╰─
```

After bootstrap (or if the human chose "No"), continue to Step 2.

---

### Step 2 -- Encryption Detection and Decryption

Check if the extracted staging directory contains `payload.enc`. If yes, the content is encrypted. Also check for `payload.key` to determine the encryption mode.

```bash
if [ -f "$STAGING/payload.enc" ] && [ -f "$STAGING/payload.key" ]; then
  echo "RSA_ENCRYPTED"
elif [ -f "$STAGING/payload.enc" ]; then
  echo "PASSPHRASE_ENCRYPTED"
else
  echo "CLEARTEXT"
fi
```

**If CLEARTEXT:** The content files are already extracted alongside the manifest. Proceed to Step 3.

**If RSA_ENCRYPTED (payload.enc + payload.key):**

This is a relay package encrypted with the recipient's RSA public key. Auto-decrypt using the local private key -- no passphrase prompt needed.

Locate the private key by reading `relay.private_key` from `.alive/relay.yaml`:

```bash
PRIVATE_KEY_REL=$(grep '^ *private_key:' "$WORLD_ROOT/.alive/relay.yaml" 2>/dev/null | head -1 | sed 's/^.*private_key: *"*\([^"]*\)"*/\1/' | tr -d '[:space:]')
if [ -n "$PRIVATE_KEY_REL" ]; then
  PRIVATE_KEY="$WORLD_ROOT/$PRIVATE_KEY_REL"
else
  PRIVATE_KEY="$WORLD_ROOT/.alive/relay-keys/private.pem"
fi
test -f "$PRIVATE_KEY" && echo "KEY_FOUND" || echo "KEY_MISSING"
```

If the private key is found, decrypt:

```bash
# 1. Unwrap AES key with local RSA private key
AES_KEY=$(mktemp "/tmp/walnut-aes-XXXXXXXX.key")
openssl pkeyutl -decrypt -inkey "$PRIVATE_KEY" \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
  -in "$STAGING/payload.key" -out "$AES_KEY"

if [ $? -ne 0 ]; then
  echo "RSA_DECRYPT_FAILED"
  rm -f "$AES_KEY"
else
  echo "AES_KEY_UNWRAPPED"
fi
```

If key unwrap succeeds, decrypt the payload:

```bash
# 2. Decrypt payload with unwrapped AES key
INNER_TAR=$(mktemp "/tmp/walnut-inner-XXXXXXXX.tar.gz")
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "$STAGING/payload.enc" \
  -out "$INNER_TAR" \
  -pass "file:$AES_KEY"

if [ $? -ne 0 ]; then
  echo "PAYLOAD_DECRYPT_FAILED"
  rm -f "$INNER_TAR"
else
  echo "DECRYPTED"
fi

# 3. Securely delete the plaintext AES key
rm -P "$AES_KEY" 2>/dev/null || rm "$AES_KEY"
```

On success, extract the inner archive and clean up:

```bash
# Extract inner archive content into staging using safe extraction
python3 -c '<SAFE_EXTRACT_SCRIPT>' "$STAGING" "$INNER_TAR"

# Clean up: remove payload.enc, payload.key, and inner tar
rm -f "$INNER_TAR" "$STAGING/payload.enc" "$STAGING/payload.key"
```

If RSA decryption fails (key unwrap or payload decrypt), the private key does not match. This happens when the local keypair was regenerated after the sender encrypted the package, or the package was encrypted for a different recipient:

```
╭─ 🐿️ RSA decryption failed
│
│  Couldn't decrypt with your local RSA key.
│  The package was encrypted with your RSA public key
│  but your current private key doesn't match.
│
│  This can happen if you regenerated your keypair.
│  Ask the sender to re-share the package.
│
│  ▸ Abort?
│  1. Yes -- cancel import
│  2. No -- I have more context (explain)
╰─
```

Abort the import. Clean up staging. Do NOT offer passphrase fallback -- relay RSA packages have no passphrase and attempting passphrase decryption on RSA-encrypted content will always fail with confusing errors.

If the private key is missing (no relay configured locally):

```
╭─ 🐿️ encrypted package (RSA)
│
│  This package uses RSA encryption (relay transport).
│  No local RSA private key found.
│
│  To decrypt relay packages, set up your relay:
│  /alive:relay setup
│
│  Or ask the sender to re-share with passphrase encryption.
╰─
```

Abort the import. Clean up staging.

**If PASSPHRASE_ENCRYPTED (payload.enc only):**

Collect the passphrase through the session:

```
╭─ 🐿️ encrypted package
│
│  This package is encrypted.
│
│  ▸ Enter the passphrase:
╰─
```

Decrypt `payload.enc` to a temporary inner archive, then extract it into the staging directory:

```bash
# Decrypt the payload
INNER_TAR=$(mktemp "/tmp/walnut-inner-XXXXXXXX.tar.gz")
WALNUT_PASSPHRASE="<passphrase-from-session>" \
  openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
  -in "$STAGING/payload.enc" \
  -out "$INNER_TAR" \
  -pass env:WALNUT_PASSPHRASE

if [ $? -ne 0 ]; then
  echo "DECRYPTION_FAILED"
  rm -f "$INNER_TAR"
else
  echo "DECRYPTED"
fi
```

If decryption fails, surface it and offer to retry:

```
╭─ 🐿️ decryption failed
│
│  Wrong passphrase or corrupted package.
│
│  ▸ Try again?
│  1. Yes
│  2. Cancel
╰─
```

On success, extract the inner archive into staging (same Python validation), then clean up:

```bash
# Extract inner archive content into staging using safe extraction
python3 -c '<SAFE_EXTRACT_SCRIPT>' "$STAGING" "$INNER_TAR"

# Clean up: remove payload.enc and inner tar
rm -f "$INNER_TAR" "$STAGING/payload.enc"
```

After this step, the staging directory looks the same regardless of encryption mode: `manifest.yaml` + content files. All subsequent steps are identical.

**Passphrase handling:** The passphrase MUST be passed via `env:` (environment variable), never as a CLI argument (visible in `ps`) or written to a file. The `WALNUT_PASSPHRASE=... openssl ...` syntax sets it for that single command only.

**AES key handling:** The unwrapped AES key MUST be securely deleted after use. `rm -P` overwrites before deletion on macOS. Falls back to `rm` on Linux.

---

### Step 3 -- Post-Extraction Safety Validation (defense in depth)

**This is a security requirement. Do NOT skip.**

Step 2 already validates archive members via Python's `tarfile` and only extracts regular files and directories. This step is defense-in-depth -- it walks the extracted filesystem to catch anything unexpected:

```bash
python3 -c '
import os, sys, stat

staging = sys.argv[1]
staging_real = os.path.realpath(staging)
violations = []

for root, dirs, files in os.walk(staging, followlinks=False):
    for name in dirs + files:
        full = os.path.join(root, name)
        rel = os.path.relpath(full, staging)
        if ".." in rel.split(os.sep):
            violations.append(f"Path traversal: {rel}")
        if os.path.islink(full):
            target = os.readlink(full)
            violations.append(f"Symlink rejected: {rel} -> {target}")
            continue
        st = os.lstat(full)
        if not (stat.S_ISREG(st.st_mode) or stat.S_ISDIR(st.st_mode)):
            violations.append(f"Special file rejected: {rel} (mode {oct(st.st_mode)})")
        real = os.path.realpath(full)
        if real != staging_real and not real.startswith(staging_real + os.sep):
            violations.append(f"Path escape: {rel} resolves to {real}")

if violations:
    for v in violations:
        print(v, file=sys.stderr)
    sys.exit(1)
print("All paths safe.")
' "$STAGING"
```

If any violations are found, abort the import and clean up staging:

```
╭─ 🐿️ import blocked
│
│  This package contains unsafe paths:
│  - [violation details]
│
│  Import aborted. The package may be corrupted or malicious.
╰─
```

```bash
rm -rf "$STAGING"
```

---

### Step 4 -- Manifest Validation

Read `manifest.yaml` from the staging root. **Do NOT `cat` directly** -- manifest content is untrusted. Read via Python and strip control characters before displaying:

```bash
python3 -c '
import sys
with open(sys.argv[1]) as f:
    text = f.read()
# Strip ASCII control chars (C0 except \n and \t, DEL, C1 range)
# \r is NOT allowed (can rewrite prior terminal content)
cleaned = "".join(c if (c in "\n\t" or 0x20 <= ord(c) < 0x7f or ord(c) > 0x9f) else "?" for c in text)
print(cleaned)
' "$STAGING/manifest.yaml"
```

#### 4a. Format version check

Parse `format_version` from the manifest. Check the major version:

- **Major version matches** (currently `1.x.x`) -- proceed.
- **Major version mismatch** -- block:

```
╭─ 🐿️ import blocked
│
│  This package uses format version X.Y.Z.
│  This plugin supports version 1.x.x.
│
│  A newer version of the ALIVE plugin may be required.
╰─
```

- **Minor version ahead** (e.g. package is `1.3.0`, plugin supports `1.0.0`) -- warn but proceed:

```
╭─ 🐿️ heads up
│
│  This package uses format version 1.3.0 (newer than this plugin's 1.0.0).
│  Some optional features may not be recognized. Proceeding anyway.
╰─
```

#### 4b. Plugin version check

Parse `source.plugin_version` from the manifest. Compare the major version against the installed plugin's major version.

- **Major mismatch** -- block with a clear message about updating the plugin.
- **Match** -- proceed.

#### 4c. SHA-256 checksum and size validation

**Note on scope:** Checksums detect transit corruption and accidental modification. They do NOT provide authenticity -- a malicious sender can craft valid checksums. This is a known limitation of v1. Future versions may add signatures.

Validate every file listed in `manifest.files` against its `sha256` checksum and `size`:

```bash
python3 -c '
import hashlib, sys, os, re, stat

MAX_FILE_SIZE = 500 * 1024 * 1024  # 500 MB per file
MAX_TOTAL_SIZE = 2 * 1024 * 1024 * 1024  # 2 GB total

staging = os.path.realpath(sys.argv[1])
manifest_path = os.path.join(staging, "manifest.yaml")

with open(manifest_path) as f:
    manifest_text = f.read()

# Regex matches the manifest template exact structure (avoids PyYAML dependency).
# CONSTRAINT: manifest must use LF line endings, lowercase hex sha256, exact key
# ordering (path/sha256/size), and standard YAML quoting. The share skill enforces
# this format. If a manifest uses different formatting, this fails closed (no entries = abort).
ENTRY_RE = re.compile(
    r"- path: \"?([^\"\n]+)\"?\n\s+sha256: \"?([a-f0-9]{64})\"?\n\s+size: (\d+)"
)
entries = []
for m in ENTRY_RE.finditer(manifest_text):
    raw_path = m.group(1).strip()
    norm_path = os.path.normpath(raw_path)
    while norm_path.startswith("./"):
        norm_path = norm_path[2:]
    entries.append({"path": norm_path, "sha256": m.group(2), "size": int(m.group(3))})

errors = []
verified = 0

if not entries:
    print("No file entries found in manifest -- may be malformed or empty.", file=sys.stderr)
    sys.exit(1)

declared_total = sum(e["size"] for e in entries)
if declared_total > MAX_TOTAL_SIZE:
    print(f"Package declares {declared_total} bytes total -- exceeds {MAX_TOTAL_SIZE} byte cap.", file=sys.stderr)
    sys.exit(1)

for entry in entries:
    path = entry["path"]
    if os.path.isabs(path) or ".." in path.split("/"):
        errors.append(f"Unsafe manifest path: {path}")
        continue
    fpath = os.path.normpath(os.path.join(staging, path))
    if not fpath.startswith(staging + os.sep):
        errors.append(f"Path escape via manifest: {path}")
        continue
    if not os.path.exists(fpath):
        errors.append(f"Missing: {path}")
        continue
    st = os.lstat(fpath)
    if not stat.S_ISREG(st.st_mode):
        errors.append(f"Not a regular file: {path} (mode {oct(st.st_mode)})")
        continue
    actual_size = st.st_size
    if actual_size != entry["size"]:
        errors.append(f"Size mismatch: {path} (expected {entry['size']}, got {actual_size})")
        continue
    if actual_size > MAX_FILE_SIZE:
        errors.append(f"File too large: {path} ({actual_size} bytes)")
        continue
    h = hashlib.sha256()
    with open(fpath, "rb") as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    if h.hexdigest() != entry["sha256"]:
        errors.append(f"Checksum mismatch: {path}")
    else:
        verified += 1

listed_paths = {e["path"] for e in entries}
for root, dirs, files in os.walk(staging):
    for name in files:
        full = os.path.join(root, name)
        rel = os.path.normpath(os.path.relpath(full, staging))
        while rel.startswith("./"):
            rel = rel[2:]
        if rel == "manifest.yaml":
            continue
        if rel not in listed_paths:
            errors.append(f"Unlisted file: {rel}")

if errors:
    for e in errors:
        print(e, file=sys.stderr)
    sys.exit(1)
print(f"{verified} files verified.")
' "$STAGING"
```

If any checksums fail, sizes mismatch, or files are missing/unlisted, show the errors and abort:

```
╭─ 🐿️ integrity check failed
│
│  [error details]
│
│  Import aborted. The package may have been corrupted in transit.
╰─
```

Clean up staging on any failure.

---

### Step 5 -- Content Preview

**Display safety:** All manifest fields (`source.walnut`, `description`, `note`, capsule names) and `.walnut.meta` content are untrusted input from the sender. Before displaying any string from these sources in bordered blocks, strip control characters: reject anything below U+0020 except `\n` and `\t` (NOT `\r` -- carriage return can rewrite prior terminal content), plus DEL (U+007F) and C1 range (U+0080-U+009F). Replace stripped chars with `?` or omit. Apply the same sanitization in Step 1 (meta preview).

Read the manifest and show what's inside:

```
╭─ 🐿️ package contents
│
│  Source:     nova-station
│  Scope:     capsule
│  Capsules:  shielding-review, safety-brief
│  Files:     12
│  Created:   2026-03-26T12:00:00Z
│  Encrypted: yes (decrypted successfully)
│
│  Description: Evaluate radiation shielding vendors for habitat module
│
│  Note: "Two capsules from the shielding review -- one still in draft."
│
│  ▸ Proceed with import?
│  1. Yes
│  2. Cancel
╰─
```

If any capsules have `sensitivity: restricted` or `pii: true`, surface prominently:

```
╭─ 🐿️ sensitivity notice
│
│  vendor-analysis has pii: true
│  safety-brief has sensitivity: restricted
│
│  These flags were set by the sender. Review content carefully.
╰─
```

---

### Step 6 -- Target Selection

Routing depends on scope. **All target paths MUST resolve inside the world root.** Before writing anything, verify:

```bash
python3 -c '
import os, sys
target = os.path.realpath(sys.argv[1])
world = os.path.realpath(sys.argv[2])
try:
    common = os.path.commonpath([target, world])
except ValueError:
    common = ""
if common != world or target == world:
    print(f"Target {target} is not inside world root {world}", file=sys.stderr)
    sys.exit(1)
print("Target path validated.")
' "<target-path>" "<world-root>"
```

#### Full scope

Always creates a new walnut. Ask which ALIVE domain:

```
╭─ 🐿️ import target
│
│  Full walnut import creates a new walnut.
│
│  ▸ Which domain?
│  1. 02_Life/
│  2. 04_Ventures/
│  3. 05_Experiments/
╰─
```

The walnut name defaults to the source walnut name from the manifest. If a walnut with that name already exists in the chosen domain, ask:

```
╭─ 🐿️ name collision
│
│  A walnut named "nova-station" already exists at 04_Ventures/nova-station/.
│
│  ▸ What to do?
│  1. Rename -- pick a new name
│  2. Cancel
╰─
```

No merge for MVP. Full import always creates fresh.

#### Capsule scope

Import into an existing walnut or create a new one.

**Step 1: Smart source matching.** Before presenting any list, check if a walnut matching the manifest's `source.walnut` name already exists in the world. Search recursively with no depth limit:

```bash
find <world-root>/02_Life <world-root>/04_Ventures <world-root>/05_Experiments \
  -name "key.md" -path "*/_core/key.md" 2>/dev/null | while read f; do
  dir=$(dirname "$(dirname "$f")")
  name=$(basename "$dir")
  echo "$name $dir"
done
```

If a walnut matching the source name is found, suggest it as the default:

```
╭─ 🐿️ import target
│
│  This capsule came from merchgirls.
│  Found matching walnut: 04_Ventures/supernormal-systems/clients/merchgirls/
│
│  ▸ Import here, or choose another?
│  1. Yes -- import into merchgirls (recommended)
│  2. Pick a different walnut
│  3. Create a new walnut for this capsule
╰─
```

If no matching walnut exists:

```
╭─ 🐿️ import target
│
│  No walnut named "nova-station" found in your world.
│
│  ▸ Where should this capsule go?
│  1. Create a new walnut named "nova-station"
│  2. Import into an existing walnut
╰─
```

**Step 2: Walnut list (if needed).** Scan ALL ALIVE domains recursively for directories containing `_core/key.md` -- no depth limit. Present as a nested list showing sub-walnuts indented under their parents:

```
╭─ 🐿️ pick a walnut
│
│  Ventures:
│  1. building-certifiers
│  2. supernormal-systems
│     2a. clients/merchgirls
│     2b. clients/customs-brokers
│  3. stackwalnuts
│
│  Experiments:
│  4. safe-childcare
│
│  ▸ Which walnut? (number or path)
╰─
```

To build the nested list: for each walnut found, compute its path relative to the ALIVE domain folder. If a walnut's relative path contains more than one segment (e.g. `supernormal-systems/clients/merchgirls`), it's a sub-walnut -- indent it under its parent with a letter suffix.

**Step 3: Create new walnut (if chosen).** If the human picks "Create a new walnut", ask which ALIVE domain:

```
╭─ 🐿️ new walnut
│
│  ▸ Which domain for the new walnut?
│  1. 02_Life/
│  2. 04_Ventures/
│  3. 05_Experiments/
╰─
```

Then scaffold the walnut using the source walnut's `key.md` from the package (already in staging at `$STAGING/_core/key.md`). Create the standard `_core/` structure with the 5 system files. The capsule gets imported into the new walnut's `_core/_capsules/`.

**Step 4: Multi-capsule routing.** If the package contains multiple capsules, default all to the chosen walnut. Offer per-capsule override:

```
╭─ 🐿️ capsule routing
│
│  Importing 2 capsules into [target-walnut]:
│  1. shielding-review
│  2. safety-brief
│
│  ▸ All to [target-walnut], or route individually?
│  1. All to [target-walnut]
│  2. Route each separately
╰─
```

#### Snapshot scope

Read-only view. Show the content without creating or modifying anything:

```
╭─ 🐿️ snapshot from nova-station
│
│  This is a read-only status briefing. Nothing will be written.
│
│  [Show key.md goal, now.md context paragraph, insights frontmatter]
│
│  ▸ Done viewing, or capture as a reference?
│  1. Done
│  2. Capture into a walnut as a reference
╰─
```

If the human picks "Capture as a reference", ask which walnut, then write the snapshot content as a companion in `_core/_references/snapshots/` with type `snapshot`.

---

### Step 7 -- Content Routing

This is the core write step. Behavior depends on scope.

#### 7a. Full scope -- Create new walnut

Follow the walnut scaffolding pattern from `skills/create/SKILL.md`:

1. Create the directory structure at `<domain>/<walnut-name>/`
2. Copy `_core/` contents from staging to the new walnut's `_core/` using safe rsync:
   ```bash
   rsync -rt --no-links --no-specials --no-devices -- "$STAGING/_core/" "<target-walnut>/_core/"
   ```
   This strips foreign permissions/ownership and rejects any special files that survived extraction.
3. Create `_core/_capsules/` if not present in the package

**Handle log.md via bash** (the log guardian hook blocks Write tool on log.md; Edit is allowed for prepending new entries but NOT for modifying signed entries):

If the package includes `_core/log.md`, write the entire file via bash first (this is a new walnut, so no existing signed entries to protect):

```bash
cat -- "$STAGING/_core/log.md" > "<target-walnut>/_core/log.md"
```

Then prepend an import entry at the top of the log (after frontmatter) using the Edit tool (this is a new unsigned entry, which the log guardian allows):

The import entry:

```markdown
## <ISO-timestamp> -- squirrel:<session_id>

Walnut imported from .walnut package. Source: <source-walnut> (packaged <created-date>).

### References Captured
- walnut-package: <original-filename> -- imported into <domain>/<walnut-name>/

signed: squirrel:<session_id>
```

Update the log.md frontmatter (`last-entry`, `entry-count`, `summary`) via Edit.

**Replace @session_id in tasks.md:**

If the package includes `_core/tasks.md`, replace foreign `@session_id` references with `@[source-walnut-name]`:

```bash
python3 -c '
import re, sys, pathlib
tasks_path = sys.argv[1]
source = sys.argv[2]
# Sanitize source name to prevent regex replacement backrefs
safe_source = re.sub(r"[^a-z0-9_-]", "-", source.lower())
text = pathlib.Path(tasks_path).read_text(encoding="utf-8", errors="replace")
updated = re.sub(r"@([0-9a-f]{6,})", lambda m: f"@[{safe_source}]", text)
pathlib.Path(tasks_path).write_text(updated, encoding="utf-8")
' "<target-walnut>/_core/tasks.md" "<source-walnut-name>"
```

**Update now.md** with import context via Edit:
- Set `squirrel:` to the current session_id
- Set `updated:` to now
- Keep the existing `phase:` and `next:`

#### 7b. Capsule scope -- Route into existing walnut

For each capsule being imported:

1. **Check for name collision** -- does `_core/_capsules/<capsule-name>/` already exist?

If collision:

```
╭─ 🐿️ name collision
│
│  A capsule named "shielding-review" already exists in [target-walnut].
│
│  ▸ What to do?
│  1. Rename -- pick a new name for the imported capsule
│  2. Replace -- overwrite existing capsule
│  3. Skip -- don't import this capsule
╰─
```

2. **Copy capsule directory** from staging to `<target-walnut>/_core/_capsules/<capsule-name>/`

If the human chose "Replace" for a name collision, remove the existing capsule first:

```bash
# Only for "Replace" -- remove old capsule before copying new one
rm -rf "<target-walnut>/_core/_capsules/<capsule-name>"
```

Then copy (same for new capsules and replacements):

```bash
mkdir -p -- "<target-walnut>/_core/_capsules/<capsule-name>"
rsync -rt --no-links --no-specials --no-devices -- "$STAGING/_core/_capsules/<capsule-name>/" "<target-walnut>/_core/_capsules/<capsule-name>/"
```

Using `-rt` (recursive + timestamps) instead of `-a` avoids preserving foreign permissions, ownership, and group from the package. `--no-links --no-specials --no-devices` is defense-in-depth -- Step 2 already filtered these out, but this prevents accidental copies if the staging dir is modified between extraction and routing.

3. **Add `received_from:` to the capsule companion** -- edit `companion.md` to add provenance:

```yaml
received_from:
  source_walnut: "<source-walnut-name>"
  method: "walnut-package"
  date: <YYYY-MM-DD>
  package: "<original-filename>"
```

Use the Edit tool on the companion's frontmatter to add this field.

4. **Replace @session_id in tasks within capsule** (if any task-like content exists in version files):

Foreign `@session_id` references are replaced with `@[source-walnut-name]` -- same pattern as full scope.

5. **Flag unknown people** -- scan the imported companion for `people:` or person references (`[[name]]`). If any referenced people don't have walnuts in `02_Life/people/`, stash them:

```
╭─ 🐿️ +1 stash (N)
│  Unknown person referenced in imported capsule: [[kai-tanaka]]
│  → drop?
╰─
```

#### 7c. Snapshot scope -- Capture as reference (optional)

Only if the human chose "Capture as a reference" in Step 6.

Create a companion in the target walnut's `_core/_references/snapshots/`:

```bash
mkdir -p -- "<target-walnut>/_core/_references/snapshots"
```

Write a companion file:

```markdown
---
type: snapshot
description: "<source-walnut> status snapshot -- <description from manifest>"
source_walnut: "<source-walnut-name>"
date: <created-date-from-manifest>
received: <today's-date>
squirrel: <session_id>
tags: [imported, snapshot]
---

## Summary

Status snapshot from [[<source-walnut-name>]].

## Key Identity

[Contents of key.md from staging]

## Current State

[Contents of now.md from staging]

## Domain Knowledge

[Contents of insights.md from staging]

## Source

Imported from .walnut package: <original-filename>
```

---

### Step 8 -- Cleanup

**If relay-sourced (`RELAY_SOURCE=true`):** Skip the file archival below. Relay package cleanup (git rm + push) is handled by entry point 3e after the full receive flow completes. Only clean up the staging directory.

**If not relay-sourced:** Move the original `.walnut` file from its current location to the archive. If the file came from `03_Inputs/`, move it to `01_Archive/03_Inputs/`:

Only auto-archive files that came from `03_Inputs/`. Files from other locations (e.g. Desktop) are left where the human put them.

```bash
# Use pwd -P (physical, no symlinks) for reliable containment check
PACKAGE_REAL="$(cd "$(dirname "<package-path>")" && pwd -P)/$(basename "<package-path>")"
INPUTS_DIR="$(cd "<world-root>/03_Inputs" 2>/dev/null && pwd -P)"

# Only archive if the package is inside 03_Inputs/ (or a subdirectory)
case "$PACKAGE_REAL" in
  "$INPUTS_DIR"/*)
    SHOULD_ARCHIVE=true ;;
  *)
    SHOULD_ARCHIVE=false ;;
esac

if [ "$SHOULD_ARCHIVE" = "true" ]; then
  ARCHIVE_DIR="<world-root>/01_Archive/03_Inputs"
  mkdir -p -- "$ARCHIVE_DIR"
  TIMESTAMP=$(date +%Y%m%d-%H%M%S)

  BASENAME="$(basename "<package-path>")"
  if [ -e "$ARCHIVE_DIR/$BASENAME" ]; then
    case "$BASENAME" in
      *.walnut) STEM="${BASENAME%.walnut}"; EXT="walnut" ;;
      *) STEM="${BASENAME%.*}"; EXT="${BASENAME##*.}" ;;
    esac
    BASENAME="${STEM}-${TIMESTAMP}.${EXT}"
  fi
  mv -- "<package-path>" "$ARCHIVE_DIR/$BASENAME"
fi
```

Clean up the staging directory:

```bash
rm -rf "$STAGING"
```

---

### Step 9 -- Stash & Summary

Stash the import event for logging at next save:

```
╭─ 🐿️ +1 stash (N)
│  Imported [scope] package from [source-walnut]: [capsule names or "full walnut"] into [target]
│  → drop?
╰─
```

Show the final summary:

**Full scope:**

```
╭─ 🐿️ imported
│
│  Walnut: 04_Ventures/nova-station/
│  Source: nova-station (packaged 2026-03-26)
│  Files:  23 files imported
│  Scope:  full
│
│  The walnut is alive. Open it with /alive:load nova-station.
╰─
```

**Capsule scope:**

```
╭─ 🐿️ imported
│
│  Target: [target-walnut]
│  Capsules imported:
│    - shielding-review (12 files)
│    - safety-brief (4 files)
│  Source: nova-station
│
│  Open the walnut with /alive:load [target-walnut].
╰─
```

**Snapshot scope (viewed only):**

```
╭─ 🐿️ snapshot viewed
│
│  Source: nova-station
│  No files written.
╰─
```

**Snapshot scope (captured as reference):**

```
╭─ 🐿️ imported
│
│  Snapshot captured as reference in [target-walnut].
│  File: _core/_references/snapshots/<date>-<source>-snapshot.md
│  Source: nova-station
╰─
```

---

### Step 10 -- Post-import

Offer to open the imported content:

```
╭─ 🐿️ next
│
│  ▸ Open [walnut-name] now?
│  1. Yes -- /alive:load [name]
│  2. No -- stay here
╰─
```

For capsule imports, offer to open the target walnut (not the capsule directly -- capsules are opened via the walnut).

---

## Edge Cases

**Encrypted package with wrong passphrase:** The openssl decryption will fail. Offer to retry with a different passphrase.

**Empty capsule (companion only, no raw/drafts):** Import it. The companion context has value on its own.

**Cross-capsule relative paths in sources:** Preserve as-is. They're historical metadata. The paths will reference capsules that may not exist in the target walnut -- that's fine.

**Duplicate import (same package imported twice):** For MVP, just import again. The name collision handler (Step 7b) catches capsule conflicts. Let the human decide rename/replace/skip.

**Package with no `manifest.yaml`:** This is not a valid `.walnut` package. Show an error:

```
╭─ 🐿️ invalid package
│
│  No manifest.yaml found. This doesn't appear to be a valid .walnut package.
│  A .walnut file must contain manifest.yaml at its root.
╰─
```

**Corrupted archive (tar extraction fails):** Catch the error and report:

```
╭─ 🐿️ extraction failed
│
│  Could not extract the archive. It may be corrupted or not a valid .walnut file.
│  Error: [tar error message]
╰─
```

**Multiple `.walnut` files in `03_Inputs/`:** The inbox scan in capture handles this by listing all items. Each `.walnut` file is processed individually via a separate receive invocation.

**Package contains files outside `_core/`:** The format spec says packages contain `_core/` contents. Files outside `_core/` in the archive are flagged as unexpected in checksum validation (Step 4c, "unlisted file" check) and excluded.

**Relay pull -- inbox path convention:** This skill scans `inbox/<own-username>/` on the local relay clone, matching the sparse checkout configuration and the session-start hook. The share skill's push path must deliver packages to this same location on the recipient's relay. If packages are not appearing despite successful pushes, verify that `alive:share` pushes to `inbox/<recipient-username>/` (not `inbox/<sender-username>/`) on the recipient's relay.

**Relay pull -- empty inbox after git pull:** The hook detected packages but they were cleaned up between hook run and pull (race with another session). Show "relay inbox empty" and exit cleanly.

**Relay pull -- git push cleanup fails:** The import succeeded but cleanup push failed (network error, auth expired). Warn but don't block. The packages stay in the remote inbox until the next successful push.

**Relay pull -- private key regenerated:** If the local private key was regenerated after a peer encrypted a package with the old public key, RSA decryption fails. The fallback to passphrase mode won't work either (relay packages don't have passphrases). The package is unrecoverable -- inform the human to ask the sender to re-share.

**Relay pull -- unknown sender:** If a package appears in the relay inbox from someone not in the peer list, warn before processing:

```
╭─ 🐿️ unknown sender
│
│  Package from unknown sender in relay inbox: <filename>
│  Anyone with push access to your relay can deliver packages.
│
│  ▸ Process or skip?
│  1. Process -- import the package
│  2. Skip -- leave it in the inbox
╰─
```

**Bootstrap -- sender hasn't invited yet:** The relay: field is in the manifest but no pending GitHub invitation exists. Inform the human and continue with the import. They can run `/alive:relay peer accept` later when the invitation arrives.

**Bootstrap -- offline during join:** If `gh api` calls fail during bootstrap, skip the relay join silently and continue with the package import. The human can join later.

**RSA decryption -- payload.key present but decrypt fails:** If `RELAY_SOURCE=true` (package from relay inbox), abort the import -- relay packages are always RSA-encrypted and passphrase fallback is not applicable. If `RELAY_SOURCE=false` (manually received package that happens to have `payload.key`), abort with guidance to ask sender to re-share. In no case offer passphrase fallback for packages containing `payload.key` -- the passphrase mode and RSA mode are mutually exclusive encryption paths.

---

## Scope Summary (Quick Reference)

| Scope | Creates | Target | User picks | Writes to log |
|-------|---------|--------|------------|---------------|
| **full** | New walnut | ALIVE domain | Domain | Via bash (new walnut) |
| **capsule** | Capsule dirs | Existing walnut | Walnut + optional per-capsule | Via stash (at save) |
| **snapshot** | Nothing (or reference) | View-only (or existing walnut) | View or capture | Via stash (if captured) |
