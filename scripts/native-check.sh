#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build --package-path native
swift run --package-path native RTCContractTests
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate --spec native/project.yml; else echo "SKIP: xcodegen unavailable"; fi
if command -v xcodebuild >/dev/null 2>&1; then echo "Xcode project compilation is an explicit follow-up gate"; else echo "REMAINING GATE: full Xcode build, UI tests, signing, and notarization (xcodebuild unavailable)"; fi
