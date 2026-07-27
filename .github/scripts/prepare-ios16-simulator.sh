#!/bin/bash
#
# Makes an iOS 16 simulator available on this machine and prints the UDID of a
# device booted on it. Progress goes to stderr so stdout stays parseable.
#
# No GitHub-hosted runner image ships an iOS 16 runtime any more (macos-13 with
# Xcode 14.3.1 + iOS 16.4 has been retired), so the runtime is downloaded on
# demand. Apple can withdraw a given runtime download for a given Xcode at any
# time, which is why the calling job is marked continue-on-error.
set -euo pipefail

if ! xcrun simctl list runtimes | grep -qE '^iOS 16\.'; then
  echo "Downloading the iOS 16.4 simulator runtime (this can take several minutes)..." >&2
  xcodebuild -downloadPlatform iOS -buildVersion 16.4 >&2
fi

RUNTIME_ID="$(
  xcrun simctl list runtimes \
    | grep -E '^iOS 16\.' \
    | grep -v 'unavailable' \
    | tail -1 \
    | awk '{ print $NF }'
)"

if [ -z "${RUNTIME_ID}" ]; then
  echo "::error::No iOS 16 simulator runtime is available on this runner." >&2
  exit 1
fi
echo "Using runtime ${RUNTIME_ID}" >&2

DEVICE_TYPE=""
for candidate in "iPhone 14" "iPhone 14 Pro" "iPhone 13" "iPhone SE (3rd generation)"; do
  if xcrun simctl list devicetypes | grep -qF "${candidate} ("; then
    DEVICE_TYPE="${candidate}"
    break
  fi
done

if [ -z "${DEVICE_TYPE}" ]; then
  echo "::error::No iPhone device type usable with the iOS 16 runtime was found." >&2
  exit 1
fi
echo "Using device type ${DEVICE_TYPE}" >&2

xcrun simctl create "EhPanda-iOS16" "${DEVICE_TYPE}" "${RUNTIME_ID}"
