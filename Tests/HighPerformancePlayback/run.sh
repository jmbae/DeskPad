#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
playback_test_dir=$(mktemp -d)
trap 'rm -rf "$playback_test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos14.0" DeskPad/HighPerformancePlayback.swift Tests/HighPerformancePlayback/main.swift -o "$playback_test_dir/tests"
"$playback_test_dir/tests" Tests/HighPerformancePlayback/black.h264 Tests/HighPerformancePlayback/tone.aac-au
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -typecheck -target arm64-apple-ios26.0-simulator -sdk "$sdk" DeskPad/HighPerformancePlayback.swift
