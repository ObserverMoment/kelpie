#!/usr/bin/env bash
# Prints the newest Command Line Tools macOS SDK that the pinned Zig can link
# (26.3 or older, see select-developer-dir.sh). Exits 1 when none is installed.
set -euo pipefail
shopt -s nullglob

sdks=(/Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.[0-9]*.sdk)
best="$(
  for sdk in ${sdks[@]+"${sdks[@]}"}; do
    ver="$(basename "${sdk}" .sdk)"
    ver="${ver#MacOSX}"
    [ "$(printf '%s\n26.3\n' "${ver}" | sort -V | tail -1)" = "26.3" ] && printf '%s %s\n' "${ver}" "${sdk}"
  done | sort -V | tail -1 | cut -d' ' -f2-
)"
[ -n "${best}" ] || exit 1
printf '%s\n' "${best}"
