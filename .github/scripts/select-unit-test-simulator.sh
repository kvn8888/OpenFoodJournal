#!/bin/bash

set -euo pipefail

simulator_id="$(
  xcrun simctl list devices available --json |
    jq -r '[.devices[][] | select(.name | startswith("iPhone"))][0].udid // empty'
)"

if [[ -z "${simulator_id}" ]]; then
  echo "The hosted Xcode image has no available iPhone simulator for unit tests." >&2
  exit 1
fi

echo "Selected unit-test simulator ${simulator_id}."

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'UNIT_TEST_SIMULATOR_ID=%s\n' "${simulator_id}" >> "${GITHUB_ENV}"
else
  printf '%s\n' "${simulator_id}"
fi
