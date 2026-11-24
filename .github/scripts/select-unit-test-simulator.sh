#!/bin/bash

set -euo pipefail

sdk_version="$(xcrun --sdk iphonesimulator --show-sdk-version)"
runtime="com.apple.CoreSimulator.SimRuntime.iOS-${sdk_version//./-}"
simulator_id="$(
  xcrun simctl list devices available --json |
    jq -r --arg runtime "${runtime}" \
      '[.devices[$runtime][]? | select(.name | startswith("iPhone"))][0].udid // empty'
)"

if [[ -z "${simulator_id}" ]]; then
  echo "The hosted Xcode image has no available iOS ${sdk_version} iPhone simulator for unit tests." >&2
  exit 1
fi

echo "Selected unit-test simulator ${simulator_id}."

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'UNIT_TEST_SIMULATOR_ID=%s\n' "${simulator_id}" >> "${GITHUB_ENV}"
else
  printf '%s\n' "${simulator_id}"
fi
