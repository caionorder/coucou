#!/usr/bin/env bash
# Optional API key for a local model server (Ollama, LM Studio, oMLX…): request building,
# 401/403 mapping, and an end-to-end run against a fake server that requires a key.
set -euo pipefail
cd "$(dirname "$0")/.."

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-local-chat-auth.XXXXXX")"
SERVER_PID=""
trap 'rm -rf "$TEST_DIR"; [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true' EXIT

PORT_FILE="$TEST_DIR/port.txt"
python3 tests/fake_local_llm_auth.py "$PORT_FILE" &
SERVER_PID=$!

swiftc \
    NotchBuddy/Sources/App/LocalChat.swift \
    tests/LocalChatAuthTests.swift \
    -o "$TEST_DIR/local-chat-auth-tests"

for i in $(seq 1 300); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "ERROR: fake server exited unexpectedly" >&2
        exit 1
    fi
    [ -s "$PORT_FILE" ] && break
    sleep 0.1
done
[ -s "$PORT_FILE" ] || { echo "ERROR: fake server did not write its port within 30 s" >&2; exit 1; }

"$TEST_DIR/local-chat-auth-tests" "$(cat "$PORT_FILE")"
