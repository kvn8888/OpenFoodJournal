#!/bin/bash
# Read/compare/export a design without overwriting the working file.
set -euo pipefail
PLAYGROUND_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$PLAYGROUND_DIR" rev-parse --show-toplevel)"
case "${1:-journal}" in
    journal) design=journal; file=JournalDesign.swift ;;
    nutrition) design=nutrition; file=NutritionDesign.swift ;;
    history) design=history; file=HistoryDesign.swift ;;
    *) echo "First argument must be journal, nutrition or history." >&2; exit 2 ;;
esac
relative="DesignPlaygrounds/Journal/$file"
case "${2:-list}" in
    list) git -C "$REPO_ROOT" --no-pager log --all --follow --date=short --format='%h  %ad  %s' -- "$relative" ;;
    versions) git -C "$REPO_ROOT" tag --list "design/$design/*" ;;
    diff)
        revision="$(git -C "$REPO_ROOT" rev-parse --verify "${3:?Supply a commit or design tag}^{commit}")"
        git -C "$REPO_ROOT" --no-pager diff "$revision" -- "$relative"
        ;;
    export)
        revision="$(git -C "$REPO_ROOT" rev-parse --verify "${3:?Supply a commit or design tag}^{commit}")"
        git -C "$REPO_ROOT" cat-file -e "$revision:$relative"
        mkdir -p "$PLAYGROUND_DIR/.build/design-history"
        destination="$PLAYGROUND_DIR/.build/design-history/$design-${revision:0:12}.swift"
        # noclobber refuses to replace even an existing exported copy.
        (set -o noclobber; git -C "$REPO_ROOT" show "$revision:$relative" > "$destination")
        echo "$destination"
        ;;
    save)
        label="${3:?Supply a short label, e.g. neutral-pill-v1}"
        [[ "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]] || { echo "Use letters, digits, - or _ only." >&2; exit 2; }
        git -C "$REPO_ROOT" ls-files --error-unmatch "$relative" >/dev/null
        if ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$relative"; then
            echo "Commit $file first so the named checkpoint includes your edits. Nothing was changed." >&2
            exit 2
        fi
        git -C "$REPO_ROOT" tag -a "design/$design/$label" -m "$design design: $label" HEAD
        echo "Saved design/$design/$label locally. No push performed."
        ;;
    *) echo "Usage: bash history.sh [journal|nutrition|history] [list|versions|diff REF|export REF|save LABEL]" >&2; exit 2 ;;
esac
