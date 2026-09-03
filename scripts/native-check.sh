#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

swift build --package-path native
node scripts/validate-native-manifests.mjs
if swift -e 'import XCTest' >/dev/null 2>&1; then
    swift test --package-path native
else
    echo "REMAINING GATE: XCTest test targets (XCTest unavailable in Command Line Tools)"
fi

for test_target in \
    RTCCLITests \
    RTCContractTests \
    RTCDiagramTests \
    RTCDiffCanvasTests \
    RTCDomainTests \
    RTCIPCTests \
    RTCLifecycleTests \
    RTCReviewTests \
    RTCReviewWorkspaceFeatureTests \
    RTCSyntaxTests \
    RTCTourTests \
    TourWorkspaceFeatureTests
do
    swift run --package-path native "$test_target"
done

developer_dir=$(xcode-select -p 2>/dev/null || true)
if command -v xcodegen >/dev/null 2>&1; then
    generated_project_dir=.test-state/native-xcodegen
    mkdir -p "$generated_project_dir"
    xcodegen generate \
        --spec native/project.yml \
        --project "$generated_project_dir" \
        --project-root native
    if [ -n "$developer_dir" ] && [ "${developer_dir##*/}" != "CommandLineTools" ] && command -v xcodebuild >/dev/null 2>&1; then
        xcodebuild \
            -project "$generated_project_dir/ReadTheCode.xcodeproj" \
            -alltargets \
            -configuration Debug \
            CODE_SIGNING_ALLOWED=NO \
            build
    else
        echo "REMAINING GATE: full Xcode build, UI tests, signing, and notarization (Command Line Tools only)"
    fi
else
    echo "SKIP: xcodegen unavailable"
    echo "REMAINING GATE: Xcode project generation/build, UI tests, signing, and notarization"
fi
