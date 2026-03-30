---
description: "Package walnut context into a portable .walnut file for sharing via any channel -- email, AirDrop, Slack, USB. Supports three scopes (full, capsule, snapshot), sensitivity gating, optional passphrase encryption, and relay push for automatic delivery to peers."
user-invocable: true
---

# Share

Package walnut context for someone else. The export side of P2P sharing.

A `.walnut` file is a gzip-compressed tar archive with a manifest. Three scopes: full walnut handoff, capsule-level sharing, or a lightweight snapshot for status updates. Optional passphrase encryption via `openssl` -- fully session-driven, no terminal interaction required.

**Single file output:** A `.walnut` file is always one file. For encrypted packages, the manifest stays cleartext inside the archive (so the recipient can preview source/scope/note before decrypting) and the actual content is an encrypted blob (`payload.enc`) alongside it.

**Relay push (optional):** When a relay is configured (`.alive/relay.yaml` exists with accepted peers), the skill offers to push the package to a peer's relay after packaging. The relay push uses RSA encryption with the peer's public key and the GitHub Contents API -- no passphrases needed. The local `.walnut` file is still created as before; relay is additive.

The skill runs in the current walnut by default. If a walnut name is provided as an argument, operate on that walnut instead -- read its `_core/` before proceeding.

---

## Prerequisites

Read the format spec before generating any package. The templates are at these **exact paths** relative to the plugin install root:

```
templates/walnut-package/format-spec.md    -- full format specification
templates/walnut-package/manifest.yaml     -- manifest template with field docs
```

The squirrel MUST read both files before packaging. Do not reconstruct the manifest schema from memory. Do NOT spawn an Explore agent or search for these files -- the paths above are authoritative.

---

## Flow

### Step 1 -- Scope Selection

```
╭─ 🐿️ share
│
│  What are you sharing from [walnut-name]?
│
│  ▸ Scope
│  1. Full walnut -- entire _core/ (creates new walnut on import)
│  2. Capsule -- one or more work/reference capsules
│  3. Snapshot -- key + now + insights (read-only status briefing)
╰─
```

If the walnut has no capsules in `_core/_capsules/`, suppress option 2.

---

### Step 2 -- Capsule Picker (capsule scope only)

Read all `_core/_capsules/*/companion.md` frontmatter. Present capsules grouped by status -- active capsules (draft, prototype, published) first, then done capsules in a separate section. Show sensitivity status prominently for each.

```
╭─ 🐿️ pick capsules
│
│  Active:
│  1. shielding-review    draft       private
│  2. vendor-analysis     prototype   private      pii: true ⚠
│
│  Done:
│  3. safety-brief        done        restricted ⚠
│
│  ▸ Which ones? (number, several "1,3", or "all")
╰─
```

Multi-select is allowed. Multiple capsules go into one package. Done capsules are still selectable -- they're just shown separately so the human knows what's current vs historical.

---

### Step 3 -- Sensitivity Gate

For each selected capsule (or all capsules if full scope), read `sensitivity:` and `pii:` from companion frontmatter.

**Sensitivity levels:**

| Level | Action |
|-------|--------|
| `public` | No gate. Proceed. |
| `private` | Soft note: "This capsule is marked private." No blocking. |
| `restricted` | Warn prominently. Recommend encryption. Require explicit "yes, share it" before proceeding. |

**PII check:**

If any capsule has `pii: true`, block by default:

```
╭─ 🐿️ sensitivity gate
│
│  ⚠ vendor-analysis contains personal data (pii: true).
│  Sharing PII requires explicit confirmation.
│
│  ▸ Continue?
│  1. Yes, I understand -- proceed
│  2. Cancel
╰─
```

The human must choose option 1 to proceed. This follows the confirm-before-external pattern from `rules/human.md`.

If any content is `restricted` or has PII, recommend encryption at Step 5 (but don't force it).

---

### Step 4 -- Scope Confirmation

Build the file list for the selected scope. Show what will be packaged:

```
╭─ 🐿️ package contents
│
│  Scope:    capsule
│  Capsules: shielding-review, safety-brief
│  Files:    12 files
│  Est size: ~2.4 MB
│
│  Includes: 2 companions, 4 drafts, 6 raw files
│  Plus: _core/key.md (parent context)
│
│  ▸ Package it?
│  1. Yes
│  2. Add a personal note first
│  3. Cancel
╰─
```

If the human picks "Add a personal note", ask for the note. It goes into the manifest's `note:` field and is shown in a bordered block on import.

**Recipient (for shared: metadata):** After confirming scope, ask who the package is for:

```
╭─ 🐿️ recipient
│
│  ▸ Who is this for? (name or skip)
╰─
```

If the human provides a name, store it for the `shared:` metadata `to:` field in Step 8. If they skip, infer from the personal note if possible, otherwise use `"walnut-package"`.

**Cross-capsule path warning:** Scan capsule companion `sources:` entries for paths containing `../`. If found:

```
╭─ 🐿️ heads up
│
│  shielding-review references files in other capsules
│  via relative paths (../vendor-analysis/raw/specs.pdf).
│  These paths will break for the recipient.
│
│  The references are preserved as historical metadata.
│  Proceeding.
╰─
```

This is informational only -- do not block.

---

### Step 5 -- Encryption Prompt

Encryption uses `openssl enc` which is pre-installed on macOS and Linux. No additional dependencies needed. The passphrase is collected through the session and passed via environment variable -- it never touches disk and is never visible in process listings.

```
╭─ 🐿️ encryption
│
│  Encrypt this package?
│  (Recipient will need the passphrase to open it.)
│
│  ▸ Encrypt?
│  1. Yes -- passphrase encrypt
│  2. No -- send unencrypted
╰─
```

If content was flagged `restricted` or `pii: true` in Step 3, surface that context:

```
╭─ 🐿️ encryption (recommended)
│
│  This package contains restricted/PII content.
│  Encryption is strongly recommended.
│
│  ▸ Encrypt?
│  1. Yes -- passphrase encrypt
│  2. No -- I accept the risk
╰─
```

If the human chooses to encrypt, collect the passphrase immediately:

```
╭─ 🐿️ passphrase
│
│  ▸ Enter a passphrase for this package:
╰─
```

Store the passphrase in memory for Step 6e. It is passed to `openssl` via `env:` -- never written to a file or passed as a CLI argument.

---

### Step 6 -- Package Creation

This is the core packaging step. The squirrel executes these bash commands via the Bash tool.

#### 6a. Prepare staging directory

```bash
STAGING=$(mktemp -d)
WALNUT_PATH="<path to the walnut being shared>"
WALNUT_NAME="<walnut directory name>"
```

#### 6b. Copy files to staging based on scope

**Full scope:**
```bash
# Copy _core/ to staging, excluding _squirrels/, _index.yaml, and OS artifacts
mkdir -p "$STAGING/_core"
rsync -a --exclude='_squirrels' --exclude='_index.yaml' --exclude='.DS_Store' --exclude='Thumbs.db' --exclude='desktop.ini' "$WALNUT_PATH/_core/" "$STAGING/_core/"
```

**Capsule scope:**
```bash
# Copy key.md for parent context
mkdir -p "$STAGING/_core"
cp "$WALNUT_PATH/_core/key.md" "$STAGING/_core/key.md"

# Copy each selected capsule
for CAPSULE in <capsule-names>; do
  mkdir -p "$STAGING/_core/_capsules/$CAPSULE"
  rsync -a --exclude='.DS_Store' "$WALNUT_PATH/_core/_capsules/$CAPSULE/" "$STAGING/_core/_capsules/$CAPSULE/"
done
```

**Snapshot scope:**
```bash
mkdir -p "$STAGING/_core"
cp "$WALNUT_PATH/_core/key.md" "$STAGING/_core/key.md"
cp "$WALNUT_PATH/_core/now.md" "$STAGING/_core/now.md"
cp "$WALNUT_PATH/_core/insights.md" "$STAGING/_core/insights.md"
```

#### 6c. Strip ephemeral data from capsule companions

For capsule and full scopes, strip `active_sessions:` from every capsule companion in staging. This is done on the staging copy -- the original is never modified.

Run this Python snippet against all companions in staging:

```bash
python3 -c "
import sys, re, pathlib, glob

for p in glob.glob(sys.argv[1] + '/_core/_capsules/*/companion.md'):
    text = pathlib.Path(p).read_text()
    # Match YAML frontmatter between --- delimiters
    m = re.match(r'(---\n)(.*?)(---\n)', text, re.DOTALL)
    if not m:
        continue
    front = m.group(2)
    # Remove active_sessions key and its value (scalar, list, or block)
    # Handles: active_sessions: []  /  active_sessions:\n  - ...\n  - ...
    cleaned = re.sub(
        r'^active_sessions:.*?(?=\n\S|\n---|\Z)',
        '',
        front,
        flags=re.MULTILINE | re.DOTALL
    )
    # Remove any resulting blank lines left behind
    cleaned = re.sub(r'\n{3,}', '\n\n', cleaned)
    pathlib.Path(p).write_text(m.group(1) + cleaned + m.group(3) + text[m.end():])
" "$STAGING"
```

This handles both empty (`active_sessions: []`) and populated block forms without requiring PyYAML.

#### 6d. Generate manifest.yaml

Read the manifest template from `templates/walnut-package/manifest.yaml`. Fill every field:

- `format_version`: `"1.0.0"`
- `source.walnut`: the walnut directory name
- `source.session_id`: current session ID
- `source.engine`: current model name
- `source.plugin_version`: read from the ALIVE plugin (use `"1.0.0"` if not determinable)
- `scope`: `"full"`, `"capsule"`, or `"snapshot"`
- `created`: current ISO 8601 timestamp with timezone
- `encrypted`: `true` if encrypting, `false` otherwise
- `description`: auto-generated from `key.md` goal (full/snapshot) or capsule companion goal (capsule scope -- join multiple goals with "; ")
- `note`: the personal note if provided, otherwise omit the field
- `capsules`: list of capsule names (capsule scope only, otherwise omit)

**Compute checksums and sizes for every file in staging** (except manifest.yaml itself):

```bash
# macOS
if command -v shasum >/dev/null 2>&1; then
  find "$STAGING" -type f ! -name 'manifest.yaml' -exec shasum -a 256 {} \;
# Linux fallback
elif command -v sha256sum >/dev/null 2>&1; then
  find "$STAGING" -type f ! -name 'manifest.yaml' -exec sha256sum {} \;
fi
```

For file sizes:
```bash
find "$STAGING" -type f ! -name 'manifest.yaml' -exec stat -f '%z %N' {} \;  # macOS
# or: find "$STAGING" -type f ! -name 'manifest.yaml' -exec stat --format='%s %n' {} \;  # Linux
```

Build the `files:` array from these results. Paths must be relative to the staging root (strip the staging prefix). Sort entries lexicographically by path.

Write the completed `manifest.yaml` to `$STAGING/manifest.yaml`.

#### 6e. Create the archive

Build the output path. The **base** is the filename without the `.walnut` extension:

```
OUTPUT_BASE=~/Desktop/<walnut-name>-<scope>-<YYYY-MM-DD>
```

The final filename is always `$OUTPUT_BASE.walnut` -- encrypted or not. One file.

Ask the human for the output path:

```
╭─ 🐿️ output
│
│  Where should I save the package?
│  Default: ~/Desktop/nova-station-capsule-2026-03-26.walnut
│
│  ▸ Path? (press enter for default)
╰─
```

If a file with that name already exists, append a sequence number to the base: `$OUTPUT_BASE-2`, `$OUTPUT_BASE-3`, etc.

**Unencrypted:**

All content + manifest.yaml are already in `$STAGING`. Create the archive directly:

```bash
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_BASE.walnut" -C "$STAGING" .
```

**Encrypted:**

For encrypted packages, the `.walnut` file contains `manifest.yaml` (cleartext, for preview) alongside `payload.enc` (the encrypted content). This keeps it as a single file while letting the recipient peek at metadata before decrypting.

```bash
# 1. Create an inner tar.gz of the content (everything except manifest.yaml)
INNER=$(mktemp /tmp/walnut-inner-XXXXX.tar.gz)
COPYFILE_DISABLE=1 tar -czf "$INNER" -C "$STAGING" --exclude='manifest.yaml' .

# 2. Encrypt the inner tar with the passphrase collected in Step 5
WALNUT_PASSPHRASE="<passphrase-from-step-5>" \
  openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
  -in "$INNER" -out "$STAGING/payload.enc" \
  -pass env:WALNUT_PASSPHRASE

# 3. Remove the inner tar (no longer needed)
rm -f "$INNER"

# 4. Remove content files from staging -- only manifest.yaml and payload.enc remain
find "$STAGING" -mindepth 1 -not -name 'manifest.yaml' -not -name 'payload.enc' -delete 2>/dev/null
# Handle directories left behind
find "$STAGING" -mindepth 1 -type d -empty -delete 2>/dev/null

# 5. Create the outer archive (manifest.yaml + payload.enc)
COPYFILE_DISABLE=1 tar -czf "$OUTPUT_BASE.walnut" -C "$STAGING" .
```

**IMPORTANT:** The passphrase MUST be passed via `env:` (environment variable), never as a CLI argument (visible in `ps`) or written to a file. The `WALNUT_PASSPHRASE=... openssl ...` syntax sets it for that single command only.

#### 6f. Strip macOS extended attributes

macOS may add quarantine/provenance attributes to created files. Strip them:

```bash
xattr -c "$OUTPUT_BASE.walnut" 2>/dev/null || true
```

#### 6g. Clean up staging

The staging directory is in `/tmp` and will be cleaned by the OS, but clean it explicitly:

```bash
rm -rf "$STAGING" 2>/dev/null || true
```

Note: The archive enforcer hook may block `rm` if it pattern-matches too broadly. If blocked, ignore -- `/tmp` is cleaned by the OS automatically.

---

### Step 7 -- Output

Show the result:

```
╭─ 🐿️ packaged
│
│  File: ~/Desktop/nova-station-capsule-2026-03-26.walnut
│  Size: 2.4 MB
│  Scope: capsule (shielding-review, safety-brief)
│  Encrypted: no
│
│  Send it however you like -- email, AirDrop, Slack, USB.
│  Recipient imports with /alive:receive.
╰─
```

If encrypted:

```
╭─ 🐿️ packaged
│
│  File: ~/Desktop/nova-station-capsule-2026-03-26.walnut
│  Size: 2.4 MB (encrypted)
│  Scope: capsule (shielding-review, safety-brief)
│
│  Share the passphrase separately from the file.
│  Recipient imports with /alive:receive.
╰─
```

Always one file. The recipient opens it with `/alive:receive` regardless of encryption -- the receive skill detects `payload.enc` inside and prompts for the passphrase.

---

### Step 8 -- Metadata Update

For capsule scope: update each exported capsule's companion `shared:` field in the **original walnut** (not staging -- staging is deleted).

Read each capsule's `companion.md`, add an entry to the `shared:` array:

```yaml
shared:
  - to: "<recipient if known, otherwise 'walnut-package'>"
    method: "walnut-package"
    date: <YYYY-MM-DD>
    version: "<current version file, e.g. shielding-review-draft-02.md>"
```

If the human mentioned who the package is for during the flow (in the personal note, or in conversation), use that name for `to:`. Otherwise default to `"walnut-package"`.

**Note:** Step 8 runs before the relay push (Step 9). If Step 9 later succeeds, update the `method:` field from `"walnut-package"` to `"walnut-relay"` in the same `shared:` entry. This retroactive update is acceptable because the share event hasn't been logged yet.

For full scope: no companion metadata update (the entire walnut is being handed off).

For snapshot scope: no metadata update (read-only briefing, nothing was "shared" in the capsule sense).

Stash the share event for the log:

```
╭─ 🐿️ +1 stash (N)
│  Shared [scope] package: [capsule names or "full walnut"] via walnut-package
│  → drop?
╰─
```

---

### Step 9 -- Relay Push (conditional)

This step runs only when a relay is configured. If `.alive/relay.yaml` does not exist or has no peers, skip to the end -- the local `.walnut` file is the final output.

#### 9a. Check relay configuration

Discover the world root (walk up from cwd looking for `.alive/`), then check for relay config:

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

if [ -n "$WORLD_ROOT" ] && [ -f "$WORLD_ROOT/.alive/relay.yaml" ]; then
  echo "RELAY_CONFIGURED"
else
  echo "NO_RELAY"
fi
```

If `NO_RELAY`, skip the entire step. The local `.walnut` file stands alone.

#### 9b. Parse peers and check relay reachability

Read the peer list, filter to `status: "accepted"`, then probe each peer's relay repo. The output is an indexed `PEERS` bash array that Step 9c uses for selection mapping.

**Reachability check:** For each accepted peer, verify their relay repo is accessible via the GitHub API. Use explicit timeout wrapping (same pattern as `alive-relay-check.sh`):

```bash
PEERS_DATA=$(python3 - "$WORLD_ROOT/.alive/relay.yaml" << 'PYEOF'
import sys, re, subprocess, time, json

config_path = sys.argv[1]
with open(config_path) as f:
    text = f.read()

# Extract peer blocks (each starts with "  - github:")
blocks = re.split(r'(?=\s+-\s+github:)', text)
peers = []
for block in blocks:
    gh = re.search(r'github:\s*"?([^"\n]+)"?', block)
    name = re.search(r'name:\s*"?([^"\n]+)"?', block)
    relay = re.search(r'relay:\s*"?([^"\n]+)"?', block)
    status = re.search(r'status:\s*"?([^"\n]+)"?', block)
    if gh and name and relay and status:
        if status.group(1).strip() == "accepted":
            peers.append({
                "github": gh.group(1).strip(),
                "name": name.group(1).strip(),
                "relay": relay.group(1).strip()
            })

if not peers:
    print("PEER_COUNT=0")
    sys.exit(0)

# Probe each peer's relay with 5s per-peer timeout, 10s hard total cap.
# Per-peer timeout is min(5, remaining_budget) so we never exceed 10s.
TOTAL_BUDGET = 10
PER_PEER_MAX = 5
total_start = time.time()
for p in peers:
    remaining = TOTAL_BUDGET - (time.time() - total_start)
    if remaining <= 0:
        p["status"] = "TIMEOUT"
        continue
    peer_timeout = min(PER_PEER_MAX, remaining)
    try:
        # Use -i to include HTTP headers; check both stdout and stderr
        # for the status code (gh may write headers to either stream)
        r = subprocess.run(
            ["gh", "api", f"repos/{p['relay']}", "-i", "--silent"],
            capture_output=True, timeout=peer_timeout
        )
        combined = r.stdout.decode() + r.stderr.decode()
        status_match = re.search(r'HTTP/[\d.]+ (\d{3})', combined)
        if status_match:
            code = int(status_match.group(1))
            if 200 <= code < 300:
                p["status"] = "OK"
            elif code in (403, 404):
                p["status"] = "NOT_FOUND_OR_NO_ACCESS"
            else:
                p["status"] = "OTHER_ERROR"
        elif r.returncode == 0:
            p["status"] = "OK"
        else:
            p["status"] = "OTHER_ERROR"
    except subprocess.TimeoutExpired:
        p["status"] = "TIMEOUT"
    except Exception:
        p["status"] = "OTHER_ERROR"

# Emit one line per peer: index|github|relay|name|status
# Pipe-delimited to safely handle spaces in names
for i, p in enumerate(peers):
    print(f"{i+1}|{p['github']}|{p['relay']}|{p['name']}|{p['status']}")
print(f"PEER_COUNT={len(peers)}")
PYEOF
)

echo "$PEERS_DATA"
```

The output uses pipe-delimited lines (one per peer) to safely handle names with spaces. The last line is `PEER_COUNT=N`. Example:

```
1|benflint|benflint/walnut-relay|Ben Flint|OK
2|carolsmith|carolsmith/walnut-relay|Carol Smith|NOT_FOUND_OR_NO_ACCESS
PEER_COUNT=2
```

If `PEER_COUNT=0`, skip relay push. Surface a brief note only if the human explicitly mentioned relay during the session, otherwise skip silently.

**Status buckets:**

| Status | Meaning | Selectable? |
|--------|---------|-------------|
| `OK` | Relay exists and accessible | Yes |
| `NOT_FOUND_OR_NO_ACCESS` | 403/404 -- repo missing or private without access | No |
| `TIMEOUT` | Per-peer network timeout or total 10s budget exceeded | Yes (with note) |
| `OTHER_ERROR` | Unexpected API error | Yes (with note) |

#### 9c. Present relay push option from Step 9b output

Build the menu from the pipe-delimited peer lines emitted by Step 9b:

```
╭─ 🐿️ relay
│
│  Push to relay for automatic delivery?
│
│  ▸ Recipient
│  1. Ben Flint (benflint)
│  2. Carol Smith (carolsmith) -- (not found or no access)
│  3. Dave Lee (davelee) -- (couldn't verify)
│  4. Skip -- share file manually
╰─
```

Peers with `NOT_FOUND_OR_NO_ACCESS` status are shown with "(not found or no access)" and are **not selectable** -- if the human picks one, explain the relay isn't reachable and suggest sharing manually. Peers with `TIMEOUT` or `OTHER_ERROR` are shown with "(couldn't verify)" but remain selectable.

The last option is always "Skip". If only one peer exists, still show the menu.

**When the human selects a peer (e.g., "1"), extract the three identity variables by parsing the matching pipe-delimited line:**

```bash
# Find the line starting with the selected index from PEERS_DATA
SELECTED_LINE=$(echo "$PEERS_DATA" | grep "^${selection}|")
# Parse pipe-delimited fields: index|github|relay|name|status
PEER_USERNAME=$(echo "$SELECTED_LINE" | cut -d'|' -f2)
PEER_RELAY=$(echo "$SELECTED_LINE" | cut -d'|' -f3)
PEER_NAME=$(echo "$SELECTED_LINE" | cut -d'|' -f4)
```

Uses `cut -d'|'` which is portable across macOS and Linux (no PCRE/`grep -P` needed).

These three variables are the **single source of truth** for Steps 9d-9g. They must be declared at the top of the consolidated script block and never re-derived.

If the human skips, the step ends. The local `.walnut` file is the output.

#### 9d-9g. Key fetch, RSA encryption, manifest update, and push (single Bash invocation)

**CRITICAL: Steps 9d through 9g MUST run as a single Bash tool invocation.** Splitting them across separate Bash calls loses shell variables (`$RELAY_STAGING`, `$PEER_PUBKEY`, `$WALNUT_B64`, etc.). The entire relay push pipeline -- key fetch, RSA encryption, manifest update, archive creation, and Contents API push -- runs in one script.

The three peer identity variables from Step 9c (`PEER_USERNAME`, `PEER_RELAY`, `PEER_NAME`) are declared at the top. They are the single source of truth for the entire script.

Expected failures (key fetch, push attempts) use `if ! ...; then` blocks -- **not** `set -e` -- so user-facing error messages can be shown before exiting. All temp files use `mktemp`; never `$$`. The `trap` ensures cleanup on all exit paths (success, expected failure, unexpected failure).

```bash
#!/bin/bash

# ── Peer identity from Step 9c selection (single source of truth) ──
PEER_USERNAME="<selected-peer-github>"
PEER_RELAY="<selected-peer-relay>"
PEER_NAME="<selected-peer-name>"
WORLD_ROOT="<world-root-from-9a>"
WALNUT_FILE="<path-to-local-walnut-file>"

# ── Temp files via mktemp ──
RELAY_STAGING=$(mktemp -d)
AES_KEY=$(mktemp)
INNER_TAR=$(mktemp)
RELAY_WALNUT=$(mktemp /tmp/walnut-relay-pkg-XXXXX.walnut)

# ── Cleanup on ALL exit paths ──
trap 'rm -rf "$RELAY_STAGING" 2>/dev/null; rm -f "$AES_KEY" "$INNER_TAR" "$RELAY_WALNUT" 2>/dev/null' EXIT

# ── Step 9d: Fetch peer's public key ──
PEER_PUBKEY="$WORLD_ROOT/.alive/relay-keys/peers/$PEER_USERNAME.pem"
if [ ! -f "$PEER_PUBKEY" ] || [ ! -s "$PEER_PUBKEY" ]; then
  mkdir -p "$WORLD_ROOT/.alive/relay-keys/peers"
  if ! gh api "repos/$PEER_RELAY/contents/keys/$PEER_USERNAME.pem" \
       --jq '.content' 2>/dev/null | (base64 -d 2>/dev/null || base64 -D) > "$PEER_PUBKEY"; then
    echo "KEY_FAILED"
    rm -f "$PEER_PUBKEY"
    # Exit -- trap cleans up temp files
    exit 1
  fi
  if [ ! -s "$PEER_PUBKEY" ]; then
    echo "KEY_FAILED"
    rm -f "$PEER_PUBKEY"
    exit 1
  fi
  echo "KEY_FETCHED"
else
  echo "KEY_CACHED"
fi

# ── Step 9e: RSA-encrypt the package for relay ──
# Extract the local .walnut to get its contents
if ! tar -xzf "$WALNUT_FILE" -C "$RELAY_STAGING"; then
  echo "EXTRACT_FAILED"
  exit 1
fi

# Handle passphrase-encrypted local packages
if [ -f "$RELAY_STAGING/payload.enc" ] && [ ! -f "$RELAY_STAGING/payload.key" ]; then
  if ! WALNUT_PASSPHRASE="<passphrase-from-step-5>" \
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 \
    -in "$RELAY_STAGING/payload.enc" -out "$INNER_TAR" \
    -pass env:WALNUT_PASSPHRASE; then
    echo "DECRYPT_FAILED"
    exit 1
  fi
  rm "$RELAY_STAGING/payload.enc"
  tar -xzf "$INNER_TAR" -C "$RELAY_STAGING" || { echo "EXTRACT_FAILED"; exit 1; }
  rm -f "$INNER_TAR"
fi

# Create inner tar.gz of content (everything except manifest.yaml)
if ! COPYFILE_DISABLE=1 tar -czf "$INNER_TAR" -C "$RELAY_STAGING" --exclude='manifest.yaml' .; then
  echo "ARCHIVE_FAILED"
  exit 1
fi

# Generate random AES-256 key and encrypt payload
if ! openssl rand 32 > "$AES_KEY"; then
  echo "KEYGEN_FAILED"
  exit 1
fi
if ! openssl enc -aes-256-cbc -salt -pbkdf2 -iter 600000 \
  -in "$INNER_TAR" -out "$RELAY_STAGING/payload.enc" -pass "file:$AES_KEY"; then
  echo "ENCRYPT_FAILED"
  exit 1
fi

# Wrap AES key with peer's RSA public key (OAEP-SHA256)
if ! openssl pkeyutl -encrypt -pubin -inkey "$PEER_PUBKEY" \
  -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
  -in "$AES_KEY" -out "$RELAY_STAGING/payload.key"; then
  echo "RSA_WRAP_FAILED"
  exit 1
fi

# Securely delete the plaintext AES key and inner tar
rm -P "$AES_KEY" 2>/dev/null || rm -f "$AES_KEY"
rm -f "$INNER_TAR"

# Remove content files -- only manifest.yaml, payload.enc, payload.key remain
find "$RELAY_STAGING" -mindepth 1 \
  -not -name 'manifest.yaml' \
  -not -name 'payload.enc' \
  -not -name 'payload.key' \
  -delete 2>/dev/null
find "$RELAY_STAGING" -mindepth 1 -type d -empty -delete 2>/dev/null

# ── Step 9f: Update manifest for relay ──
python3 - "$RELAY_STAGING/manifest.yaml" "$WORLD_ROOT/.alive/relay.yaml" << 'PYEOF'
import sys, re

manifest_path = sys.argv[1]
relay_config_path = sys.argv[2]

with open(relay_config_path) as f:
    relay_text = f.read()

repo_match = re.search(r'repo:\s*"?([^"\n]+)"?', relay_text)
username_match = re.search(r'github_username:\s*"?([^"\n]+)"?', relay_text)

if not repo_match or not username_match:
    print("ERROR: missing relay config fields")
    sys.exit(1)

relay_repo = repo_match.group(1).strip()
relay_sender = username_match.group(1).strip()

with open(manifest_path) as f:
    manifest = f.read()

manifest = re.sub(r'^encrypted:\s*\w+', 'encrypted: true', manifest, flags=re.MULTILINE)

if 'relay:' not in manifest:
    relay_block = (
        f'\nrelay:\n'
        f'  repo: "{relay_repo}"\n'
        f'  sender: "{relay_sender}"\n'
    )
    manifest = re.sub(r'(\nfiles:)', relay_block + r'\1', manifest)

with open(manifest_path, 'w') as f:
    f.write(manifest)

print(f"MANIFEST_UPDATED relay_repo={relay_repo} sender={relay_sender}")
PYEOF

# ── Step 9g: Create relay .walnut and push via Contents API ──
COPYFILE_DISABLE=1 tar -czf "$RELAY_WALNUT" -C "$RELAY_STAGING" .

# File size guard (GitHub Contents API 100 MB limit)
WALNUT_SIZE=$(stat -f '%z' "$RELAY_WALNUT" 2>/dev/null || stat --format='%s' "$RELAY_WALNUT" 2>/dev/null)
if [ -z "$WALNUT_SIZE" ]; then
  echo "SIZE_CHECK_FAILED"
  exit 1
fi
if [ "$WALNUT_SIZE" -gt 104857600 ]; then
  echo "TOO_LARGE"
  exit 1
fi

UUID=$(python3 -c "import uuid; print(uuid.uuid4())")
WALNUT_B64=$(base64 < "$RELAY_WALNUT" | tr -d '\n')

# Push to RECIPIENT's inbox on RECIPIENT's relay (PEER_USERNAME, not sender)
PUSH_SUCCESS=false
for ATTEMPT in 1 2 3; do
  if RESPONSE=$(gh api "repos/$PEER_RELAY/contents/inbox/$PEER_USERNAME/$UUID.walnut" \
    -X PUT \
    -f message="relay: deliver" \
    -f content="$WALNUT_B64" 2>&1); then
    if echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print('OK' if 'content' in d else 'FAIL')" 2>/dev/null | grep -q "OK"; then
      PUSH_SUCCESS=true
      break
    fi
  fi
  echo "Attempt $ATTEMPT failed. Retrying..."
  sleep 1
done

echo "PUSH_SUCCESS=$PUSH_SUCCESS"
# trap handles cleanup on exit
```

**Key points about this consolidated script:**

- `PEER_USERNAME` is used in the push path (`inbox/$PEER_USERNAME/`) -- this is the **recipient's** inbox on the **recipient's** relay. The sender's username is only used in the manifest `relay.sender` field.
- `trap` ensures temp file cleanup on all exit paths (success, key failure, push failure, unexpected errors).
- Expected failures (key fetch, push) use `if ! ...; then` -- not `set -e` -- so error messages reach the user.
- Critical pipeline operations (`tar`, `openssl enc`, `openssl pkeyutl`, `openssl rand`) also check return codes and exit on failure with descriptive status codes.
- All temp files use `mktemp`, never `$$`.
- The passphrase (if the local package was encrypted) is passed via `env:`, never as a CLI argument.

If `KEY_FAILED`:

```
╭─ 🐿️ relay push failed
│
│  Couldn't fetch <peer-name>'s public key from their relay.
│  They may not have set up their relay yet.
│
│  The package is still at: <local-walnut-path>
│  Share it manually instead.
╰─
```

If `TOO_LARGE`:

```
╭─ 🐿️ package too large for relay
│
│  This package is over 100 MB -- too large for the GitHub Contents API.
│  Share the file manually instead: <local-walnut-path>
╰─
```

If `PUSH_SUCCESS=false`:

```
╭─ 🐿️ relay push failed
│
│  Couldn't push to <peer-name>'s relay after 3 attempts.
│  The package is still at: <local-walnut-path>
│  Send it manually, or try /alive:relay status to diagnose.
╰─
```

#### 9h. Confirmation

```
╭─ 🐿️ relayed
│
│  Package pushed to relay for <peer-name>.
│  They'll see it on their next session start.
│
│  Local copy: <local-walnut-path>
╰─
```

The local `.walnut` file is always preserved. Relay is additive -- it provides automatic delivery alongside the manual file.

Stash the relay event:

```
╭─ 🐿️ +1 stash (N)
│  Relayed [scope] package to <peer-name> (<peer-username>) via relay
│  → drop?
╰─
```

---

## Scope File Rules (Quick Reference)

| Scope | Includes | Excludes |
|-------|----------|----------|
| **full** | All `_core/` contents | `_squirrels/`, `_index.yaml`, OS artifacts |
| **capsule** | `key.md` + selected capsule dirs | Everything else |
| **snapshot** | `key.md`, `now.md`, `insights.md` | Everything else |

For all scopes:
- `active_sessions:` stripped from capsule companions in staging
- OS artifacts (`.DS_Store`, `Thumbs.db`, `desktop.ini`) excluded
- `COPYFILE_DISABLE=1` mandatory on tar to prevent AppleDouble files

---

## Edge Cases

**Empty capsule (companion only, no raw files):** Package it anyway. The companion context has value.

**Large package warning:** If total staging size exceeds 25 MB, warn:

```
╭─ 🐿️ heads up
│
│  This package is ~42 MB. That may be too large for email.
│  Consider AirDrop, a shared drive, or splitting into smaller packages.
│
│  ▸ Continue?
│  1. Yes
│  2. Cancel
╰─
```

**No capsules exist (capsule scope selected):** This shouldn't happen since the option is suppressed in Step 1, but if reached: "This walnut has no capsules. Try full or snapshot scope instead."

**Walnut argument (sharing from non-current walnut):** If the human provides a walnut name or path as an argument, locate it, read its `_core/key.md` and proceed. Don't switch the session's active walnut -- just read from the target.

**Multiple packages same day:** Check for existing files matching the name pattern. Append sequence number (`-2`, `-3`) to avoid overwriting.

**Relay push -- peer's relay doesn't exist:** If the peer hasn't run `/alive:relay setup`, their relay repo won't exist. The Contents API call will fail with a 404. Surface the failure and suggest sharing the file manually.

**Relay push -- peer key missing:** If the peer's public key isn't cached locally and can't be fetched from their relay, skip relay push and explain the issue. This usually means the peer hasn't committed their public key yet.

**Relay push -- offline:** If `gh api` fails with a connection error, skip relay push silently. The local `.walnut` file is always available.

**Relay push -- only pending peers:** If all peers have `status: "pending"` (invitations not yet accepted), skip the relay push step. Pending peers don't have push access to the relay repo yet.
