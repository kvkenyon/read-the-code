#!/bin/sh
set -eu

if [ "${1-}" != "--dry-run" ] || [ "$#" -ne 1 ]; then
  printf '%s\n' 'usage: scripts/native-release/native-release-dry-run.sh --dry-run' >&2
  exit 64
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"
scripts/native-release/validate-release-config.sh
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/read-the-code-sbom.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
node scripts/native-release/generate-sbom.mjs --out "$temporary_directory/sbom.spdx.json" >/dev/null
test -s "$temporary_directory/sbom.spdx.json"
printf '%s\n' 'DRY RUN ONLY: archive/export, Developer ID signing, notarization, stapling, DMG/ZIP assembly, Sparkle appcast signing, clean-install/uninstall, and publication were not invoked.'
printf '%s\n' 'REMAINING GATE: run require-full-xcode.sh on a release host, then use externally supplied release credentials after RTC-900 and explicit captain authorization.'
