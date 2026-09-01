#!/bin/bash
set -euo pipefail
fixture_dir="$(mktemp -d)"
trap 'rm -rf "$fixture_dir"' EXIT
method=testGeminiFoodIconImageLiveContract
validator=.github/scripts/verify-live-test-log.sh
prefix="Test Case '-[OpenFoodJournalTests.ChatLiveProviderTests ${method}]'"
printf '%s passed (1.234 seconds).\n' "$prefix" > "$fixture_dir/pass.log"
bash "$validator" "$fixture_dir/pass.log" "$method" >/dev/null
printf '%s skipped (0.001 seconds).\n' "$prefix" > "$fixture_dir/skip.log"
printf '%s failed (0.001 seconds).\n' "$prefix" > "$fixture_dir/fail.log"
printf '%s\n' '** TEST SUCCEEDED **' > "$fixture_dir/empty.log"
printf '%s\n' "Test Case '-[Tests.Other testOther]' passed (0.1 seconds)." > "$fixture_dir/other.log"
printf '%s passed (1.0 seconds).\n%s passed (1.0 seconds).\n' "$prefix" "$prefix" > "$fixture_dir/duplicate.log"
printf '%s skipped (0.1 seconds).\n%s passed (1.0 seconds).\n' "$prefix" "$prefix" > "$fixture_dir/mixed.log"
for name in skip fail empty other duplicate mixed missing; do
  if bash "$validator" "$fixture_dir/$name.log" "$method" >/dev/null 2>&1; then
    echo "Live gate incorrectly accepted $name fixture." >&2
    exit 1
  fi
done
echo 'Live test gate: 8 fixture cases passed.'
