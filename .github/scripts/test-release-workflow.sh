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

# Ensure Preview UAT and Production workflows both enforce signed IPA isolation.
for workflow in .github/workflows/testflight.yml .github/workflows/app-store.yml; do
  if ! grep -Fq "bash .github/scripts/verify-signed-ipa.sh" "${workflow}"; then
    echo "${workflow} does not invoke verify-signed-ipa.sh before upload." >&2
    exit 1
  fi
done

if ! grep -Fq -- '--configuration "${{ steps.preview_config.outputs.xcode_config }}"' .github/workflows/testflight.yml; then
  echo "testflight.yml must archive using the Preview configuration." >&2
  exit 1
fi
if grep -Fq -- '--submit' .github/workflows/testflight.yml; then
  echo "testflight.yml must remain internal-only for OFJ Preview and not submit to external Beta App Review." >&2
  exit 1
fi
if ! grep -Fq -- '--configuration Release' .github/workflows/app-store.yml; then
  echo "app-store.yml must archive production binaries using the Release configuration." >&2
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

# Verify ExportOptions.plist supports clean per-lane bundle ID injection.
export_fixture="${fixture_root}/ExportOptions.plist"
cp ci/ExportOptions.plist "${export_fixture}"
/usr/libexec/PlistBuddy \
  -c "Add :provisioningProfiles:k3vnc.OpenFoodJournal.preview string PreviewProfile" \
  "${export_fixture}"
/usr/libexec/PlistBuddy \
  -c "Set :signingCertificate iPhone Distribution" \
  "${export_fixture}"
plutil -lint "${export_fixture}" >/dev/null

# Verify schema-3 Preview UAT and Production RC promotion provenance contracts.
promotion_repo="${fixture_root}/promotion-repo"
mkdir -p \
  "${promotion_repo}/.github/scripts" \
  "${promotion_repo}/OpenFoodJournal" \
  "${promotion_repo}/OpenFoodJournal.xcodeproj" \
  "${promotion_repo}/ci"
cp .github/scripts/validate-release-notes.sh "${promotion_repo}/.github/scripts/"
cp .github/scripts/verify-promotion.sh "${promotion_repo}/.github/scripts/"
cat > "${promotion_repo}/ci/release-config.json" <<'EOF'
{
  "appStoreAppID": "6761086648",
  "bundleIdentifier": "k3vnc.OpenFoodJournal",
  "cloudKitContainerIdentifier": "iCloud.k3vnc.OpenFoodJournal",
  "preview": {
    "appStoreAppID": "9999999999",
    "bundleIdentifier": "k3vnc.OpenFoodJournal.preview",
    "cloudKitContainerIdentifier": "iCloud.k3vnc.OpenFoodJournal.preview",
    "xcodeConfiguration": "Preview"
  }
}
EOF
printf '%s\n' 'fixture' > "${promotion_repo}/OpenFoodJournal/App.swift"
printf '%s\n' 'fixture' > "${promotion_repo}/OpenFoodJournal.xcodeproj/project.pbxproj"

git -C "${promotion_repo}" init -q
git -C "${promotion_repo}" config user.name "Release Contract"
git -C "${promotion_repo}" config user.email "release-contract@example.invalid"
git -C "${promotion_repo}" add .
git -C "${promotion_repo}" commit -qm "fixture"
git -C "${promotion_repo}" tag preview/1.6-1
git -C "${promotion_repo}" tag release-rc/1.6-1

fixture_commit="$(git -C "${promotion_repo}" rev-parse HEAD)"
fixture_whats_new="${promotion_repo}/whats-new.txt"
printf '%s\n' '• Health data now matches the journal.' > "${fixture_whats_new}"
fixture_notes_sha="$(shasum -a 256 "${fixture_whats_new}" | awk '{print $1}')"

preview_manifest="${promotion_repo}/preview-manifest.json"
jq -n \
  --arg commitSHA "${fixture_commit}" \
  --arg whatsNewSHA256 "${fixture_notes_sha}" \
  '{
    schemaVersion: 3,
    manifestKind: "preview-uat",
    appStoreAppID: "9999999999",
    bundleIdentifier: "k3vnc.OpenFoodJournal.preview",
    cloudKitContainerIdentifier: "iCloud.k3vnc.OpenFoodJournal.preview",
    xcodeConfiguration: "Preview",
    buildID: "preview-build-id",
    buildNumber: "1",
    version: "1.6",
    ipaSHA256: "preview-ipa-sha",
    primaryLocale: "en-US",
    whatsNew: "• Health data now matches the journal.",
    whatsNewSHA256: $whatsNewSHA256,
    whatToTest: "Verify Health data reconciliation.",
    commitSHA: $commitSHA,
    releaseNotes: {
      source: "bifrost",
      requiresHumanApproval: true
    }
  }' > "${preview_manifest}"

prod_rc_manifest="${promotion_repo}/prod-rc-manifest.json"
jq -n \
  --arg commitSHA "${fixture_commit}" \
  --arg whatsNewSHA256 "${fixture_notes_sha}" \
  '{
    schemaVersion: 3,
    manifestKind: "production-rc",
    sourcePreviewTag: "preview/1.6-1",
    appStoreAppID: "6761086648",
    bundleIdentifier: "k3vnc.OpenFoodJournal",
    cloudKitContainerIdentifier: "iCloud.k3vnc.OpenFoodJournal",
    xcodeConfiguration: "Release",
    buildID: "prod-build-id",
    buildNumber: "1",
    version: "1.6",
    ipaSHA256: "prod-ipa-sha",
    primaryLocale: "en-US",
    whatsNew: "• Health data now matches the journal.",
    whatsNewSHA256: $whatsNewSHA256,
    whatToTest: "Verify Health data reconciliation.",
    commitSHA: $commitSHA,
    releaseNotes: {
      source: "bifrost",
      requiresHumanApproval: true
    }
  }' > "${prod_rc_manifest}"

(
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    --kind preview-uat \
    preview/1.6-1 \
    "${preview_manifest}" \
    "${fixture_whats_new}" >/dev/null
  bash .github/scripts/verify-promotion.sh \
    --kind production-rc \
    release-rc/1.6-1 \
    "${prod_rc_manifest}" \
    "${fixture_whats_new}" >/dev/null
)

# Reject cross-kind promotion (e.g., passing Preview manifest as production RC).
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    --kind production-rc \
    preview/1.6-1 \
    "${preview_manifest}" \
    "${fixture_whats_new}" >/dev/null 2>&1
); then
  echo "Preview manifest unexpectedly passed production-rc verification." >&2
  exit 1
fi

# Reject legacy schema-2 manifests.
jq '.schemaVersion = 2' "${preview_manifest}" > "${preview_manifest}.legacy"
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    --kind preview-uat \
    preview/1.6-1 \
    "${preview_manifest}.legacy" \
    "${fixture_whats_new}" >/dev/null 2>&1
); then
  echo "Legacy manifest schema unexpectedly passed promotion verification." >&2
  exit 1
fi

# Reject mismatched CloudKit container in manifest.
jq '.cloudKitContainerIdentifier = "iCloud.k3vnc.OpenFoodJournal"' "${preview_manifest}" > "${preview_manifest}.wrongck"
if (
  cd "${promotion_repo}"
  bash .github/scripts/verify-promotion.sh \
    --kind preview-uat \
    preview/1.6-1 \
    "${preview_manifest}.wrongck" \
    "${fixture_whats_new}" >/dev/null 2>&1
); then
  echo "Preview manifest targeting production CloudKit unexpectedly passed." >&2
  exit 1
fi

# Verify verify-signed-ipa.sh with a real ad-hoc signed .app fixture.
ipa_stage="${fixture_root}/ipa-fixture"
app_dir="${ipa_stage}/Payload/OFJPreview.app"
mkdir -p "${app_dir}"
cp /bin/echo "${app_dir}/OFJPreview"
cat > "${app_dir}/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>k3vnc.OpenFoodJournal.preview</string>
  <key>CFBundleDisplayName</key>
  <string>OFJ Preview</string>
  <key>CFBundleExecutable</key>
  <string>OFJPreview</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
</dict>
</plist>
EOF
cat > "${ipa_stage}/entitlements.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>application-identifier</key>
  <string>83B48K23H4.k3vnc.OpenFoodJournal.preview</string>
  <key>com.apple.developer.healthkit</key>
  <true/>
  <key>com.apple.developer.icloud-container-identifiers</key>
  <array>
    <string>iCloud.k3vnc.OpenFoodJournal.preview</string>
  </array>
  <key>com.apple.developer.icloud-services</key>
  <array>
    <string>CloudKit</string>
  </array>
</dict>
</plist>
EOF
codesign --force --sign - --entitlements "${ipa_stage}/entitlements.plist" "${app_dir}" >/dev/null 2>&1
(cd "${ipa_stage}" && zip -qr "${fixture_root}/OFJPreview.ipa" Payload)

bash .github/scripts/verify-signed-ipa.sh \
  "${fixture_root}/OFJPreview.ipa" \
  k3vnc.OpenFoodJournal.preview \
  83B48K23H4 \
  iCloud.k3vnc.OpenFoodJournal.preview \
  "OFJ Preview" >/dev/null

if bash .github/scripts/verify-signed-ipa.sh \
  "${fixture_root}/OFJPreview.ipa" \
  k3vnc.OpenFoodJournal \
  83B48K23H4 \
  iCloud.k3vnc.OpenFoodJournal \
  "OpenFoodJournal" >/dev/null 2>&1
then
  echo "Preview IPA unexpectedly passed production IPA verification." >&2
  exit 1
fi

if bash .github/scripts/verify-signed-ipa.sh \
  "${fixture_root}/OFJPreview.ipa" \
  k3vnc.OpenFoodJournal.preview \
  83B48K23H4 \
  iCloud.k3vnc.OpenFoodJournal \
  "OFJ Preview" >/dev/null 2>&1
then
  echo "IPA with preview CloudKit unexpectedly matched production CloudKit expectation." >&2
  exit 1
fi

echo "Release workflow contract tests passed."
