#!/usr/bin/env bash
# the manifest version and the exported constant must agree. this drift has
# reached both long-lived branches once already: src/lib.mach reported 0.4.0
# while the manifest had moved to 0.5.0.
set -euo pipefail
[ "$MACH_CI_PRIMARY" = true ] || exit 0
manifest=$(awk -F'"' '/^version = "/ { print $2; exit }' mach.toml)
exported=$(awk -F'"' '/^pub val VERSION: str = "/ { print $2; exit }' src/lib.mach)
if [ -z "$manifest" ] || [ -z "$exported" ]; then
  echo "::error::release version is missing: mach.toml=${manifest:-<none>} src/lib.mach=${exported:-<none>}"
  exit 1
fi
if [ "$manifest" != "$exported" ]; then
  echo "::error::release version mismatch: mach.toml=$manifest src/lib.mach=$exported"
  exit 1
fi
echo "release version $manifest"
