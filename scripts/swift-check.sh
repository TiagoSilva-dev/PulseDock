#!/bin/bash
# Runs a swift command and prints only compiler diagnostics (file:line: error|warning) and
# test results, without the long command lines. Usage: scripts/swift-check.sh build|test [args…]
set -o pipefail
cd "$(dirname "$0")/.."
output=$(swift "$@" 2>&1)
status=$?
echo "$output" | sed -E 's/\x1b\[[0-9;]*m//g' \
  | grep -E '^/[^ ]+:[0-9]+:[0-9]+: (error|warning):|^error: (fatalError|Build failed)$|✘|Test run with|tests? (passed|failed)|recorded an issue|Expectation failed|Build complete' \
  | grep -v 'SwiftCompile normal' | awk '!seen[$0]++' | head -${CHECK_LINES:-80}
exit $status
