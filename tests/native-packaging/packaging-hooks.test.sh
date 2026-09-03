#!/bin/sh
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
  printf '%s\n' 'SKIP: native packaging hooks require macOS; unsigned validation runs in the native macOS workflow.'
  exit 0
fi

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)
cd "$repo_root"

scripts/native-release/validate-release-config.sh
sbom_path=$(mktemp "${TMPDIR:-/tmp}/read-the-code-sbom.XXXXXX.json")
xcode_output=$(mktemp "${TMPDIR:-/tmp}/read-the-code-xcode.XXXXXX")
unsigned_output=$(mktemp "${TMPDIR:-/tmp}/read-the-code-unsigned.XXXXXX")
trap 'rm -f "$sbom_path" "$xcode_output" "$unsigned_output"' EXIT HUP INT TERM
node scripts/native-release/generate-sbom.mjs --out "$sbom_path" >/dev/null
node -e 'const fs = require("fs"); const sbom = JSON.parse(fs.readFileSync(process.argv[1])); if (sbom.spdxVersion !== "SPDX-2.3" || sbom.packages.length !== 2) process.exit(1)' "$sbom_path"
scripts/native-release/native-release-dry-run.sh --dry-run

if xcode-select -p 2>/dev/null | grep -Fqx /Library/Developer/CommandLineTools; then
  if scripts/native-release/require-full-xcode.sh >"$xcode_output" 2>&1; then
    echo 'expected Command Line Tools to reject an Xcode-only release operation' >&2
    exit 1
  fi
  grep -Fq 'full Xcode toolchain is required' "$xcode_output"
else
  scripts/native-release/require-full-xcode.sh >"$xcode_output"
fi

if scripts/native-release/validate-signed-app.sh --app /tmp/does-not-exist.app --expected-team EXAMPLE >"$unsigned_output" 2>&1; then
  echo 'expected missing app to be rejected' >&2
  exit 1
fi
grep -Fq 'unsigned or missing app bundle' "$unsigned_output"
printf '%s\n' 'Native packaging hooks passed.'
