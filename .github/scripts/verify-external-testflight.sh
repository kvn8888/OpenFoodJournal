#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: verify-external-testflight.sh TESTFLIGHT_TAG RELEASE_MANIFEST" >&2
  exit 64
fi

testflight_tag="$1"
manifest_path="$2"
config_path="ci/release-config.json"
tag_prefix="$(jq -r '.testFlightTagPrefix // empty' "${config_path}")"
version="$(jq -r '.version // empty' "${manifest_path}")"
build_number="$(jq -r '.buildNumber // empty' "${manifest_path}")"
expected_tag="${tag_prefix}${version}-${build_number}"

if [[ -z "${tag_prefix}" || "${testflight_tag}" != "${expected_tag}" ]]; then
  echo "Tag ${testflight_tag} does not match manifest version/build ${expected_tag}." >&2
  exit 1
fi

schema_version="$(jq -r '.schemaVersion // 0' "${manifest_path}")"
if [[ "${schema_version}" -ne 2 ]]; then
  echo "Release manifest schema ${schema_version} is not externally promotable." >&2
  exit 1
fi

for required_field in appStoreAppID buildID buildNumber version ipaSHA256 commitSHA whatToTest; do
  field_value="$(jq -r --arg field "${required_field}" '.[$field] // empty' "${manifest_path}")"
  if [[ -z "${field_value}" ]]; then
    echo "Release manifest is missing ${required_field}." >&2
    exit 1
  fi
done

tag_commit="$(git rev-list -n 1 "${testflight_tag}")"
manifest_commit="$(jq -r '.commitSHA' "${manifest_path}")"
if [[ "${manifest_commit}" != "${tag_commit}" ]]; then
  echo "Manifest commit ${manifest_commit} does not match ${testflight_tag} (${tag_commit})." >&2
  exit 1
fi

configured_app_id="$(jq -r '.appStoreAppID // empty' "${config_path}")"
manifest_app_id="$(jq -r '.appStoreAppID' "${manifest_path}")"
if [[ -z "${configured_app_id}" || "${manifest_app_id}" != "${configured_app_id}" ]]; then
  echo "Manifest app ${manifest_app_id} does not match configured app ${configured_app_id:-<missing>}." >&2
  exit 1
fi

internal_group_id="$(jq -r '.testFlightGroupID // empty' "${config_path}")"
external_group_id="$(jq -r '.externalTestFlightGroupID // empty' "${config_path}")"
if [[ -z "${external_group_id}" || "${external_group_id}" == "${internal_group_id}" ]]; then
  echo "External TestFlight group must be configured and differ from the internal group." >&2
  exit 1
fi

if [[ "$(jq -r '.releaseNotes.requiresHumanApproval // false' "${manifest_path}")" != "true" ]]; then
  echo "Release manifest does not require human approval." >&2
  exit 1
fi

echo "External TestFlight promotion matches ${testflight_tag}, build ${build_number}, and the configured public group."
