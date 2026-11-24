#!/usr/bin/env bash
set -euo pipefail

sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ ! "$sdk_version" =~ ^([0-9]+)\.([0-9]+) ]] ||
    (( BASH_REMATCH[1] < 27 || (BASH_REMATCH[1] == 27 && BASH_REMATCH[2] < 3) )); then
    printf 'Siri AI preview requires Xcode with the iOS 27.3 SDK or newer. Found %s.\n' "$sdk_version" >&2
    exit 1
fi

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="${1:-$(mktemp -d "${TMPDIR:-/tmp}/ofj-siri-ai-preview.XXXXXX")}"

xcodebuild \
    -project "$project_dir/OpenFoodJournal.xcodeproj" \
    -scheme OpenFoodJournal \
    -destination generic/platform=iOS \
    -derivedDataPath "$derived_data" \
    IPHONEOS_DEPLOYMENT_TARGET=27.3 \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) OFJ_SIRI_AI_PREVIEW' \
    CODE_SIGNING_ALLOWED=NO \
    build-for-testing

xcrun sirimetadataanalyzer "$derived_data/Build/Products/Debug-iphoneos/OpenFoodJournal.app"
