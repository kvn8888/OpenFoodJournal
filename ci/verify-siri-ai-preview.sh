#!/usr/bin/env bash
set -euo pipefail

sdk_version="$(xcrun --sdk iphoneos --show-sdk-version)"
if [[ ! "$sdk_version" =~ ^([0-9]+)\.([0-9]+) ]] ||
    (( BASH_REMATCH[1] < 27 || (BASH_REMATCH[1] == 27 && BASH_REMATCH[2] < 3) )); then
    printf 'Siri AI preview requires Xcode with the iOS 27.3 SDK or newer. Found %s.\n' "$sdk_version" >&2
    exit 1
fi

if [[ "${1:-}" == --app ]]; then
    app="${2:?Provide the path to OpenFoodJournal.app}"
else
    project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    derived_data="${1:-$(mktemp -d "${TMPDIR:-/tmp}/ofj-siri-ai-preview.XXXXXX")}"

    xcodebuild \
        -project "$project_dir/OpenFoodJournal.xcodeproj" \
        -scheme OpenFoodJournalSiriAIPreview \
        -configuration SiriAIPreview \
        -destination generic/platform=iOS \
        -derivedDataPath "$derived_data" \
        CODE_SIGNING_ALLOWED=NO \
        build

    app="$derived_data/Build/Products/SiriAIPreview-iphoneos/OpenFoodJournal.app"
fi

minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")"
if [[ "$minimum_os" != 27.3 ]]; then
    printf 'Expected the Siri AI preview to require iOS 27.3, found %s.\n' "$minimum_os" >&2
    exit 1
fi

if ! report="$(xcrun sirimetadataanalyzer "$app" 2>&1)"; then
    printf '%s\n' "$report" >&2
    exit 1
fi
printf '%s\n' "$report"
if ! grep -Eq '\([1-9][0-9]* tools?\)' <<< "$report"; then
    printf 'The Siri AI preview metadata contains no tool intents.\n' >&2
    exit 1
fi
