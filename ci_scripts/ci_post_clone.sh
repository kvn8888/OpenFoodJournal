#!/usr/bin/env bash
set -euo pipefail

if [[ "${CI_WORKFLOW:-}" == 'Siri AI Preview Verification' &&
      "${CI_XCODEBUILD_ACTION:-}" != archive ]]; then
    "$CI_PRIMARY_REPOSITORY_PATH/ci/verify-siri-ai-preview.sh"
fi
