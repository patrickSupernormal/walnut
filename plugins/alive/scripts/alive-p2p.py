#!/usr/bin/env python3
"""Cross-platform P2P utilities for the Alive sharing layer.

Standalone stdlib-only module providing hashing, tar operations, atomic JSON
state files, OpenSSL detection, base64, and YAML frontmatter parsing.

Designed for macOS (BSD tar, LibreSSL) and Linux (GNU tar, OpenSSL).
No pip dependencies -- python3 stdlib + openssl CLI only.

Usage as library:
    from alive_p2p import sha256_file, safe_tar_create, detect_openssl, ...

Usage as CLI (smoke tests):
    python3 alive-p2p.py hash <file>
    python3 alive-p2p.py openssl
    python3 alive-p2p.py tar-create <source_dir> <output.tar.gz>
    python3 alive-p2p.py tar-extract <archive.tar.gz> <output_dir>
    python3 alive-p2p.py tar-list <archive.tar.gz>
    python3 alive-p2p.py b64 <file>
    python3 alive-p2p.py yaml <file>

Task: fn-5-dof.2
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile


# ---------------------------------------------------------------------------
# Hashing
# ---------------------------------------------------------------------------

def sha256_file(path):
    """Return hex SHA-256 digest of a file. Cross-platform, no subprocess."""
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        while True:
            chunk = f.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


# ---------------------------------------------------------------------------
# Tar operations
# ---------------------------------------------------------------------------

# Files and patterns to exclude from archives
_TAR_EXCLUDES = {'.DS_Store', 'Thumbs.db', 'Icon\r', '__MACOSX'}


def _is_excluded(name):
    """Check whether a tar entry name should be excluded."""
    base = os.path.basename(name)
    if base in _TAR_EXCLUDES:
        return True
    # macOS resource fork files
    if base.startswith('._'):
        return True
    return False


def _resolve_path(base, name):
    """Resolve *name* relative to *base* and check it stays inside *base*.

    Returns the resolved absolute path, or None if the entry escapes.
    """
    # Reject absolute paths outright
    if os.path.isabs(name):
        return None
    target = os.path.normpath(os.path.join(base, name))
    # Must start with base (use trailing sep to avoid prefix tricks)
    if not (target == base or target.startswith(base + os.sep)):
        return None
    return target


def safe_tar_create(source_dir, output_path, strip_prefix=None):
    """Create a tar.gz archive from *source_dir*.

    - Sets COPYFILE_DISABLE=1 to suppress macOS resource forks.
    - Excludes .DS_Store, Thumbs.db, ._* files.
    - Rejects symlinks that resolve outside *source_dir*.
    - Optional *strip_prefix* removes a leading path component from entries.
    """
    source_dir = os.path.abspath(source_dir)
    if not os.path.isdir(source_dir):
        raise FileNotFoundError(f"Source directory not found: {source_dir}")

    # Suppress macOS resource forks (affects C-level tar inside python too)
    os.environ['COPYFILE_DISABLE'] = '1'

    output_path = os.path.abspath(output_path)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    with tarfile.open(output_path, 'w:gz') as tar:
        for root, dirs, files in os.walk(source_dir):
            # Skip excluded directories in-place
            dirs[:] = [d for d in dirs
                       if d not in _TAR_EXCLUDES and not d.startswith('._')]

            for name in sorted(files):
                if _is_excluded(name):
                    continue

                full_path = os.path.join(root, name)

                # Reject symlinks that escape source_dir
                if os.path.islink(full_path):
                    real = os.path.realpath(full_path)
                    if not (real == source_dir
                            or real.startswith(source_dir + os.sep)):
                        raise ValueError(
                            f"Symlink escapes source: {full_path} -> {real}")

                arcname = os.path.relpath(full_path, source_dir)
                if strip_prefix:
                    if arcname.startswith(strip_prefix):
                        arcname = arcname[len(strip_prefix):]
                        arcname = arcname.lstrip(os.sep)

                tar.add(full_path, arcname=arcname)

            # Also add directories that are symlinks (check safety)
            for d in dirs:
                dir_path = os.path.join(root, d)
                if os.path.islink(dir_path):
                    real = os.path.realpath(dir_path)
                    if not (real == source_dir
                            or real.startswith(source_dir + os.sep)):
                        raise ValueError(
                            f"Symlink escapes source: {dir_path} -> {real}")


def safe_tar_extract(archive_path, output_dir):
    """Extract a tar.gz archive with path-traversal and symlink protection.

    - Rejects entries with ``../`` or absolute paths (Zip Slip).
    - Rejects symlinks pointing outside *output_dir*.
    - Extracts to a staging directory first, then moves into *output_dir*.
    """
    archive_path = os.path.abspath(archive_path)
    output_dir = os.path.abspath(output_dir)

    if not os.path.isfile(archive_path):
        raise FileNotFoundError(f"Archive not found: {archive_path}")

    os.makedirs(output_dir, exist_ok=True)

    # Use a staging directory in the same parent (same filesystem for rename)
    parent = os.path.dirname(output_dir)
    staging = tempfile.mkdtemp(dir=parent, prefix='.p2p-extract-')

    try:
        with tarfile.open(archive_path, 'r:*') as tar:
            # First pass: validate every entry
            for member in tar.getmembers():
                # Reject absolute paths
                if os.path.isabs(member.name):
                    raise ValueError(
                        f"Absolute path in archive: {member.name}")

                # Reject path traversal
                resolved = _resolve_path(staging, member.name)
                if resolved is None:
                    raise ValueError(
                        f"Path traversal in archive: {member.name}")

                # Reject symlinks that escape output
                if member.issym() or member.islnk():
                    link_target = member.linkname
                    # For symlinks, resolve relative to the member's parent
                    member_parent = os.path.join(
                        staging, os.path.dirname(member.name))
                    if os.path.isabs(link_target):
                        link_resolved = link_target
                    else:
                        link_resolved = os.path.normpath(
                            os.path.join(member_parent, link_target))
                    if not (link_resolved == staging
                            or link_resolved.startswith(staging + os.sep)):
                        raise ValueError(
                            f"Symlink escapes output: {member.name} "
                            f"-> {member.linkname}")

            # Second pass: extract (rewind)
            tar.extractall(path=staging)

        # Move contents from staging into output_dir
        for item in os.listdir(staging):
            src = os.path.join(staging, item)
            dst = os.path.join(output_dir, item)
            if os.path.exists(dst):
                # Remove existing to allow overwrite
                if os.path.isdir(dst):
                    import shutil
                    shutil.rmtree(dst)
                else:
                    os.remove(dst)
            os.rename(src, dst)

    finally:
        # Clean up staging directory
        if os.path.isdir(staging):
            import shutil
            shutil.rmtree(staging, ignore_errors=True)


def tar_list_entries(archive_path):
    """Return a list of entry names in a tar archive."""
    archive_path = os.path.abspath(archive_path)
    if not os.path.isfile(archive_path):
        raise FileNotFoundError(f"Archive not found: {archive_path}")

    with tarfile.open(archive_path, 'r:*') as tar:
        return [m.name for m in tar.getmembers()]


# ---------------------------------------------------------------------------
# JSON state files (atomic read/write)
# ---------------------------------------------------------------------------

def atomic_json_write(path, data):
    """Write *data* as JSON to *path* atomically (temp + fsync + rename).

    The temp file is created in the same directory as *path* so that
    os.replace() is a same-filesystem atomic rename on POSIX.
    """
    path = os.path.abspath(path)
    target_dir = os.path.dirname(path)
    os.makedirs(target_dir, exist_ok=True)

    fd, tmp_path = tempfile.mkstemp(dir=target_dir, suffix='.tmp')
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2, default=str)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp_path, path)
    except BaseException:
        # Clean up temp file on any failure
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def atomic_json_read(path):
    """Read JSON from *path*. Returns empty dict on missing or corrupt file."""
    path = os.path.abspath(path)
    try:
        with open(path, 'r', encoding='utf-8') as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, IOError):
        return {}


# ---------------------------------------------------------------------------
# OpenSSL detection
# ---------------------------------------------------------------------------

def detect_openssl():
    """Detect the system openssl binary and its capabilities.

    Returns a dict::

        {
            "binary": "openssl",        # path or name
            "version": "LibreSSL 3.3.6",
            "is_libressl": True,
            "supports_pbkdf2": True,
            "supports_pkeyutl": True,
        }

    Returns None values on detection failure (openssl not found).
    """
    result = {
        'binary': None,
        'version': None,
        'is_libressl': None,
        'supports_pbkdf2': None,
        'supports_pkeyutl': None,
    }

    # Find openssl binary
    for candidate in ['openssl', '/usr/bin/openssl', '/usr/local/bin/openssl']:
        try:
            proc = subprocess.run(
                [candidate, 'version'],
                capture_output=True, text=True, timeout=5)
            if proc.returncode == 0:
                result['binary'] = candidate
                result['version'] = proc.stdout.strip()
                break
        except (FileNotFoundError, subprocess.TimeoutExpired):
            continue

    if result['binary'] is None:
        return result

    version_str = result['version'] or ''
    result['is_libressl'] = 'LibreSSL' in version_str

    # Detect -pbkdf2 support
    # LibreSSL < 3.1 and OpenSSL < 1.1.1 lack -pbkdf2
    if result['is_libressl']:
        # Parse LibreSSL version: "LibreSSL X.Y.Z"
        m = re.search(r'LibreSSL\s+(\d+)\.(\d+)\.(\d+)', version_str)
        if m:
            major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
            result['supports_pbkdf2'] = (major, minor, patch) >= (3, 1, 0)
        else:
            result['supports_pbkdf2'] = False
    else:
        # OpenSSL: "OpenSSL X.Y.Zp" or "OpenSSL X.Y.Z"
        m = re.search(r'OpenSSL\s+(\d+)\.(\d+)\.(\d+)', version_str)
        if m:
            major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
            result['supports_pbkdf2'] = (major, minor, patch) >= (1, 1, 1)
        else:
            result['supports_pbkdf2'] = False

    # Detect pkeyutl support (needed for RSA-OAEP)
    try:
        proc = subprocess.run(
            [result['binary'], 'pkeyutl', '-help'],
            capture_output=True, text=True, timeout=5)
        # pkeyutl -help returns 0 on OpenSSL, 1 on some versions -- both mean it exists
        # If the command is truly missing, FileNotFoundError or returncode != 0 with
        # "unknown command" in stderr
        stderr = proc.stderr.lower()
        result['supports_pkeyutl'] = 'unknown command' not in stderr
    except (FileNotFoundError, subprocess.TimeoutExpired):
        result['supports_pkeyutl'] = False

    return result


# ---------------------------------------------------------------------------
# Base64
# ---------------------------------------------------------------------------

def b64_encode_file(path):
    """Return strict base64 encoding of a file (no line breaks).

    Uses ``openssl base64 -A`` for cross-platform portability
    (works on both LibreSSL and OpenSSL).
    """
    path = os.path.abspath(path)
    if not os.path.isfile(path):
        raise FileNotFoundError(f"File not found: {path}")

    ssl = detect_openssl()
    if ssl['binary'] is None:
        raise RuntimeError("openssl not found on this system")

    proc = subprocess.run(
        [ssl['binary'], 'base64', '-A', '-in', path],
        capture_output=True, text=True, timeout=30)

    if proc.returncode != 0:
        raise RuntimeError(
            f"openssl base64 failed (rc={proc.returncode}): {proc.stderr}")

    return proc.stdout.strip()


# ---------------------------------------------------------------------------
# YAML frontmatter parsing
# ---------------------------------------------------------------------------

def parse_yaml_frontmatter(content):
    """Parse YAML frontmatter from markdown content.

    Hand-rolled parser matching the pattern in generate-index.py.
    No PyYAML dependency. Handles:
    - Scalar values (strings, numbers, booleans)
    - Inline lists: [a, b, c]
    - Multi-line lists (items starting with ``  - ``)
    - Quoted strings (single and double)

    Returns an empty dict if no frontmatter is found.
    """
    match = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
    if not match:
        return {}

    fm = {}
    lines = match.group(1).split('\n')
    i = 0
    while i < len(lines):
        line = lines[i]
        kv = re.match(r'^(\w[\w-]*)\s*:\s*(.*)', line)
        if kv:
            key = kv.group(1)
            val = kv.group(2).strip()

            # Check for multi-line list (next lines start with "  - ")
            if val == '' or val == '[]':
                items = []
                j = i + 1
                while j < len(lines) and re.match(r'^\s+-\s', lines[j]):
                    item_match = re.match(r'^\s+-\s+(.*)', lines[j])
                    if item_match:
                        items.append(item_match.group(1).strip())
                    j += 1
                if items:
                    fm[key] = items
                    i = j
                    continue
                else:
                    fm[key] = val
            elif val.startswith('[') and val.endswith(']'):
                # Inline list: [a, b, c]
                inner = val[1:-1]
                fm[key] = [x.strip().strip('"').strip("'")
                           for x in inner.split(',') if x.strip()]
            else:
                # Remove surrounding quotes
                if ((val.startswith('"') and val.endswith('"'))
                        or (val.startswith("'") and val.endswith("'"))):
                    val = val[1:-1]

                # Coerce booleans and numbers
                lower = val.lower()
                if lower == 'true':
                    fm[key] = True
                elif lower == 'false':
                    fm[key] = False
                elif lower == 'null' or lower == '~':
                    fm[key] = None
                else:
                    # Try integer
                    try:
                        fm[key] = int(val)
                    except ValueError:
                        # Try float
                        try:
                            fm[key] = float(val)
                        except ValueError:
                            fm[key] = val
        i += 1
    return fm


# ---------------------------------------------------------------------------
# CLI (smoke tests)
# ---------------------------------------------------------------------------

def _cli():
    """Minimal CLI for smoke-testing functions."""
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == 'hash':
        if len(sys.argv) < 3:
            print("Usage: alive-p2p.py hash <file>", file=sys.stderr)
            sys.exit(1)
        print(sha256_file(sys.argv[2]))

    elif cmd == 'openssl':
        info = detect_openssl()
        for k, v in info.items():
            print(f"  {k}: {v}")

    elif cmd == 'tar-create':
        if len(sys.argv) < 4:
            print("Usage: alive-p2p.py tar-create <source_dir> <output.tar.gz>",
                  file=sys.stderr)
            sys.exit(1)
        safe_tar_create(sys.argv[2], sys.argv[3])
        entries = tar_list_entries(sys.argv[3])
        print(f"Created {sys.argv[3]} ({len(entries)} entries)")
        for e in entries:
            print(f"  {e}")

    elif cmd == 'tar-extract':
        if len(sys.argv) < 4:
            print("Usage: alive-p2p.py tar-extract <archive.tar.gz> <output_dir>",
                  file=sys.stderr)
            sys.exit(1)
        safe_tar_extract(sys.argv[2], sys.argv[3])
        print(f"Extracted to {sys.argv[3]}")

    elif cmd == 'tar-list':
        if len(sys.argv) < 3:
            print("Usage: alive-p2p.py tar-list <archive.tar.gz>",
                  file=sys.stderr)
            sys.exit(1)
        entries = tar_list_entries(sys.argv[2])
        for e in entries:
            print(e)

    elif cmd == 'b64':
        if len(sys.argv) < 3:
            print("Usage: alive-p2p.py b64 <file>", file=sys.stderr)
            sys.exit(1)
        print(b64_encode_file(sys.argv[2]))

    elif cmd == 'yaml':
        if len(sys.argv) < 3:
            print("Usage: alive-p2p.py yaml <file>", file=sys.stderr)
            sys.exit(1)
        with open(sys.argv[2], 'r', encoding='utf-8') as f:
            content = f.read()
        fm = parse_yaml_frontmatter(content)
        print(json.dumps(fm, indent=2, default=str))

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    _cli()
