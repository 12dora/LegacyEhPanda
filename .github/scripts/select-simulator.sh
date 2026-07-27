#!/bin/bash
#
# Prints "<udid>|<device name>|<runtime version>" for the newest *available*
# iPhone simulator on this machine.
#
# Usage:
#   select-simulator.sh          # newest available iOS runtime
#   select-simulator.sh 16       # newest available iOS 16.x runtime
#
# Selecting by UDID instead of by a hard-coded device name keeps the workflows
# working across runner-image refreshes (the old workflows pinned
# "iPhone 15 Pro", which does not exist on every image).
set -euo pipefail

WANT_MAJOR="${1:-}" xcrun simctl list devices available --json | python3 -c '
import json
import os
import sys

want = os.environ.get("WANT_MAJOR") or ""
devices_by_runtime = json.load(sys.stdin)["devices"]

best = None
for runtime, devices in devices_by_runtime.items():
    identifier = runtime.rsplit(".", 1)[-1]
    if not identifier.startswith("iOS-"):
        continue
    try:
        version = tuple(int(part) for part in identifier[len("iOS-"):].split("-"))
    except ValueError:
        continue
    if want and str(version[0]) != want:
        continue
    for device in devices:
        if not device.get("isAvailable"):
            continue
        if not device.get("name", "").startswith("iPhone"):
            continue
        key = (version, device["name"])
        if best is None or key > best[0]:
            best = (key, device, version)

if best is None:
    sys.exit(
        "No available iPhone simulator"
        + (" for iOS %s.x" % want if want else "")
        + " was found on this runner."
    )

_, device, version = best
print("%s|%s|%s" % (device["udid"], device["name"], ".".join(str(p) for p in version)))
'
