#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null 2>&1 && xcodegen generate --spec native/project.yml
swift package --package-path native resolve
echo "Native workspace prepared. Full Xcode archive/sign/notarization remains an Xcode-only gate."
