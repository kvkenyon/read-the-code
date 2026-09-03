#!/bin/sh
set -eu

developer_dir=$(xcode-select -p 2>/dev/null || true)
if [ -z "$developer_dir" ] || [ "$developer_dir" = "/Library/Developer/CommandLineTools" ]; then
  printf '%s\n' 'REMAINING GATE: a full Xcode toolchain is required for archive, signing, notarization, stapling, and packaged-install validation; Command Line Tools evidence is not sufficient.' >&2
  exit 69
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  printf '%s\n' 'REMAINING GATE: xcodebuild from a full Xcode toolchain is required for native release operations.' >&2
  exit 69
fi

printf '%s\n' "Full Xcode toolchain selected at $developer_dir."
