#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd -P)
swift build --package-path "$repository_root/native" -c release --target RTCGit >&2
build_dir=$(swift build --package-path "$repository_root/native" -c release --show-bin-path)
benchmark_binary=$(mktemp "${TMPDIR:-/tmp}/rtc-git-benchmark.XXXXXX")
trap 'rm -f "$benchmark_binary"' EXIT HUP INT TERM

swiftc -O -parse-as-library \
    "$repository_root/native/Fixtures/Git/RTCGitBenchmark.swift" \
    "$build_dir/RTCGit.build/GitEngine.swift.o" \
    "$build_dir/RTCContracts.build/Contracts.swift.o" \
    "$build_dir/RTCContracts.build/JSONPreflight.swift.o" \
    -I "$build_dir/Modules" \
    -o "$benchmark_binary"
"$benchmark_binary"
