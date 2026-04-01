#!/usr/bin/env python3
"""Relay probe: check GitHub relay for new commits and pending packages.

Runs from the alive-relay-check SessionStart hook with a 10s timeout.
Reads relay.json, probes the relay repo via `gh api`, counts pending
.walnut files in the user's inbox, checks peer reachability, and writes
results to state.json atomically.

MUST exit 0 always -- network failures are expected and must not block
session start.

Usage:
    python3 relay-probe.py --config ~/.alive/relay/relay.json \
                           --state  ~/.alive/relay/state.json

Task: fn-5-dof.4
"""

import argparse
import datetime
import os
import subprocess
import sys

# Import atomic JSON utilities from alive-p2p.py (same directory).
# The filename uses a hyphen, so we need importlib to load it.
import importlib.util as _ilu

_script_dir = os.path.dirname(os.path.abspath(__file__))
_p2p_path = os.path.join(_script_dir, 'alive-p2p.py')
_spec = _ilu.spec_from_file_location('alive_p2p', _p2p_path)
_mod = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_mod)

atomic_json_read = _mod.atomic_json_read
atomic_json_write = _mod.atomic_json_write


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _now_iso():
    """Return current UTC time as ISO 8601 string."""
    return datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec='seconds')


def _run_gh(args, timeout=5):
    """Run a `gh` CLI command. Returns (stdout, success)."""
    try:
        proc = subprocess.run(
            ['gh'] + args,
            capture_output=True, text=True, timeout=timeout)
        return proc.stdout.strip(), proc.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return '', False


def _run_git(args, timeout=5):
    """Run a `git` command. Returns (stdout, success)."""
    try:
        proc = subprocess.run(
            ['git'] + args,
            capture_output=True, text=True, timeout=timeout)
        return proc.stdout.strip(), proc.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return '', False


# ---------------------------------------------------------------------------
# Probe: check relay repo for new commits
# ---------------------------------------------------------------------------

def probe_relay_commit(repo):
    """Check the latest commit SHA on the relay repo's main branch.

    Uses `gh api` which is the fastest way to check -- single HTTPS
    request, no git operations.

    Returns the commit SHA string, or None on failure.
    """
    stdout, ok = _run_gh([
        'api', f'repos/{repo}/git/refs/heads/main',
        '--jq', '.object.sha'])
    if ok and stdout:
        return stdout
    return None


# ---------------------------------------------------------------------------
# Probe: count pending .walnut files in inbox
# ---------------------------------------------------------------------------

def count_pending_packages(clone_dir, username):
    """Count .walnut files in inbox/{username}/ of the local clone.

    The clone is a sparse checkout that only includes inbox/{username}/
    and keys/. Returns 0 if the directory doesn't exist.
    """
    inbox_dir = os.path.join(clone_dir, 'inbox', username)
    if not os.path.isdir(inbox_dir):
        return 0

    count = 0
    try:
        for entry in os.listdir(inbox_dir):
            if entry.endswith('.walnut'):
                count += 1
    except OSError:
        pass
    return count


# ---------------------------------------------------------------------------
# Probe: fetch latest from relay
# ---------------------------------------------------------------------------

def fetch_relay(clone_dir):
    """Fetch latest from origin and reset to origin/main.

    Uses --depth=1 to keep it fast. Returns True on success.
    """
    _, fetch_ok = _run_git(
        ['-C', clone_dir, 'fetch', '--depth=1', 'origin', 'main'],
        timeout=8)
    if not fetch_ok:
        return False

    _, reset_ok = _run_git(
        ['-C', clone_dir, 'reset', '--hard', 'origin/main'],
        timeout=5)
    return reset_ok


# ---------------------------------------------------------------------------
# Probe: peer reachability
# ---------------------------------------------------------------------------

def check_peer_reachability(peers):
    """Check if each peer's relay repo is reachable via `gh api`.

    Returns a dict of {github_username: {reachable, checked, relay_repo}}.
    Skips peers without a relay field.
    """
    reachability = {}
    for peer in peers:
        github = peer.get('github', '')
        relay = peer.get('relay', '')
        if not github or not relay:
            continue

        # Quick check: does the repo exist and is it accessible?
        stdout, ok = _run_gh([
            'api', f'repos/{relay}',
            '--jq', '.full_name'],
            timeout=3)

        reachability[github] = {
            'reachable': ok and bool(stdout),
            'checked': _now_iso(),
            'relay_repo': relay,
        }

    return reachability


# ---------------------------------------------------------------------------
# Main probe
# ---------------------------------------------------------------------------

def run_probe(config_path, state_path):
    """Run the full relay probe and write results to state.json.

    Steps:
    1. Read relay.json config
    2. Check for new commits on relay repo (gh api)
    3. If changed: fetch latest into local clone
    4. Count pending .walnut files in inbox
    5. Check peer reachability
    6. Write state.json atomically
    """
    config = atomic_json_read(config_path)
    if not config:
        # No relay configured -- nothing to probe
        return

    repo = config.get('repo', '')
    username = config.get('github_username', '')
    peers = config.get('peers', [])

    if not repo or not username:
        return

    # Read existing state for comparison
    state = atomic_json_read(state_path)
    old_commit = state.get('last_commit', '')

    # Step 1: Check latest commit on relay repo
    new_commit = probe_relay_commit(repo)

    # Determine the clone directory
    relay_dir = os.path.dirname(os.path.abspath(config_path))
    clone_dir = os.path.join(relay_dir, 'clone')

    # Step 2: If commit changed (or first run), fetch
    fetched = False
    if new_commit and new_commit != old_commit and os.path.isdir(clone_dir):
        fetched = fetch_relay(clone_dir)

    # Step 3: Count pending packages (from local clone)
    pending = count_pending_packages(clone_dir, username)

    # Step 4: Check peer reachability
    reachability = check_peer_reachability(peers)

    # Step 5: Build and write state
    new_state = {
        'last_sync': _now_iso(),
        'last_commit': new_commit if new_commit else old_commit,
        'pending_packages': pending,
        'peer_reachability': reachability,
    }

    atomic_json_write(state_path, new_state)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description='Probe GitHub relay for new packages and peer reachability')
    parser.add_argument(
        '--config', required=True,
        help='Path to relay.json')
    parser.add_argument(
        '--state', required=True,
        help='Path to state.json (written atomically)')

    args = parser.parse_args()

    try:
        run_probe(args.config, args.state)
    except Exception:
        # Must exit 0 always -- this runs in a SessionStart hook
        # with a 10s timeout. Network failures are expected.
        pass

    sys.exit(0)


if __name__ == '__main__':
    main()
