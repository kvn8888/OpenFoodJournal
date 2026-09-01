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

debug_settings="$(build_settings Debug)"
release_settings="$(build_settings Release)"

assert_setting "${debug_settings}" PRODUCT_BUNDLE_IDENTIFIER k3vnc.OpenFoodJournal.dev
assert_setting "${debug_settings}" CODE_SIGN_ENTITLEMENTS OpenFoodJournal/OpenFoodJournal-Debug.entitlements
assert_setting "${debug_settings}" APP_DISPLAY_NAME "OFJ Dev"
assert_setting "${debug_settings}" CURRENT_PROJECT_VERSION 0

assert_setting "${release_settings}" PRODUCT_BUNDLE_IDENTIFIER k3vnc.OpenFoodJournal
assert_setting "${release_settings}" CODE_SIGN_ENTITLEMENTS OpenFoodJournal/OpenFoodJournal.entitlements
assert_setting "${release_settings}" APP_DISPLAY_NAME OpenFoodJournal

debug_entitlements="$(plutil -convert json -o - OpenFoodJournal/OpenFoodJournal-Debug.entitlements)"
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
  .["com.apple.developer.icloud-container-identifiers"] == ["iCloud.k3vnc.OpenFoodJournal"]
  and .["com.apple.developer.icloud-services"] == ["CloudKit"]
  and .["com.apple.developer.healthkit"] == true
' <<< "${release_entitlements}" >/dev/null

if grep -Fq 'iCloud.k3vnc.OpenFoodJournal.dev' OpenFoodJournal/OpenFoodJournal.entitlements; then
  echo "Release entitlements unexpectedly reference the development CloudKit container." >&2
  exit 1
fi

echo "Debug and Release isolation contracts passed."
