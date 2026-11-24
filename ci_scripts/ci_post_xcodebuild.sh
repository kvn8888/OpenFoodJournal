#!/usr/bin/env bash
set -euo pipefail

if [[ "${CI_XCODE_SCHEME:-}" == OpenFoodJournalSiriAIPreview &&
      "${CI_XCODEBUILD_ACTION:-}" == archive &&
      "${CI_XCODEBUILD_EXIT_CODE:-}" == 0 ]]; then
    "${CI_PRIMARY_REPOSITORY_PATH}/ci/verify-siri-ai-preview.sh" --app "${CI_ARCHIVE_PATH}/Products/Applications/OpenFoodJournal.app"
fi
