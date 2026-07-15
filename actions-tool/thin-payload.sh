#!/bin/sh
# Thin/strip Mach-O binaries in an .app payload for distribution.
# Safe on single-arch (arm64-only) binaries and when bitcode is absent.

set -eu

foreachThin() {
  for file in "$1"/*; do
    [ -e "$file" ] || continue
    if [ -f "$file" ]; then
      mime=$(file --mime-type -b "$file" 2>/dev/null || true)
      case "$mime" in
        application/x-mach-binary) ;;
        *)
          # Also treat .dylib by extension in case file(1) is inconclusive
          case "$file" in
            *.dylib) ;;
            *) continue ;;
          esac
          ;;
      esac
      echo "process $file"
      # Only thin fat binaries; skip if already thin (single arch)
      if lipo -info "$file" 2>/dev/null | grep -q 'Architectures in the fat file'; then
        xcrun -sdk iphoneos lipo "$file" -thin arm64 -output "$file"
      fi
      # bitcode_strip fails on binaries without bitcode on newer toolchains
      xcrun -sdk iphoneos bitcode_strip "$file" -r -o "$file" 2>/dev/null || true
      strip -S -x "$file" -o "$file" 2>/dev/null || true
    elif [ -d "$file" ]; then
      foreachThin "$file"
    fi
  done
}

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <path-to-.app>" >&2
  exit 1
fi

foreachThin "$1"
