#!/usr/bin/env bash
set -euo pipefail

if [[ "${CI_WORKFLOW:-}" == 'Siri AI Preview Verification' ]]; then
    "$CI_PRIMARY_REPOSITORY_PATH/ci/verify-siri-ai-preview.sh"
fi
