#!/bin/bash
# Measure synthetic Activity lifecycle operations with a normal AppKit run loop.
# The production checkout, preferences, and provider backend are untouched.
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
project_root="$(cd "$(dirname "$0")/.." && pwd)"
profile_root="$(mktemp -d /tmp/quotamew-m5-profile.XXXXXX)"
mkdir -p "$profile_root/source"
ditto "$project_root/QuotaMew" "$profile_root/source/QuotaMew"
ditto "$project_root/QuotaMew.xcodeproj" "$profile_root/source/QuotaMew.xcodeproj"
cp "$project_root/scripts/fixtures/M5NativeResourceHarness.swift" \
   "$profile_root/source/QuotaMew/App/QuotaMewApp.swift"
printf 'Profile artifacts: %s\n' "$profile_root"
xcodebuild -project "$profile_root/source/QuotaMew.xcodeproj" -scheme QuotaMew \
  -configuration Release -derivedDataPath "$profile_root/build" CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=dev.quotapulse.m5.resource-harness build -quiet \
  > "$profile_root/build.log" 2>&1
app_path="$profile_root/build/Build/Products/Release/QuotaMew.app"
report_path="$profile_root/resource.log"
open -n "$app_path" --args --m5-resource-report "$report_path"
# LaunchServices returns before the fixture finishes. Bound the wait and reap
# only this fixture's executable if it fails to terminate normally.
python3 - "$app_path/Contents/MacOS/QuotaMew" "$report_path" <<'PY'
import os
import signal
import subprocess
import sys
import time

executable, report = sys.argv[1:]
deadline = time.monotonic() + 60
def owned_pids():
    listing = subprocess.check_output(['/bin/ps', '-axo', 'pid=,command='], text=True)
    expected = os.path.realpath(executable)
    return [int(pid) for line in listing.splitlines()
            for pid, _, command in [line.strip().partition(' ')]
            if command.strip().startswith((executable, expected))]

while time.monotonic() < deadline:
    if os.path.isfile(report) and not owned_pids():
        with open(report, encoding='utf-8') as handle:
            result = handle.read(8192)
        print(result)
        sys.exit(0 if 'result=PASS' in result else 1)
    time.sleep(0.2)
for pid in owned_pids():
    os.kill(pid, signal.SIGTERM)
raise SystemExit('Native resource fixture did not complete within 60 seconds')
PY
