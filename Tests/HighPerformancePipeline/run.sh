#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
pipeline_test_dir=$(mktemp -d)
trap 'rm -rf "$pipeline_test_dir"' EXIT
swiftc -target "$(uname -m)-apple-macos14.0" DeskPad/HighPerformanceMedia.swift DeskPad/HighPerformancePlayback.swift DeskPad/AppleHPVideoDepacketizer.swift DeskPad/AppleHPHEVCDepacketizer.swift DeskPad/HighPerformanceMediaPipeline.swift Tests/HighPerformancePipeline/Harness.swift -o "$pipeline_test_dir/tests"
"$pipeline_test_dir/tests" Tests/HighPerformancePlayback/black.h264
"$pipeline_test_dir/tests" Tests/HighPerformancePlayback/intra-nonidr.h264
sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun swiftc -typecheck -target arm64-apple-ios26.0-simulator -sdk "$sdk" DeskPad/HighPerformanceMedia.swift DeskPad/HighPerformancePlayback.swift DeskPad/AppleHPVideoDepacketizer.swift DeskPad/AppleHPHEVCDepacketizer.swift DeskPad/HighPerformanceMediaPipeline.swift
