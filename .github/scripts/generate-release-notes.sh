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
system_prompt_path="ci/prompts/whats-new-system.txt"
user_prompt_path="ci/prompts/whats-new-user.txt"
notes_source=""
notes_model=""

mkdir -p "$(dirname "${output_notes_path}")" "$(dirname "${output_metadata_path}")"

# Reasoning models bill hidden reasoning tokens against this cap. A budget that
# only covers the visible bullets returns an empty message and silently demotes
# the run to deterministic notes, so leave headroom for the reasoning pass.
max_tokens=2500

render_prompt() {
  sed -e "s/{{VERSION}}/${version}/g" "${user_prompt_path}" |
    awk -v evidence="${what_to_test_path}" '
      $0 == "{{EVIDENCE}}" {
        while ((getline line < evidence) > 0) print line
        next
      }
      { print }
    '
}

# Emits the assistant text on success, nothing on failure. Callers decide
# whether an empty result is fatal.
call_chat_completions() {
  local endpoint="$1"
  local request_path="$2"
  local response_path="$3"
  shift 3

  if curl \
    --silent \
    --show-error \
    --fail-with-body \
    --retry 2 \
    --retry-all-errors \
    --connect-timeout 10 \
    --max-time 90 \
    -X POST \
    -H "Content-Type: application/json" \
    "$@" \
    "${endpoint}" \
    --data-binary "@${request_path}" \
    > "${response_path}"; then
    jq -r '.choices[0].message.content // empty' "${response_path}"
  fi
}

if [[ -f "${override_path}" ]]; then
  cp "${override_path}" "${output_notes_path}"
  notes_source="repository-override"
elif [[ -n "${model}" && "${model}" != "null" ]] &&
  [[ -f "${system_prompt_path}" && -f "${user_prompt_path}" ]]; then
  request_path="${RUNNER_TEMP:-/tmp}/release-notes-request.json"
  response_path="${RUNNER_TEMP:-/tmp}/release-notes-response.json"

  # The router does no automatic cross-provider routing on its own: no
  # provider-level fallbacks are configured and max_retries is 0, so a single
  # upstream outage would otherwise fail the whole call. Bifrost does honour a
  # per-request fallback chain, so send one. Entries are "provider/model" and
  # are tried in order when the primary errors.
  fallbacks_json="$(
    jq -c '.releaseNotesFallbackModels // []' ci/release-config.json
  )"
  if [[ -n "${RELEASE_NOTES_FALLBACK_MODELS:-}" ]]; then
    # Comma-separated override, so the chain can be changed without a commit.
    fallbacks_json="$(
      jq -Rc 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))' \
        <<< "${RELEASE_NOTES_FALLBACK_MODELS}"
    )"
  fi
  # A model must never list itself as its own fallback.
  fallbacks_json="$(
    jq -c --arg model "${model}" 'map(select(. != $model))' <<< "${fallbacks_json}"
  )"

  jq -n \
    --arg model "${model}" \
    --arg system "$(cat "${system_prompt_path}")" \
    --arg user "$(render_prompt)" \
    --argjson maxTokens "${max_tokens}" \
    --argjson fallbacks "${fallbacks_json}" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $system},
        {role: "user", content: $user}
      ],
      max_tokens: $maxTokens,
      temperature: 0.2
    }
    + (if ($fallbacks | length) > 0 then {fallbacks: $fallbacks} else {} end)' \
    > "${request_path}"

  # Preferred provider: the self-hosted Bifrost router. It is a single machine,
  # so every failure below has to fall through rather than fail the release.
  if [[ -n "${BIFROST_BASE_URL:-}" && -n "${BIFROST_VIRTUAL_KEY:-}" ]]; then
    bifrost_args=(-H "x-bf-vk: ${BIFROST_VIRTUAL_KEY}")
    if [[ -n "${BIFROST_AUTHORIZATION:-}" ]]; then
      bifrost_args+=(-H "Authorization: ${BIFROST_AUTHORIZATION}")
    fi

    call_chat_completions \
      "${BIFROST_BASE_URL%/}/chat/completions" \
      "${request_path}" \
      "${response_path}" \
      "${bifrost_args[@]}" \
      > "${output_notes_path}"

    if bash .github/scripts/validate-release-notes.sh "${output_notes_path}" "${locale}" >/dev/null; then
      notes_source="bifrost"
      # A fallback may have served this, so report what actually answered
      # rather than what was asked for.
      notes_model="$(jq -r '.model // empty' "${response_path}")"
      notes_model="${notes_model:-${model}}"
    else
      echo "Bifrost release-note generation was unusable; trying GitHub Models." >&2
    fi
  fi

  if [[ -z "${notes_source}" && -n "${GH_TOKEN:-}" ]]; then
    # GitHub Models names models the same way (provider/model), but has no
    # concept of a fallback chain and rejects the unknown field.
    github_request_path="${RUNNER_TEMP:-/tmp}/release-notes-request-github.json"
    jq 'del(.fallbacks)' "${request_path}" > "${github_request_path}"

    call_chat_completions \
      "https://models.github.ai/inference/chat/completions" \
      "${github_request_path}" \
      "${response_path}" \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      -H "X-GitHub-Api-Version: 2026-03-10" \
      > "${output_notes_path}"

    if bash .github/scripts/validate-release-notes.sh "${output_notes_path}" "${locale}" >/dev/null; then
      notes_source="github-models"
      notes_model="${model}"
    else
      echo "GitHub Models release-note generation was unavailable; using deterministic notes." >&2
    fi
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
  notes_model=""
fi

bash .github/scripts/validate-release-notes.sh "${output_notes_path}" "${locale}"

jq -n \
  --arg buildNumber "${build_number}" \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg model "${notes_model}" \
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
