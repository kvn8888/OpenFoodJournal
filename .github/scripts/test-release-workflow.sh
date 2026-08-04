#!/bin/bash

set -euo pipefail

fixture_root="$(mktemp -d)"
trap 'rm -rf "${fixture_root}"' EXIT

release_runner="$(jq -r '.xcodeRunner' ci/release-config.json)"
required_xcode_version="$(jq -r '.requiredXcodeVersion' ci/release-config.json)"
required_xcode_build="$(jq -r '.requiredXcodeBuild' ci/release-config.json)"
xcode_app_version="${required_xcode_version#Xcode }"
developer_dir="/Applications/Xcode_${xcode_app_version}.app/Contents/Developer"

for workflow in \
  .github/workflows/cloud-ci.yml \
  .github/workflows/testflight.yml \
  .github/workflows/app-store.yml \
  .github/workflows/release-credentials-check.yml
do
  if ! grep -Fq "runs-on: ${release_runner}" "${workflow}"; then
    echo "${workflow} does not use the configured release runner ${release_runner}." >&2
    exit 1
  fi
done

for workflow in \
  .github/workflows/cloud-ci.yml \
  .github/workflows/testflight.yml \
  .github/workflows/app-store.yml
do
  if ! grep -Fq "DEVELOPER_DIR: ${developer_dir}" "${workflow}"; then
    echo "${workflow} does not select configured ${required_xcode_version} (${required_xcode_build})." >&2
    exit 1
  fi
done

if ! grep -Fq 'gemini-image-contract:' .github/workflows/testflight.yml; then
  echo "TestFlight workflow is missing the protected Gemini image contract job." >&2
  exit 1
fi
if ! grep -Fq 'testGeminiFoodIconImageLiveContract' .github/workflows/testflight.yml; then
  echo "TestFlight workflow does not execute the production Gemini image contract test." >&2
  exit 1
fi
if ! grep -Fq 'OFJ_GEMINI_API_KEY: ${{ secrets.OFJ_GEMINI_API_KEY }}' .github/workflows/testflight.yml; then
  echo "TestFlight workflow does not source the Gemini canary key from the protected environment." >&2
  exit 1
fi

valid_notes="${fixture_root}/valid-notes.txt"
empty_notes="${fixture_root}/empty-notes.txt"
long_notes="${fixture_root}/long-notes.txt"
printf '%s\n' '• Better nutrition-history reliability.' > "${valid_notes}"
: > "${empty_notes}"
awk 'BEGIN { for (i = 0; i < 4001; i++) printf "a" }' > "${long_notes}"

bash .github/scripts/validate-release-notes.sh "${valid_notes}" en-US >/dev/null
if bash .github/scripts/validate-release-notes.sh "${empty_notes}" en-US >/dev/null 2>&1; then
  echo "Empty release notes unexpectedly passed validation." >&2
  exit 1
fi
if bash .github/scripts/validate-release-notes.sh "${long_notes}" en-US >/dev/null 2>&1; then
  echo "Oversized release notes unexpectedly passed validation." >&2
  exit 1
fi
if bash .github/scripts/validate-release-notes.sh "${valid_notes}" invalid_locale >/dev/null 2>&1; then
  echo "Invalid locale unexpectedly passed validation." >&2
  exit 1
fi

what_to_test="${fixture_root}/what-to-test.txt"
generated_notes="${fixture_root}/generated-notes.txt"
generated_metadata="${fixture_root}/generated-metadata.json"
printf '%s\n' '- fix: repair dietary-energy reconciliation' > "${what_to_test}"
env -u GH_TOKEN RUNNER_TEMP="${fixture_root}" \
  bash .github/scripts/generate-release-notes.sh \
  1.4 \
  11 \
  en-US \
  "${what_to_test}" \
  "${generated_notes}" \
  "${generated_metadata}" \
  openai/gpt-4.1 >/dev/null
grep -q 'repair dietary-energy reconciliation' "${generated_notes}"
if grep -q 'fix:' "${generated_notes}"; then
  echo "Deterministic public notes leaked a conventional-commit prefix." >&2
  exit 1
fi
test "$(jq -r '.source' "${generated_metadata}")" = "deterministic-git-history"
test "$(jq -r '.requiresHumanApproval' "${generated_metadata}")" = "true"

promotion_repo="${fixture_root}/promotion-repo"
mkdir -p \
  "${promotion_repo}/.github/scripts" \
  "${promotion_repo}/OpenFoodJournal" \
  "${promotion_repo}/OpenFoodJournal.xcodeproj" \
  "${promotion_repo}/ci"
cp .github/scripts/validate-release-notes.sh "${promotion_repo}/.github/scripts/"
cp .github/scripts/verify-promotion.sh "${promotion_repo}/.github/scripts/"
printf '%s\n' '{"appStoreAppID":"6761086648"}' > "${promotion_repo}/ci/release-config.json"
printf '%s\n' 'fixture' > "${promotion_repo}/OpenFoodJournal/App.swift"
printf '%s\n' 'fixture' > "${promotion_repo}/OpenFoodJournal.xcodeproj/project.pbxproj"

git -C "${promotion_repo}" init -q
git -C "${promotion_repo}" config user.name "Release Contract"
git -C "${promotion_repo}" config user.email "release-contract@example.invalid"
git -C "${promotion_repo}" add .
git -C "${promotion_repo}" commit -qm "fixture"
git -C "${promotion_repo}" tag testflight/1.4-11

fixture_commit="$(git -C "${promotion_repo}" rev-parse HEAD)"
fixture_whats_new="${promotion_repo}/whats-new.txt"
printf '%s\n' '• Health data now matches the journal.' > "${fixture_whats_new}"
fixture_notes_sha="$(shasum -a 256 "${fixture_whats_new}" | awk '{print $1}')"
fixture_manifest="${promotion_repo}/release-manifest.json"
jq -n \
  --arg commitSHA "${fixture_commit}" \
  --arg whatsNewSHA256 "${fixture_notes_sha}" \
  '{
    schemaVersion: 2,
    appStoreAppID: "6761086648",
    buildID: "build-id",
    buildNumber: "11",
    version: "1.4",
    ipaSHA256: "ipa-sha",
    primaryLocale: "en-US",
    whatsNew: "• Health data now matches the journal.",
    whatsNewSHA256: $whatsNewSHA256,
    whatToTest: "Verify Health data reconciliation.",
    commitSHA: $commitSHA,
    releaseNotes: {
      source: "github-models",
      requiresHumanApproval: true
    }
  }' > "${fixture_manifest}"

(
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    testflight/1.4-11 \
    "${fixture_manifest}" \
    "${fixture_whats_new}" >/dev/null
)

jq '.schemaVersion = 1' "${fixture_manifest}" > "${fixture_manifest}.invalid"
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    testflight/1.4-11 \
    "${fixture_manifest}.invalid" \
    "${fixture_whats_new}" >/dev/null 2>&1
); then
  echo "Legacy manifest schema unexpectedly passed promotion verification." >&2
  exit 1
fi

echo "Release workflow contract tests passed."
