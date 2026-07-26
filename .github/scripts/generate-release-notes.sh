#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 7 ]]; then
  echo "Usage: generate-release-notes.sh VERSION BUILD LOCALE WHAT_TO_TEST OUTPUT_NOTES OUTPUT_METADATA MODEL" >&2
  exit 64
fi

version="$1"
build_number="$2"
locale="$3"
what_to_test_path="$4"
output_notes_path="$5"
output_metadata_path="$6"
model="$7"
override_path="metadata/releases/${version}/${locale}/whats-new.txt"
notes_source=""

mkdir -p "$(dirname "${output_notes_path}")" "$(dirname "${output_metadata_path}")"

if [[ -f "${override_path}" ]]; then
  cp "${override_path}" "${output_notes_path}"
  notes_source="repository-override"
elif [[ -n "${GH_TOKEN:-}" && -n "${model}" && "${model}" != "null" ]]; then
  prompt="$(
    jq -Rs \
      --arg version "${version}" \
      --arg changes "$(cat "${what_to_test_path}")" \
      '
        "Write concise public App Store What'\''s New notes for OpenFoodJournal version "
        + $version
        + ". Use only the supplied change evidence. Prefer 2 to 5 short user-facing bullets. "
        + "Do not mention commits, hashes, branches, CI, internal testing, implementation details, "
        + "future work, or claims not supported by the evidence. Return only the final notes, "
        + "with no heading or code fence.\n\nChange evidence:\n"
        + $changes
      ' /dev/null
  )"
  request_path="${RUNNER_TEMP:-/tmp}/release-notes-request.json"
  response_path="${RUNNER_TEMP:-/tmp}/release-notes-response.json"
  jq -n \
    --arg model "${model}" \
    --arg prompt "${prompt}" \
    '{
      model: $model,
      messages: [
        {
          role: "system",
          content: "You are a careful App Store release editor. Accuracy and plain language matter more than marketing."
        },
        {role: "user", content: $prompt}
      ],
      max_tokens: 700,
      temperature: 0.2
    }' > "${request_path}"

  if curl \
    --silent \
    --show-error \
    --fail-with-body \
    --retry 2 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 45 \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    -H "Content-Type: application/json" \
    https://models.github.ai/inference/chat/completions \
    --data-binary "@${request_path}" \
    > "${response_path}"; then
    jq -r '.choices[0].message.content // empty' "${response_path}" > "${output_notes_path}"
    if bash .github/scripts/validate-release-notes.sh "${output_notes_path}" "${locale}" >/dev/null; then
      notes_source="github-models"
    else
      notes_source=""
    fi
  else
    echo "GitHub Models release-note generation was unavailable; using deterministic notes." >&2
  fi
fi

if [[ -z "${notes_source}" ]]; then
  {
    echo "This update includes:"
    echo
    sed -E \
      -e 's/^[[:space:]]*[-*•][[:space:]]*//' \
      -e 's/^[[:alpha:]]+(\([^)]*\))?!?:[[:space:]]*//' \
      -e '/\[skip ci\]/d' \
      "${what_to_test_path}" |
      awk 'NF && !seen[$0]++' |
      head -n 8 |
      awk '{ print "• " $0 }'
  } > "${output_notes_path}"
  notes_source="deterministic-git-history"
fi

bash .github/scripts/validate-release-notes.sh "${output_notes_path}" "${locale}"

jq -n \
  --arg buildNumber "${build_number}" \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg model "$([[ "${notes_source}" == "github-models" ]] && printf '%s' "${model}")" \
  --arg source "${notes_source}" \
  --arg version "${version}" \
  '{
    version: $version,
    buildNumber: $buildNumber,
    source: $source,
    model: (if $model == "" then null else $model end),
    generatedAt: $generatedAt,
    requiresHumanApproval: true
  }' > "${output_metadata_path}"
