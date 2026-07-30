#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: prepare-github-app-store-release.sh RELEASE_MANIFEST WHATS_NEW_FILE" >&2
  exit 64
fi

manifest_path="$1"
whats_new_path="$2"
repository="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
repository_root="$(git rev-parse --show-toplevel)"
config_path="${repository_root}/ci/release-config.json"

version="$(jq -r '.version // empty' "${manifest_path}")"
build_number="$(jq -r '.buildNumber // empty' "${manifest_path}")"
commit_sha="$(jq -r '.commitSHA // empty' "${manifest_path}")"
tag_prefix="$(jq -r '.publicReleaseTagPrefix' "${config_path}")"

if [[ ! "${version}" =~ ^[0-9]+([.][0-9]+){1,2}$ ]]; then
  echo "Manifest version ${version:-<missing>} is not a supported App Store version." >&2
  exit 1
fi
if [[ -z "${build_number}" || ! "${commit_sha}" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Manifest build number or commit SHA is missing or malformed." >&2
  exit 1
fi

release_tag="${tag_prefix}${version}"
github_notes="${RUNNER_TEMP:-/tmp}/github-app-store-release-notes.md"
{
  printf 'App Store release: **version %s (build %s)**.\n\n' "${version}" "${build_number}"
  cat "${whats_new_path}"
  printf '\n'
} > "${github_notes}"

existing_release="$(
  gh api "repos/${repository}/releases?per_page=100" --paginate |
    jq -cs --arg tag "${release_tag}" \
      '[.[][] | select(.tag_name == $tag)] | first // empty'
)"

if [[ -n "${existing_release}" ]]; then
  existing_body="$(jq -r '.body // empty' <<< "${existing_release}")"
  if ! cmp -s <(printf '%s\n' "${existing_body}") "${github_notes}"; then
    echo "${release_tag} already exists with different release notes." >&2
    exit 1
  fi

  tag_commit="$(git rev-list -n 1 "${release_tag}" 2>/dev/null || true)"
  target_commit="$(jq -r '.target_commitish // empty' <<< "${existing_release}")"
  if [[ -n "${tag_commit}" ]]; then
    target_commit="${tag_commit}"
  fi
  if [[ "${target_commit}" != "${commit_sha}" ]]; then
    echo "${release_tag} targets ${target_commit:-<missing>}, not manifest commit ${commit_sha}." >&2
    exit 1
  fi

  if [[ "$(jq -r '.draft' <<< "${existing_release}")" == "true" ]]; then
    asset_names="$(jq -r '.assets[]?.name' <<< "${existing_release}")"
    grep -qx 'release-manifest.json' <<< "${asset_names}" ||
      { echo "${release_tag} draft is missing release-manifest.json." >&2; exit 1; }
    grep -qx 'whats-new.txt' <<< "${asset_names}" ||
      { echo "${release_tag} draft is missing whats-new.txt." >&2; exit 1; }
    echo "${release_tag} draft already matches the approved App Store candidate."
  else
    echo "${release_tag} is already published."
  fi
  exit 0
fi

existing_tag_commit="$(git rev-list -n 1 "${release_tag}" 2>/dev/null || true)"
release_target_args=(--target "${commit_sha}")
if [[ -n "${existing_tag_commit}" ]]; then
  if [[ "${existing_tag_commit}" != "${commit_sha}" ]]; then
    echo "${release_tag} points to ${existing_tag_commit}, not manifest commit ${commit_sha}." >&2
    exit 1
  fi
  release_target_args=(--verify-tag)
fi

gh release create "${release_tag}" \
  "${manifest_path}#release-manifest.json" \
  "${whats_new_path}#whats-new.txt" \
  --repo "${repository}" \
  "${release_target_args[@]}" \
  --title "${release_tag}" \
  --notes-file "${github_notes}" \
  --draft

echo "Prepared ${release_tag} as a draft tied to App Store build ${build_number}."
