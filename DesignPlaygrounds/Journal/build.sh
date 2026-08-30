#!/bin/bash
# Builds this tiny Mac app only. No package installs, iOS targets, or simulators.
set -euo pipefail
PLAYGROUND_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Volumes/DevDisk/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Volumes/DevDisk/Xcode-beta.app/Contents/Developer
fi
case "${1:-build}" in
    build|run) ;;
    *) echo "Usage: bash build.sh [build|run]" >&2; exit 2 ;;
esac
xcodebuild \
    -project "$PLAYGROUND_DIR/JournalPlayground.xcodeproj" \
    -scheme JournalPlayground \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$PLAYGROUND_DIR/.build/DerivedData" \
    -clonedSourcePackagesDirPath "$PLAYGROUND_DIR/.build/SourcePackages" \
    build
if [[ "${1:-build}" == run ]]; then
    open "$PLAYGROUND_DIR/.build/DerivedData/Build/Products/Debug/JournalPlayground.app"
fi
