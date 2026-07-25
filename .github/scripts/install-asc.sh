#!/bin/bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repository_root="$(cd "${script_dir}/../.." && pwd)"
config_path="${repository_root}/ci/release-config.json"

asc_version="$(jq -r '.ascVersion' "${config_path}")"
machine_arch="$(uname -m)"

case "${machine_arch}" in
  arm64)
    release_arch="macOS_arm64"
    ;;
  x86_64)
    release_arch="macOS_amd64"
    ;;
  *)
    echo "Unsupported macOS runner architecture: ${machine_arch}" >&2
    exit 1
    ;;
esac

expected_sha="$(jq -r --arg arch "${machine_arch}" '.ascSHA256[$arch]' "${config_path}")"
if [[ -z "${expected_sha}" || "${expected_sha}" == "null" ]]; then
  echo "No pinned asc checksum for ${machine_arch}." >&2
  exit 1
fi

tool_root="${RUNNER_TEMP:-/private/tmp}/openfoodjournal-tools"
asc_path="${tool_root}/asc"
download_url="https://github.com/rorkai/App-Store-Connect-CLI/releases/download/${asc_version}/asc_${asc_version}_${release_arch}"

mkdir -p "${tool_root}"
curl \
  --fail \
  --location \
  --proto '=https' \
  --retry 3 \
  --show-error \
  --silent \
  --tlsv1.2 \
  "${download_url}" \
  --output "${asc_path}"

actual_sha="$(shasum -a 256 "${asc_path}" | awk '{print $1}')"
if [[ "${actual_sha}" != "${expected_sha}" ]]; then
  echo "asc checksum mismatch. Expected ${expected_sha}; received ${actual_sha}." >&2
  exit 1
fi

chmod +x "${asc_path}"
"${asc_path}" --version

if [[ -n "${GITHUB_PATH:-}" ]]; then
  printf '%s\n' "${tool_root}" >> "${GITHUB_PATH}"
else
  printf '%s\n' "${tool_root}"
fi
