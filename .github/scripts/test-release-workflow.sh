#!/bin/bash

set -euo pipefail

fixture_root="$(mktemp -d)"
trap 'rm -rf "${fixture_root}"' EXIT

expected_checkout_ref="actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
while IFS= read -r checkout_ref; do
  if [[ "${checkout_ref}" != "${expected_checkout_ref}" ]]; then
    echo "Unexpected actions/checkout pin: ${checkout_ref}" >&2
    exit 1
  fi
done < <(grep -Rho 'actions/checkout@[^ ]*' .github/workflows)

if [[ ! -f .github/workflows/testflight-external.yml ]]; then
  echo "External TestFlight promotion workflow is missing." >&2
  exit 1
fi
for required_text in \
  'environment: app-store-production' \
  'verify-external-testflight.sh' \
  'asc builds add-groups' \
  '--submit' \
  'confirm_external_promotion'; do
  if ! grep -Fq -- "${required_text}" .github/workflows/testflight-external.yml; then
    echo "External TestFlight workflow is missing contract: ${required_text}" >&2
    exit 1
  fi
done
internal_group_id="$(jq -r '.testFlightGroupID // empty' ci/release-config.json)"
external_group_id="$(jq -r '.externalTestFlightGroupID // empty' ci/release-config.json)"
if [[ -z "${external_group_id}" || "${external_group_id}" == "${internal_group_id}" ]]; then
  echo "External TestFlight group must exist and differ from the internal group." >&2
  exit 1
fi

release_runner="$(jq -r '.xcodeRunner' ci/release-config.json)"
required_xcode_version="$(jq -r '.requiredXcodeVersion' ci/release-config.json)"
required_xcode_build="$(jq -r '.requiredXcodeBuild' ci/release-config.json)"
xcode_app_version="${required_xcode_version#Xcode }"
developer_dir="/Applications/Xcode_${xcode_app_version}.app/Contents/Developer"

for workflow in \
  .github/workflows/cloud-ci.yml \
  .github/workflows/testflight.yml \
  .github/workflows/app-store.yml \
  .github/workflows/testflight-external.yml \
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

for required in \
  'TEST_RUNNER_OFJ_RUN_LIVE_GEMINI_IMAGE_TESTS: "1"' \
  'TEST_RUNNER_OFJ_GEMINI_API_KEY: ${{ secrets.OFJ_GEMINI_API_KEY }}' \
  'bash .github/scripts/verify-live-test-log.sh'
do
  if ! grep -Fq "$required" .github/workflows/testflight.yml; then
    echo "TestFlight live-test forwarding/result gate is missing: $required" >&2
    exit 1
  fi
done
bash .github/scripts/test-live-test-log.sh
if grep -Fq 'path: ${{ runner.temp }}/GeminiFoodImageContract.xcresult' .github/workflows/testflight.yml; then
  echo "Protected live-test results must not be uploaded with forwarded credentials." >&2
  exit 1
fi

if grep -Fq -- '--exclude-fields' .github/workflows/app-store.yml; then
  echo "App Store staging must copy a complete localization before its readiness check." >&2
  exit 1
fi
stage_line="$(grep -n 'asc release stage' .github/workflows/app-store.yml | head -n 1 | cut -d: -f1)"
metadata_line="$(grep -n 'asc metadata push' .github/workflows/app-store.yml | head -n 1 | cut -d: -f1)"
strict_line="$(grep -n 'asc validate' .github/workflows/app-store.yml | head -n 1 | cut -d: -f1)"
if [[ -z "${stage_line}" || -z "${metadata_line}" || -z "${strict_line}" ]] ||
  (( stage_line >= metadata_line || metadata_line >= strict_line )); then
  echo "App Store workflow must stage, apply reviewed metadata, then validate strictly." >&2
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
env -u GH_TOKEN -u BIFROST_BASE_URL -u BIFROST_VIRTUAL_KEY -u BIFROST_AUTHORIZATION \
  RUNNER_TEMP="${fixture_root}" \
  bash .github/scripts/generate-release-notes.sh \
  1.4 \
  11 \
  en-US \
  "${what_to_test}" \
  "${generated_notes}" \
  "${generated_metadata}" \
  openai/gpt-5.6-sol >/dev/null
grep -q 'repair dietary-energy reconciliation' "${generated_notes}"
if grep -q 'fix:' "${generated_notes}"; then
  echo "Deterministic public notes leaked a conventional-commit prefix." >&2
  exit 1
fi
test "$(jq -r '.source' "${generated_metadata}")" = "deterministic-git-history"
test "$(jq -r '.requiresHumanApproval' "${generated_metadata}")" = "true"

# The prompt lives outside the script; a rename or a lost placeholder would
# otherwise only surface as silently degraded notes during a real release.
for prompt_file in ci/prompts/whats-new-system.txt ci/prompts/whats-new-user.txt; do
  if [[ ! -s "${prompt_file}" ]]; then
    echo "Missing or empty release-note prompt: ${prompt_file}" >&2
    exit 1
  fi
done
for placeholder in '{{VERSION}}' '{{EVIDENCE}}'; do
  if ! grep -qF "${placeholder}" ci/prompts/whats-new-user.txt; then
    echo "Release-note prompt lost the ${placeholder} placeholder." >&2
    exit 1
  fi
done
if ! grep -qE '^\{\{EVIDENCE\}\}$' ci/prompts/whats-new-user.txt; then
  echo "{{EVIDENCE}} must sit alone on its own line for substitution to work." >&2
  exit 1
fi

# The router applies no cross-provider routing of its own, so the configured
# fallback chain is the only thing standing between one provider outage and
# changelog-style release notes.
notes_model="$(jq -r '.releaseNotesModel' ci/release-config.json)"
if ! jq -e '.releaseNotesFallbackModels | type == "array" and length > 0' \
  ci/release-config.json >/dev/null; then
  echo "ci/release-config.json must list at least one release-note fallback model." >&2
  exit 1
fi
if ! jq -e --arg model "${notes_model}" \
  '.releaseNotesFallbackModels | all(. != $model)' \
  ci/release-config.json >/dev/null; then
  echo "The primary release-note model must not appear in its own fallback chain." >&2
  exit 1
fi
# Models must stay unprefixed so the router keeps choosing the provider. A
# "provider/model" name silently pins the release to one upstream.
if jq -e '[.releaseNotesModel] + .releaseNotesFallbackModels | any(test("/"))' \
  ci/release-config.json >/dev/null; then
  echo "Release-note models must be unprefixed so the router selects the provider." >&2
  exit 1
fi

promotion_repo="${fixture_root}/promotion-repo"
mkdir -p \
  "${promotion_repo}/.github/scripts" \
  "${promotion_repo}/OpenFoodJournal" \
  "${promotion_repo}/OpenFoodJournal.xcodeproj" \
  "${promotion_repo}/ci"
cp .github/scripts/validate-release-notes.sh "${promotion_repo}/.github/scripts/"
cp .github/scripts/verify-promotion.sh "${promotion_repo}/.github/scripts/"
cp .github/scripts/verify-external-testflight.sh "${promotion_repo}/.github/scripts/"
cp .github/scripts/prepare-github-app-store-release.sh "${promotion_repo}/.github/scripts/"
cp .github/scripts/verify-public-release-candidate.sh "${promotion_repo}/.github/scripts/"
printf '%s\n' \
  '{"appStoreAppID":"6761086648","publicReleaseTagPrefix":"v","testFlightTagPrefix":"testflight/","testFlightGroupID":"internal-group","externalTestFlightGroupID":"external-group"}' \
  > "${promotion_repo}/ci/release-config.json"
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

fake_bin="${fixture_root}/fake-bin"
fake_gh_capture="${fixture_root}/gh-release-create.args"
mkdir -p "${fake_bin}"
printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'if [[ "$1" == "api" ]]; then' \
  '  printf "%s\n" "[]"' \
  'elif [[ "$1" == "release" && "$2" == "create" ]]; then' \
  '  printf "%s\n" "$@" > "${GH_CAPTURE:?}"' \
  'else' \
  '  echo "Unexpected fake gh command: $*" >&2' \
  '  exit 1' \
  'fi' \
  > "${fake_bin}/gh"
chmod +x "${fake_bin}/gh"

(
  cd "${promotion_repo}"
  PATH="${fake_bin}:${PATH}" \
    GH_CAPTURE="${fake_gh_capture}" \
    GITHUB_REPOSITORY="kvn8888/OpenFoodJournal" \
    RUNNER_TEMP="${fixture_root}" \
    bash .github/scripts/prepare-github-app-store-release.sh \
      "${fixture_manifest}" \
      "${fixture_whats_new}" >/dev/null
)
grep -qx 'v1.4' "${fake_gh_capture}"
grep -qx -- '--draft' "${fake_gh_capture}"
grep -qx -- '--target' "${fake_gh_capture}"
grep -qx "${fixture_commit}" "${fake_gh_capture}"
grep -qx "${fixture_manifest}#release-manifest.json" "${fake_gh_capture}"
grep -qx "${fixture_whats_new}#whats-new.txt" "${fake_gh_capture}"

(
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    testflight/1.4-11 \
    "${fixture_manifest}" \
    "${fixture_whats_new}" >/dev/null
)

(
  cd "${promotion_repo}"
  bash .github/scripts/verify-external-testflight.sh \
    testflight/1.4-11 \
    "${fixture_manifest}" >/dev/null
)

jq '.externalTestFlightGroupID = .testFlightGroupID' \
  "${promotion_repo}/ci/release-config.json" \
  > "${promotion_repo}/ci/release-config.invalid.json"
mv "${promotion_repo}/ci/release-config.json" "${promotion_repo}/ci/release-config.valid.json"
mv "${promotion_repo}/ci/release-config.invalid.json" "${promotion_repo}/ci/release-config.json"
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-external-testflight.sh \
    testflight/1.4-11 \
    "${fixture_manifest}" >/dev/null 2>&1
); then
  echo "Internal group unexpectedly passed as the external TestFlight group." >&2
  exit 1
fi
mv "${promotion_repo}/ci/release-config.valid.json" "${promotion_repo}/ci/release-config.json"

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

fixture_release="${promotion_repo}/release.json"
jq -n \
  --arg commit "${fixture_commit}" \
  '{
    tag_name: "v1.4",
    name: "v1.4",
    draft: true,
    prerelease: false,
    target_commitish: $commit
  }' > "${fixture_release}"

(
  cd "${promotion_repo}"
  bash .github/scripts/verify-public-release-candidate.sh \
    1.4 \
    "${fixture_release}" \
    "${fixture_manifest}" \
    "${fixture_whats_new}" >/dev/null
)

jq '.tag_name = "v1.5"' "${fixture_release}" > "${fixture_release}.wrong-version"
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-public-release-candidate.sh \
    1.4 \
    "${fixture_release}.wrong-version" \
    "${fixture_manifest}" \
    "${fixture_whats_new}" >/dev/null 2>&1
); then
  echo "Mismatched public release version unexpectedly passed verification." >&2
  exit 1
fi

printf '%s\n' 'Tampered public notes.' > "${fixture_whats_new}.tampered"
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-public-release-candidate.sh \
    1.4 \
    "${fixture_release}" \
    "${fixture_manifest}" \
    "${fixture_whats_new}.tampered" >/dev/null 2>&1
); then
  echo "Tampered public release notes unexpectedly passed verification." >&2
  exit 1
fi

echo "Release workflow contract tests passed."
