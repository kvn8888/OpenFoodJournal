#!/bin/bash

set -euo pipefail

project="OpenFoodJournal.xcodeproj"
scheme="OpenFoodJournal"

build_settings() {
  xcodebuild \
    -project "${project}" \
    -scheme "${scheme}" \
    -configuration "$1" \
    -destination generic/platform=iOS \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    -showBuildSettings
}

setting_value() {
  awk -F ' = ' -v key="$2" '$1 ~ "^[[:space:]]*" key "$" { print $2; exit }' <<< "$1"
}

assert_setting() {
  local settings="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(setting_value "${settings}" "${key}")"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Expected ${key}=${expected}, got ${actual:-<missing>}." >&2
    exit 1
  fi
}

assert_flag_present() {
  local settings="$1"
  local key="$2"
  local flag="$3"
  local actual
  actual="$(setting_value "${settings}" "${key}")"
  if [[ " ${actual} " != *" ${flag} "* ]]; then
    echo "Expected ${key} to contain ${flag}, got '${actual:-<missing>}'." >&2
    exit 1
  fi
}

assert_flag_absent() {
  local settings="$1"
  local key="$2"
  local flag="$3"
  local actual
  actual="$(setting_value "${settings}" "${key}")"
  if [[ " ${actual} " == *" ${flag} "* ]]; then
    echo "Expected ${key} not to contain ${flag}, got '${actual}'." >&2
    exit 1
  fi
}

debug_settings="$(build_settings Debug)"
preview_settings="$(build_settings Preview)"
release_settings="$(build_settings Release)"

# Debug (OFJ Dev — local Xcode sandbox)
assert_setting "${debug_settings}" PRODUCT_BUNDLE_IDENTIFIER k3vnc.OpenFoodJournal.dev
assert_setting "${debug_settings}" CODE_SIGN_ENTITLEMENTS OpenFoodJournal/OpenFoodJournal-Debug.entitlements
assert_setting "${debug_settings}" APP_DISPLAY_NAME "OFJ Dev"
assert_setting "${debug_settings}" ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
assert_setting "${debug_settings}" CURRENT_PROJECT_VERSION 0
assert_flag_present "${debug_settings}" SWIFT_ACTIVE_COMPILATION_CONDITIONS DEBUG
assert_flag_absent "${debug_settings}" SWIFT_ACTIVE_COMPILATION_CONDITIONS PREVIEW

# Preview (OFJ Preview — pre-prod UAT via TestFlight)
assert_setting "${preview_settings}" PRODUCT_BUNDLE_IDENTIFIER k3vnc.OpenFoodJournal.preview
assert_setting "${preview_settings}" CODE_SIGN_ENTITLEMENTS OpenFoodJournal/OpenFoodJournal-Preview.entitlements
assert_setting "${preview_settings}" APP_DISPLAY_NAME "OFJ Preview"
assert_setting "${preview_settings}" ASSETCATALOG_COMPILER_APPICON_NAME AppIconPreview
assert_setting "${preview_settings}" CURRENT_PROJECT_VERSION 0
assert_flag_present "${preview_settings}" SWIFT_ACTIVE_COMPILATION_CONDITIONS PREVIEW
assert_flag_absent "${preview_settings}" SWIFT_ACTIVE_COMPILATION_CONDITIONS DEBUG

# Release (OpenFoodJournal — App Store production)
assert_setting "${release_settings}" PRODUCT_BUNDLE_IDENTIFIER k3vnc.OpenFoodJournal
assert_setting "${release_settings}" CODE_SIGN_ENTITLEMENTS OpenFoodJournal/OpenFoodJournal.entitlements
assert_setting "${release_settings}" APP_DISPLAY_NAME OpenFoodJournal
assert_setting "${release_settings}" ASSETCATALOG_COMPILER_APPICON_NAME AppIcon
assert_flag_absent "${release_settings}" SWIFT_ACTIVE_COMPILATION_CONDITIONS DEBUG
assert_flag_absent "${release_settings}" SWIFT_ACTIVE_COMPILATION_CONDITIONS PREVIEW

# Keep MARKETING_VERSION synchronized across all configurations.
debug_version="$(setting_value "${debug_settings}" MARKETING_VERSION)"
preview_version="$(setting_value "${preview_settings}" MARKETING_VERSION)"
release_version="$(setting_value "${release_settings}" MARKETING_VERSION)"
if [[ "${debug_version}" != "${release_version}" || "${preview_version}" != "${release_version}" ]]; then
  echo "MARKETING_VERSION mismatch across configurations: Debug=${debug_version}, Preview=${preview_version}, Release=${release_version}." >&2
  exit 1
fi

debug_entitlements="$(plutil -convert json -o - OpenFoodJournal/OpenFoodJournal-Debug.entitlements)"
preview_entitlements="$(plutil -convert json -o - OpenFoodJournal/OpenFoodJournal-Preview.entitlements)"
release_entitlements="$(plutil -convert json -o - OpenFoodJournal/OpenFoodJournal.entitlements)"

jq -e '
  (keys | sort) == [
    "aps-environment",
    "com.apple.developer.icloud-container-identifiers",
    "com.apple.developer.icloud-services"
  ]
  and .["aps-environment"] == "development"
  and .["com.apple.developer.icloud-container-identifiers"] == ["iCloud.k3vnc.OpenFoodJournal.dev"]
  and .["com.apple.developer.icloud-services"] == ["CloudKit"]
' <<< "${debug_entitlements}" >/dev/null

jq -e '
  .["com.apple.developer.icloud-container-identifiers"] == ["iCloud.k3vnc.OpenFoodJournal.preview"]
  and .["com.apple.developer.icloud-services"] == ["CloudKit"]
  and .["com.apple.developer.healthkit"] == true
' <<< "${preview_entitlements}" >/dev/null

jq -e '
  .["com.apple.developer.icloud-container-identifiers"] == ["iCloud.k3vnc.OpenFoodJournal"]
  and .["com.apple.developer.icloud-services"] == ["CloudKit"]
  and .["com.apple.developer.healthkit"] == true
' <<< "${release_entitlements}" >/dev/null

if grep -Eq 'iCloud\.k3vnc\.OpenFoodJournal\.(dev|preview)' OpenFoodJournal/OpenFoodJournal.entitlements; then
  echo "Release entitlements unexpectedly reference a non-production CloudKit container." >&2
  exit 1
fi

if grep -Fq '"iCloud.k3vnc.OpenFoodJournal"' <<< "${preview_entitlements}" || grep -Fq 'iCloud.k3vnc.OpenFoodJournal.dev' OpenFoodJournal/OpenFoodJournal-Preview.entitlements; then
  echo "Preview entitlements unexpectedly reference the production or dev CloudKit container." >&2
  exit 1
fi

# Verify ci/release-config.json maintains strict Preview vs Production separation.
jq -e '
  .bundleIdentifier == "k3vnc.OpenFoodJournal"
  and .cloudKitContainerIdentifier == "iCloud.k3vnc.OpenFoodJournal"
  and .preview.bundleIdentifier == "k3vnc.OpenFoodJournal.preview"
  and .preview.cloudKitContainerIdentifier == "iCloud.k3vnc.OpenFoodJournal.preview"
  and .preview.xcodeConfiguration == "Preview"
  and .preview.bundleIdentifier != .bundleIdentifier
  and .preview.cloudKitContainerIdentifier != .cloudKitContainerIdentifier
  and .preview.tagPrefix != .releaseCandidateTagPrefix
  and ((.preview.appStoreAppID == "") or (.preview.appStoreAppID != .appStoreAppID))
' ci/release-config.json >/dev/null

echo "Debug, Preview, and Release isolation contracts passed."
