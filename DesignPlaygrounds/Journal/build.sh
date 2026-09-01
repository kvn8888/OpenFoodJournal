#!/bin/bash
# Builds this tiny Mac app only. No package installs, iOS targets, or simulators.
set -euo pipefail
PLAYGROUND_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Volumes/DevDisk/Xcode-beta.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Volumes/DevDisk/Xcode-beta.app/Contents/Developer
fi
case "${1:-build}" in
    prepare|build|run) ;;
    *) echo "Usage: bash build.sh [prepare|build|run]" >&2; exit 2 ;;
esac
# Derived Data is a per-user workspace preference. The shared template alone
# is ignored by Xcode 27; configure only THIS disposable project's user prefs.
PLAYGROUND_PREFS_DIR="$PLAYGROUND_DIR/JournalPlayground.xcodeproj/project.xcworkspace/xcuserdata/$(id -un).xcuserdatad"
PLAYGROUND_PREFS="$PLAYGROUND_PREFS_DIR/WorkspaceSettings.xcsettings"
mkdir -p "$PLAYGROUND_PREFS_DIR"
if [[ ! -f "$PLAYGROUND_PREFS" ]]; then
    cp "$PLAYGROUND_DIR/JournalPlayground.xcodeproj/project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings" "$PLAYGROUND_PREFS"
fi
/usr/bin/plutil -replace DerivedDataLocationStyle -string AbsolutePath "$PLAYGROUND_PREFS"
/usr/bin/plutil -replace DerivedDataCustomLocation -string "$PLAYGROUND_DIR/.build/DerivedData" "$PLAYGROUND_PREFS"
if [[ "${1:-build}" == prepare ]]; then
    echo "Xcode preview cache configured: $PLAYGROUND_DIR/.build/DerivedData"
    exit 0
fi
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
