#!/usr/bin/env python3
"""Inspect a candidate DMG and emit the website's release manifest v1.

No credentials, network client, source build settings, or raw tool diagnostics
are used. See docs/RELEASE_MANIFEST.md for the intentionally strict policy.
"""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time
from xml.parsers.expat import ExpatError

MANIFEST_FILENAME = "quotamew-release-manifest.json"
BUNDLE_ID = "dev.quotapulse.app"
MAX_SAFE_INTEGER = 2**53 - 1
MAX_BYTES = 65536
TAG = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", re.ASCII)
ROOT_FIELDS = ("schemaVersion", "tag", "version", "build", "channel", "minimumMacOS", "bundleID", "artifact", "signing")
SIGNING_FIELDS = ("type", "codesignVerified", "notarized", "stapled")


class ManifestError(Exception):
    """A sanitized failure; never include tool output or filesystem paths."""


def require(condition, reason):
    if not condition:
        raise ManifestError(reason)


def identity(tag, channel, filename):
    require(isinstance(tag, str), "Invalid tag")
    match = TAG.fullmatch(tag)
    require(match is not None, "Invalid QuotaMew SemVer tag")
    suffix = match[4]
    require(not suffix or all(not (p.isdigit() and len(p) > 1 and p[0] == "0") for p in suffix.split(".")), "Numeric prerelease has leading zeros")
    require(channel in ("stable", "preview"), "Unsupported channel")
    require(channel == ("preview" if suffix else "stable"), "Tag/channel mismatch")
    require(filename == f"QuotaMew-{tag}.dmg", "DMG filename/tag mismatch")
    return tag[1:], ".".join(match.group(i) for i in (1, 2, 3))


def validate_manifest(data):
    """Small explicit representation of the website v1 contract, not a copy."""
    require(type(data) is dict and set(data) == set(ROOT_FIELDS), "Manifest fields")
    require(type(data["schemaVersion"]) is int and data["schemaVersion"] == 1, "Unsupported schemaVersion")
    artifact, signing = data["artifact"], data["signing"]
    require(type(artifact) is dict and set(artifact) == {"filename"}, "Artifact fields")
    version, _ = identity(data["tag"], data["channel"], artifact["filename"])
    require(data["version"] == version, "Manifest tag/version mismatch")
    require(type(data["build"]) is int and 0 <= data["build"] <= MAX_SAFE_INTEGER, "Build must be a nonnegative safe integer")
    require(isinstance(data["minimumMacOS"], str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", data["minimumMacOS"]), "Invalid minimumMacOS")
    require(data["bundleID"] == BUNDLE_ID, "Unexpected bundle ID")
    require(type(signing) is dict and set(signing) == set(SIGNING_FIELDS), "Signing fields")
    require(signing["type"] in ("unsigned", "apple-development", "developer-id"), "Unsupported signing type")
    require(all(type(signing[k]) is bool for k in SIGNING_FIELDS[1:]), "Signing boolean fields")
    require(not signing["stapled"] or signing["notarized"], "Stapling requires notarization")
    require(signing["type"] != "unsigned" or (not signing["codesignVerified"] and not signing["notarized"]), "Unsigned signing status")
    return data


def candidate(tag, channel, filename, metadata, signing):
    version, core = identity(tag, channel, filename)
    require(metadata.get("CFBundleShortVersionString") == core, "Bundle product version/release core mismatch")
    build = metadata.get("CFBundleVersion")
    require(isinstance(build, str) and re.fullmatch(r"0|[1-9][0-9]*", build), "Bundle build must be an integer string")
    # Bound before conversion, including on Python versions with integer limits.
    require(len(build) <= 16 and int(build) <= MAX_SAFE_INTEGER, "Bundle build exceeds safe integer")
    return validate_manifest({
        "schemaVersion": 1, "tag": tag, "version": version, "build": int(build),
        "channel": channel, "minimumMacOS": metadata.get("LSMinimumSystemVersion"),
        "bundleID": metadata.get("CFBundleIdentifier"),
        "artifact": {"filename": filename}, "signing": signing,
    })


def serialize(data):
    validate_manifest(data)
    ordered = {key: data[key] for key in ROOT_FIELDS}
    ordered["artifact"] = {"filename": data["artifact"]["filename"]}
    ordered["signing"] = {key: data["signing"][key] for key in SIGNING_FIELDS}
    raw = (json.dumps(ordered, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    require(len(raw) <= MAX_BYTES, "Manifest exceeds website size bound")
    return raw


def run_tool(args, timeout=30):
    """Bound combined output, time and child lifetime; never surface raw data."""
    with tempfile.TemporaryFile() as output:
        try:
            process = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=output, stderr=output, start_new_session=True, env={**os.environ, "LC_ALL": "C", "LANG": "C"})
        except OSError:
            raise ManifestError("Required Apple tool unavailable") from None
        try:
            deadline = time.monotonic() + timeout
            while process.poll() is None:
                require(time.monotonic() < deadline, "Apple tool timeout")
                require(os.fstat(output.fileno()).st_size <= MAX_BYTES, "Apple tool output exceeds bound")
                time.sleep(0.05)
            require(os.fstat(output.fileno()).st_size <= MAX_BYTES, "Apple tool output exceeds bound")
            output.seek(0)
            return process.returncode, output.read(MAX_BYTES)
        finally:
            # Also reap on SIGINT/SIGTERM and kill inherited-pipe descendants.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def checked(args):
    status, output = run_tool(args)
    require(status == 0, "Apple artifact verification failed")
    return output


def signing_facts(signing_type, app_staple_status, dmg_staple_status):
    # stapler EX_DATAERR (65) means no usable ticket, NOT no notarization.
    require(app_staple_status in (0, 65) and dmg_staple_status in (0, 65), "Stapler evidence unavailable")
    if signing_type == "apple-development":
        require(app_staple_status == 65 and dmg_staple_status == 65, "Unexpected ticket for development signing")
        return {"type": signing_type, "codesignVerified": True, "notarized": False, "stapled": False}
    require(signing_type == "developer-id", "Unsupported signing evidence")
    # A DMG ticket alone cannot attest the independently installed app's ticket.
    require(app_staple_status == 0, "Developer ID app needs a valid staple; notarization unknown")
    return {"type": signing_type, "codesignVerified": True, "notarized": True, "stapled": True}


def inspect_signing(app, dmg):
    checked(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    checked(["/usr/bin/codesign", "--verify", "--strict", "-R=anchor apple generic", str(app)])
    output = checked(["/usr/bin/codesign", "--display", "--verbose=4", str(app)])
    authorities = [line[len(b"Authority="):] for line in output.splitlines() if line.startswith(b"Authority=")]
    require(len(authorities) >= 2, "Missing signing authority evidence")
    if authorities[0].startswith(b"Apple Development: "):
        signing_type = "apple-development"
    elif authorities[0].startswith(b"Developer ID Application: "):
        signing_type = "developer-id"
    else:
        raise ManifestError("Unrecognized Apple signing authority")
    app_status, _ = run_tool(["/usr/bin/xcrun", "stapler", "validate", str(app)])
    dmg_status, _ = run_tool(["/usr/bin/xcrun", "stapler", "validate", str(dmg)])
    return signing_facts(signing_type, app_status, dmg_status)


def bundle_metadata(app):
    path = app / "Contents" / "Info.plist"
    require(path.is_file() and not path.is_symlink() and not (app / "Contents").is_symlink() and path.stat().st_size <= MAX_BYTES, "Invalid or oversized bundle metadata")
    try:
        with path.open("rb") as source:
            metadata = plistlib.loads(source.read(MAX_BYTES + 1))
    except (OSError, ValueError, OverflowError, TypeError, plistlib.InvalidFileException, ExpatError):
        raise ManifestError("Unreadable bundle metadata") from None
    require(type(metadata) is dict, "Invalid bundle metadata")
    return {key: metadata.get(key) for key in ("CFBundleShortVersionString", "CFBundleVersion", "CFBundleIdentifier", "LSMinimumSystemVersion")}


def packaged_app(mount):
    app = mount / "QuotaMew.app"
    require(app.is_dir() and not app.is_symlink(), "Missing root QuotaMew.app")
    allowed = {"QuotaMew.app", "Applications", ".DS_Store", ".background", ".VolumeIcon.icns", ".fseventsd", ".Trashes", ".Spotlight-V100"}
    require(all(p.name in allowed for p in mount.iterdir()), "Unexpected DMG root layout")
    shortcut = mount / "Applications"
    require(shortcut.is_symlink() and os.readlink(shortcut) == "/Applications", "Invalid Applications shortcut")
    matches = []
    visited = 0
    for root, dirs, files in os.walk(mount, followlinks=False):
        visited += len(dirs) + len(files) + 1
        require(visited <= 10000, "DMG layout exceeds inspection bound")
        for name in dirs:
            if name == "QuotaMew.app":
                matches.append(Path(root) / name)
    require(matches == [app], "Ambiguous QuotaMew app layout")
    return app


@contextmanager
def mounted_dmg(dmg):
    directory = tempfile.mkdtemp(prefix="quotamew-manifest-")
    mount = Path(directory) / "volume"
    try:
        mount.mkdir()
        attempted = False
        try:
            # hdiutil otherwise writes recentcksum xattrs onto the input DMG.
            checked(["/usr/bin/hdiutil", "verify", "-nocache", str(dmg)])
            attempted = True
            checked(["/usr/bin/hdiutil", "attach", "-readonly", "-noverify", "-nobrowse", "-noautoopen", "-mountpoint", str(mount), str(dmg)])
            require(os.path.ismount(mount), "DMG did not mount at expected location")
            yield mount
        finally:
            if attempted and os.path.ismount(mount):
                status, _ = run_tool(["/usr/bin/hdiutil", "detach", str(mount)])
                if status != 0:
                    status, _ = run_tool(["/usr/bin/hdiutil", "detach", "-force", str(mount)])
                # Never recursively remove a mount that failed to detach.
                require(status == 0 and not os.path.ismount(mount), "DMG cleanup failed; manual detach required")
    finally:
        if not os.path.ismount(mount):
            shutil.rmtree(directory)


def inspect_dmg(tag, channel, dmg):
    dmg = Path(dmg).absolute()
    identity(tag, channel, dmg.name)
    require(dmg.is_file() and not dmg.is_symlink(), "Candidate DMG must be a regular file")
    before = dmg.stat()
    with mounted_dmg(dmg) as mount:
        app = packaged_app(mount)
        metadata = bundle_metadata(app)
        # Reject identity errors before running further security tools.
        candidate(tag, channel, dmg.name, metadata, {"type": "unsigned", "codesignVerified": False, "notarized": False, "stapled": False})
        data = candidate(tag, channel, dmg.name, metadata, inspect_signing(app, dmg))
    after = dmg.stat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "Candidate changed during inspection")
    return data


def atomic_write(output, raw):
    output = Path(output)
    require(output.name == MANIFEST_FILENAME, "Output must use website manifest filename")
    require(not output.is_symlink(), "Output cannot be a symlink")
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=output.parent, prefix=".quotamew-manifest-", delete=False) as target:
            temporary = Path(target.name)
            target.write(raw)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def interrupted(_signum, _frame):
    raise ManifestError("Artifact inspection interrupted")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", choices=("stable", "preview"), required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--output", type=Path)
    mode.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.output:
            require(args.output.name == MANIFEST_FILENAME, "Output must use website manifest filename")
        raw = serialize(inspect_dmg(args.tag, args.channel, args.dmg))
        if args.dry_run:
            sys.stdout.buffer.write(raw)
        else:
            atomic_write(args.output, raw)
            print("Release manifest v1 verified and written")
        return 0
    except (ManifestError, OSError):
        # OSError messages can contain private paths; only our own errors are safe.
        error = sys.exc_info()[1]
        print(str(error) if isinstance(error, ManifestError) else "Manifest filesystem operation failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
