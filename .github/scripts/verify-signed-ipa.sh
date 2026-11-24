#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 5 ]]; then
  echo "Usage: verify-signed-ipa.sh IPA_PATH EXPECTED_BUNDLE_ID EXPECTED_TEAM_ID EXPECTED_CLOUDKIT_CONTAINER EXPECTED_DISPLAY_NAME" >&2
  exit 64
fi

ipa_path="$1"
expected_bundle_id="$2"
expected_team_id="$3"
expected_cloudkit_container="$4"
expected_display_name="$5"

if [[ ! -f "${ipa_path}" ]]; then
  echo "IPA file not found: ${ipa_path}" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "${work_dir}"' EXIT

unzip -q "${ipa_path}" -d "${work_dir}"
app_bundles=("${work_dir}"/Payload/*.app)
if [[ "${#app_bundles[@]}" -ne 1 || ! -d "${app_bundles[0]}" ]]; then
  echo "Expected exactly one .app bundle inside Payload/." >&2
  exit 1
fi
app_bundle="${app_bundles[0]}"

info_plist="${app_bundle}/Info.plist"
if [[ ! -f "${info_plist}" ]]; then
  echo "Missing Info.plist in ${app_bundle}." >&2
  exit 1
fi

actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${info_plist}")"
actual_display_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "${info_plist}")"

if [[ "${actual_bundle_id}" != "${expected_bundle_id}" ]]; then
  echo "IPA CFBundleIdentifier is ${actual_bundle_id}, expected ${expected_bundle_id}." >&2
  exit 1
fi

if [[ "${actual_display_name}" != "${expected_display_name}" ]]; then
  echo "IPA CFBundleDisplayName is ${actual_display_name}, expected ${expected_display_name}." >&2
  exit 1
fi

entitlements_plist="${work_dir}/entitlements.plist"
codesign -d --entitlements - --xml "${app_bundle}" > "${entitlements_plist}" 2>/dev/null
entitlements_json="$(plutil -convert json -o - "${entitlements_plist}")"

expected_app_id="${expected_team_id}.${expected_bundle_id}"
if ! jq -e \
  --arg app_id "${expected_app_id}" \
  --arg ck "${expected_cloudkit_container}" \
  '
    .["application-identifier"] == $app_id
    and .["com.apple.developer.icloud-container-identifiers"] == [$ck]
    and ((.["com.apple.developer.icloud-services"] // []) | index("CloudKit") != null)
    and .["com.apple.developer.healthkit"] == true
  ' <<< "${entitlements_json}" >/dev/null
then
  echo "Signed IPA entitlements failed isolation verification." >&2
  echo "Expected application-identifier=${expected_app_id}, cloudKit=${expected_cloudkit_container}" >&2
  echo "Actual entitlements: ${entitlements_json}" >&2
  exit 1
fi

embedded_profile="${app_bundle}/embedded.mobileprovision"
if [[ -f "${embedded_profile}" ]]; then
  profile_plist="${work_dir}/embedded-profile.plist"
  security cms -D -i "${embedded_profile}" > "${profile_plist}"
  profile_json="$(plutil -convert json -o - "${profile_plist}")"
  if ! jq -e \
    --arg app_id "${expected_app_id}" \
    --arg team_id "${expected_team_id}" \
    --arg ck "${expected_cloudkit_container}" \
    '
      .Entitlements["application-identifier"] == $app_id
      and (.TeamIdentifier | index($team_id) != null)
      and ((.Entitlements["com.apple.developer.icloud-container-identifiers"] // []) | index($ck) != null)
    ' <<< "${profile_json}" >/dev/null
  then
    echo "Embedded provisioning profile failed isolation verification." >&2
    exit 1
  fi
fi

echo "Verified signed IPA: ${actual_bundle_id} (${actual_display_name}) -> ${expected_cloudkit_container}."
