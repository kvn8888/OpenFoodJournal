#!/bin/bash

set -euo pipefail

expected_kind="preview-uat"
if [[ "${1:-}" == "--kind" ]]; then
  if [[ "$#" -lt 4 ]]; then
    echo "Usage: verify-promotion.sh [--kind preview-uat|production-rc] TAG RELEASE_MANIFEST [WHATS_NEW_FILE]" >&2
    exit 64
  fi
  expected_kind="$2"
  shift 2
fi

if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
  echo "Usage: verify-promotion.sh [--kind preview-uat|production-rc] TAG RELEASE_MANIFEST [WHATS_NEW_FILE]" >&2
  exit 64
fi

if [[ "${expected_kind}" != "preview-uat" && "${expected_kind}" != "production-rc" ]]; then
  echo "Unsupported manifest kind: ${expected_kind}" >&2
  exit 64
fi

release_tag="$1"
manifest_path="$2"
whats_new_path="${3:-}"
tag_commit="$(git rev-list -n 1 "${release_tag}")"
manifest_commit="$(jq -r '.commitSHA // empty' "${manifest_path}")"
schema_version="$(jq -r '.schemaVersion // 0' "${manifest_path}")"
manifest_kind="$(jq -r '.manifestKind // empty' "${manifest_path}")"

if [[ "${schema_version}" -ne 3 ]]; then
  echo "Release manifest schema ${schema_version} is not promotable; create a schema-3 ${expected_kind} manifest." >&2
  exit 1
fi

if [[ "${manifest_kind}" != "${expected_kind}" ]]; then
  echo "Release manifest kind ${manifest_kind:-<missing>} does not match expected ${expected_kind}." >&2
  exit 1
fi

if [[ -z "${manifest_commit}" || "${manifest_commit}" != "${tag_commit}" ]]; then
  echo "Release manifest commit ${manifest_commit:-<missing>} does not match ${release_tag} (${tag_commit})." >&2
  exit 1
fi

if ! git merge-base --is-ancestor "${tag_commit}" HEAD; then
  echo "${release_tag} is not an ancestor of HEAD." >&2
  exit 1
fi

if ! git diff --quiet "${release_tag}..HEAD" -- OpenFoodJournal OpenFoodJournal.xcodeproj; then
  echo "App-affecting files changed after ${release_tag}:" >&2
  git diff --name-only "${release_tag}..HEAD" -- OpenFoodJournal OpenFoodJournal.xcodeproj >&2
  echo "Create a new Preview UAT build before App Store promotion." >&2
  exit 1
fi

for required_field in \
  appStoreAppID \
  bundleIdentifier \
  cloudKitContainerIdentifier \
  xcodeConfiguration \
  buildID \
  buildNumber \
  version \
  ipaSHA256 \
  primaryLocale \
  whatsNew \
  whatsNewSHA256 \
  whatToTest
do
  field_value="$(jq -r --arg field "${required_field}" '.[$field] // empty' "${manifest_path}")"
  if [[ -z "${field_value}" ]]; then
    echo "Release manifest is missing ${required_field}." >&2
    exit 1
  fi
done

if [[ "${expected_kind}" == "preview-uat" ]]; then
  configured_app_id="$(jq -r '.preview.appStoreAppID // empty' ci/release-config.json)"
  prod_app_id="$(jq -r '.appStoreAppID // empty' ci/release-config.json)"
  configured_bundle_id="$(jq -r '.preview.bundleIdentifier // empty' ci/release-config.json)"
  configured_cloudkit="$(jq -r '.preview.cloudKitContainerIdentifier // empty' ci/release-config.json)"
  configured_xcode_config="$(jq -r '.preview.xcodeConfiguration // empty' ci/release-config.json)"
  if [[ -z "${configured_app_id}" ]]; then
    echo "ci/release-config.json is missing preview.appStoreAppID." >&2
    exit 1
  fi
  if [[ "${configured_app_id}" == "${prod_app_id}" ]]; then
    echo "preview.appStoreAppID must not equal production appStoreAppID." >&2
    exit 1
  fi
else
  configured_app_id="$(jq -r '.appStoreAppID // empty' ci/release-config.json)"
  configured_bundle_id="$(jq -r '.bundleIdentifier // empty' ci/release-config.json)"
  configured_cloudkit="$(jq -r '.cloudKitContainerIdentifier // empty' ci/release-config.json)"
  configured_xcode_config="Release"
  source_preview_tag="$(jq -r '.sourcePreviewTag // empty' "${manifest_path}")"
  if [[ -z "${source_preview_tag}" ]]; then
    echo "Production RC manifest is missing sourcePreviewTag." >&2
    exit 1
  fi
fi

manifest_app_id="$(jq -r '.appStoreAppID' "${manifest_path}")"
manifest_bundle_id="$(jq -r '.bundleIdentifier' "${manifest_path}")"
manifest_cloudkit="$(jq -r '.cloudKitContainerIdentifier' "${manifest_path}")"
manifest_xcode_config="$(jq -r '.xcodeConfiguration' "${manifest_path}")"

if [[ "${manifest_app_id}" != "${configured_app_id}" ]]; then
  echo "Manifest app ${manifest_app_id} does not match configured ${expected_kind} app ${configured_app_id}." >&2
  exit 1
fi
if [[ "${manifest_bundle_id}" != "${configured_bundle_id}" ]]; then
  echo "Manifest bundle ID ${manifest_bundle_id} does not match configured ${expected_kind} bundle ID ${configured_bundle_id}." >&2
  exit 1
fi
if [[ "${manifest_cloudkit}" != "${configured_cloudkit}" ]]; then
  echo "Manifest CloudKit container ${manifest_cloudkit} does not match configured ${expected_kind} container ${configured_cloudkit}." >&2
  exit 1
fi
if [[ "${manifest_xcode_config}" != "${configured_xcode_config}" ]]; then
  echo "Manifest configuration ${manifest_xcode_config} does not match configured ${expected_kind} configuration ${configured_xcode_config}." >&2
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

echo "Verified ${expected_kind} manifest for ${release_tag} (${manifest_bundle_id}, ${manifest_cloudkit}) with no later binary changes."
