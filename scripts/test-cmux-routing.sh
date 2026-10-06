#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-cmux-routing.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/CmuxRouting.swift \
    tests/CmuxRoutingTests.swift -o "$TEST_DIR/cmux-routing-tests"
"$TEST_DIR/cmux-routing-tests"
