#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/../.." && pwd)"
config_path="${repository_root}/ci/release-config.json"

expected_version="$(jq -r '.requiredXcodeVersion' "${config_path}")"
expected_build="$(jq -r '.requiredXcodeBuild' "${config_path}")"
xcode_details="$(xcodebuild -version)"
actual_version="$(printf '%s\n' "${xcode_details}" | sed -n '1p')"
actual_build="$(printf '%s\n' "${xcode_details}" | sed -n '2s/^Build version //p')"

printf '%s\n' "${xcode_details}"

if [[ "${actual_version}" != "${expected_version}" || "${actual_build}" != "${expected_build}" ]]; then
  echo "The hosted image no longer matches the pinned OpenFoodJournal toolchain." >&2
  echo "Expected ${expected_version} (${expected_build}); received ${actual_version} (${actual_build})." >&2
  echo "Review the xcode-27 runner image before changing ci/release-config.json." >&2
  exit 1
fi
