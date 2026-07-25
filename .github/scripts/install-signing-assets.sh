#!/bin/bash

set -euo pipefail

: "${APPLE_DISTRIBUTION_CERTIFICATE_B64:?Missing APPLE_DISTRIBUTION_CERTIFICATE_B64}"
: "${APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD:?Missing APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD}"
: "${APPLE_PROVISIONING_PROFILE_B64:?Missing APPLE_PROVISIONING_PROFILE_B64}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required on the hosted runner}"
: "${GITHUB_ENV:?GITHUB_ENV is required on GitHub Actions}"

signing_root="${RUNNER_TEMP}/openfoodjournal-signing"
certificate_path="${signing_root}/distribution.p12"
profile_path="${signing_root}/distribution.mobileprovision"
profile_plist="${signing_root}/distribution.plist"
keychain_path="${signing_root}/build.keychain-db"
keychain_password="$(openssl rand -hex 32)"

mkdir -p "${signing_root}"
printf '%s' "${APPLE_DISTRIBUTION_CERTIFICATE_B64}" | /usr/bin/base64 -D > "${certificate_path}"
printf '%s' "${APPLE_PROVISIONING_PROFILE_B64}" | /usr/bin/base64 -D > "${profile_path}"

security create-keychain -p "${keychain_password}" "${keychain_path}"
security set-keychain-settings -lut 21600 "${keychain_path}"
security unlock-keychain -p "${keychain_password}" "${keychain_path}"
security import "${certificate_path}" \
  -P "${APPLE_DISTRIBUTION_CERTIFICATE_PASSWORD}" \
  -A \
  -f pkcs12 \
  -k "${keychain_path}"
security set-key-partition-list \
  -S apple-tool:,apple:,codesign: \
  -s \
  -k "${keychain_password}" \
  "${keychain_path}"
security list-keychains -d user -s "${keychain_path}"

security cms -D -i "${profile_path}" > "${profile_plist}"
profile_uuid="$(/usr/libexec/PlistBuddy -c 'Print :UUID' "${profile_plist}")"
profile_name="$(/usr/libexec/PlistBuddy -c 'Print :Name' "${profile_plist}")"
runner_account="$(id -un)"
runner_home_dir="$(dscl . -read "/Users/${runner_account}" NFSHomeDirectory | awk '{print $2}')"
installed_profile_dir="${runner_home_dir}/Library/MobileDevice/Provisioning Profiles"
installed_profile_path="${installed_profile_dir}/${profile_uuid}.mobileprovision"

mkdir -p "${installed_profile_dir}"
cp "${profile_path}" "${installed_profile_path}"

printf 'OFJ_PROFILE_NAME=%s\n' "${profile_name}" >> "${GITHUB_ENV}"
printf 'OFJ_KEYCHAIN_PATH=%s\n' "${keychain_path}" >> "${GITHUB_ENV}"
echo "Installed distribution signing assets for profile ${profile_name}."
