#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: verify-promotion.sh TESTFLIGHT_TAG RELEASE_MANIFEST" >&2
  exit 64
fi

testflight_tag="$1"
manifest_path="$2"
tag_commit="$(git rev-list -n 1 "${testflight_tag}")"
manifest_commit="$(jq -r '.commitSHA // empty' "${manifest_path}")"

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

for required_field in appStoreAppID buildID buildNumber version ipaSHA256; do
  field_value="$(jq -r --arg field "${required_field}" '.[$field] // empty' "${manifest_path}")"
  if [[ -z "${field_value}" ]]; then
    echo "Release manifest is missing ${required_field}." >&2
    exit 1
  fi
done

echo "Promotion manifest matches ${testflight_tag} and app-store contains no later binary changes."
