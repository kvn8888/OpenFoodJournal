#!/bin/bash
# Required API gates must execute, not merely return a green XCTest suite.
set -euo pipefail
log_path="${1:?Supply the xcodebuild log path}"
method="${2:?Supply the required XCTest method}"
[[ "$method" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo 'Invalid test identifier.' >&2; exit 2; }
[[ -f "$log_path" ]] || { echo 'Required test log is missing.' >&2; exit 1; }
events="$(grep -F 'Test Case ' "$log_path" | grep -F " ${method}]" || true)"
if printf '%s\n' "$events" | grep -Eq ' (skipped|failed) \('; then
  echo "Required live test ${method} was skipped or failed." >&2
  exit 1
fi
passed="$(printf '%s\n' "$events" | grep -Ec ' passed \(' || true)"
if [[ "$passed" != 1 ]]; then
  echo "Expected exactly one passing execution of ${method}; found ${passed}." >&2
  exit 1
fi
echo "Verified one executed, passing live test: ${method}."
