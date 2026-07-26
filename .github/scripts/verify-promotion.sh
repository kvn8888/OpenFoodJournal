#!/bin/bash

set -euo pipefail

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "Usage: verify-promotion.sh TESTFLIGHT_TAG RELEASE_MANIFEST [WHATS_NEW_FILE]" >&2
  exit 64
fi

testflight_tag="$1"
manifest_path="$2"
whats_new_path="${3:-}"
tag_commit="$(git rev-list -n 1 "${testflight_tag}")"
manifest_commit="$(jq -r '.commitSHA // empty' "${manifest_path}")"
schema_version="$(jq -r '.schemaVersion // 0' "${manifest_path}")"

if [[ "${schema_version}" -ne 2 ]]; then
  echo "Release manifest schema ${schema_version} is not promotable; create a new TestFlight build with schema 2." >&2
  exit 1
fi

if [[ -z "${manifest_commit}" || "${manifest_commit}" != "${tag_commit}" ]]; then
  echo "Release manifest commit ${manifest_commit:-<missing>} does not match ${testflight_tag} (${tag_commit})." >&2
  exit 1
fi

if ! git merge-base --is-ancestor "${tag_commit}" HEAD; then
  echo "${testflight_tag} is not an ancestor of app-store HEAD." >&2
  exit 1
fi

if ! git diff --quiet "${testflight_tag}..HEAD" -- OpenFoodJournal OpenFoodJournal.xcodeproj; then
  echo "App-affecting files changed after the tested TestFlight build:" >&2
  git diff --name-only "${testflight_tag}..HEAD" -- OpenFoodJournal OpenFoodJournal.xcodeproj >&2
  echo "Create a new TestFlight build before App Store promotion." >&2
  exit 1
fi

for required_field in appStoreAppID buildID buildNumber version ipaSHA256 primaryLocale whatsNew whatsNewSHA256 whatToTest; do
  field_value="$(jq -r --arg field "${required_field}" '.[$field] // empty' "${manifest_path}")"
  if [[ -z "${field_value}" ]]; then
    echo "Release manifest is missing ${required_field}." >&2
    exit 1
  fi
done

configured_app_id="$(jq -r '.appStoreAppID' ci/release-config.json)"
manifest_app_id="$(jq -r '.appStoreAppID' "${manifest_path}")"
if [[ "${manifest_app_id}" != "${configured_app_id}" ]]; then
  echo "Manifest app ${manifest_app_id} does not match configured app ${configured_app_id}." >&2
  exit 1
fi

if [[ "$(jq -r '.releaseNotes.requiresHumanApproval // false' "${manifest_path}")" != "true" ]]; then
  echo "Release manifest does not require human approval." >&2
  exit 1
fi

if [[ -n "${whats_new_path}" ]]; then
  expected_sha="$(jq -r '.whatsNewSHA256' "${manifest_path}")"
  actual_sha="$(shasum -a 256 "${whats_new_path}" | awk '{print $1}')"
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    echo "What's New asset hash does not match the immutable manifest." >&2
    exit 1
  fi

  canonical_notes="$(mktemp)"
  trap 'rm -f "${canonical_notes}"' EXIT
  printf '%s\n' "$(jq -r '.whatsNew' "${manifest_path}")" > "${canonical_notes}"
  if ! cmp -s "${canonical_notes}" "${whats_new_path}"; then
    echo "What's New asset content does not match the immutable manifest." >&2
    exit 1
  fi
  bash .github/scripts/validate-release-notes.sh \
    "${whats_new_path}" \
    "$(jq -r '.primaryLocale' "${manifest_path}")"
fi

echo "Promotion manifest matches ${testflight_tag} and app-store contains no later binary changes."
