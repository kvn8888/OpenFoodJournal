#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 4 ]]; then
  echo "Usage: verify-public-release-candidate.sh PUBLIC_VERSION RELEASE_JSON RELEASE_MANIFEST WHATS_NEW_FILE" >&2
  exit 64
fi

public_version="$1"
release_json="$2"
manifest_path="$3"
whats_new_path="$4"
repository_root="$(git rev-parse --show-toplevel)"
config_path="${repository_root}/ci/release-config.json"

tag_prefix="$(jq -r '.publicReleaseTagPrefix' "${config_path}")"
testflight_prefix="$(jq -r '.testFlightTagPrefix' "${config_path}")"
expected_tag="${tag_prefix}${public_version}"
release_tag="$(jq -r '.tag_name // empty' "${release_json}")"
manifest_version="$(jq -r '.version // empty' "${manifest_path}")"
build_number="$(jq -r '.buildNumber // empty' "${manifest_path}")"
manifest_commit="$(jq -r '.commitSHA // empty' "${manifest_path}")"

if [[ ! "${public_version}" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Apple returned malformed public version ${public_version:-<missing>}." >&2
  exit 1
fi
if [[ "$(jq -r '.draft // false' "${release_json}")" != "true" ]]; then
  echo "${release_tag:-<missing>} is not an unpublished GitHub release draft." >&2
  exit 1
fi
if [[ "${release_tag}" != "${expected_tag}" ]]; then
  echo "Draft tag ${release_tag:-<missing>} does not match public App Store version ${public_version}." >&2
  exit 1
fi
if [[ "$(jq -r '.schemaVersion // 0' "${manifest_path}")" -ne 2 ]]; then
  echo "Only schema-2 TestFlight manifests may become public GitHub releases." >&2
  exit 1
fi
if [[ "${manifest_version}" != "${public_version}" || -z "${build_number}" ]]; then
  echo "Manifest version/build does not match public App Store version ${public_version}." >&2
  exit 1
fi

testflight_tag="${testflight_prefix}${manifest_version}-${build_number}"
testflight_commit="$(git rev-list -n 1 "${testflight_tag}" 2>/dev/null || true)"
if [[ -z "${testflight_commit}" || "${testflight_commit}" != "${manifest_commit}" ]]; then
  echo "Manifest commit does not match immutable ${testflight_tag}." >&2
  exit 1
fi

release_commit="$(git rev-list -n 1 "${release_tag}" 2>/dev/null || true)"
if [[ -z "${release_commit}" ]]; then
  release_commit="$(jq -r '.target_commitish // empty' "${release_json}")"
fi
if [[ "${release_commit}" != "${manifest_commit}" ]]; then
  echo "Draft ${release_tag} does not target manifest commit ${manifest_commit}." >&2
  exit 1
fi

configured_app_id="$(jq -r '.appStoreAppID' "${config_path}")"
if [[ "$(jq -r '.appStoreAppID // empty' "${manifest_path}")" != "${configured_app_id}" ]]; then
  echo "Manifest app does not match configured App Store app ${configured_app_id}." >&2
  exit 1
fi

expected_notes_sha="$(jq -r '.whatsNewSHA256 // empty' "${manifest_path}")"
actual_notes_sha="$(shasum -a 256 "${whats_new_path}" | awk '{print $1}')"
if [[ -z "${expected_notes_sha}" || "${actual_notes_sha}" != "${expected_notes_sha}" ]]; then
  echo "Public release notes do not match the immutable TestFlight manifest." >&2
  exit 1
fi

canonical_notes="$(mktemp)"
trap 'rm -f "${canonical_notes}"' EXIT
printf '%s\n' "$(jq -r '.whatsNew // empty' "${manifest_path}")" > "${canonical_notes}"
if ! cmp -s "${canonical_notes}" "${whats_new_path}"; then
  echo "Public release notes content differs from the manifest." >&2
  exit 1
fi

bash "${repository_root}/.github/scripts/validate-release-notes.sh" \
  "${whats_new_path}" \
  "$(jq -r '.primaryLocale' "${manifest_path}")"

echo "${release_tag} is verified for App Store ${manifest_version} build ${build_number}."
