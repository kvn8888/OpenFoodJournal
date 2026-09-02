#!/bin/bash

# Resolves the App Store product-page copy for a version, in descending order of
# authority:
#
#   0. repository-override  - metadata/releases/<version>/<locale>/store.json
#   1. agentic-harness      - JSON already produced by the agent step
#   2. bifrost              - single-model generation through the router
#   3. copy-from-previous   - generate nothing; the caller keeps the live copy
#
# Every tier that produces fields must pass validate-store-metadata.sh. A tier
# that fails validation falls through rather than failing the release, which is
# the same contract generate-release-notes.sh uses for What's New.

set -euo pipefail

if [[ "$#" -ne 8 ]]; then
  echo "Usage: generate-store-metadata.sh VERSION LOCALE EVIDENCE CURRENT_DESCRIPTION AGENT_OUTPUT OUTPUT_JSON OUTPUT_METADATA MODEL" >&2
  exit 64
fi

version="$1"
locale="$2"
evidence_path="$3"
current_description_path="$4"
agent_output_path="$5"
output_json_path="$6"
output_metadata_path="$7"
model="$8"

override_path="metadata/releases/${version}/${locale}/store.json"
system_prompt_path="ci/prompts/store-metadata-system.txt"
user_prompt_path="ci/prompts/store-metadata-user.txt"
validator=".github/scripts/validate-store-metadata.sh"
source_name=""
resolved_model=""

mkdir -p "$(dirname "${output_json_path}")" "$(dirname "${output_metadata_path}")"

# Reasoning models bill hidden reasoning against this cap, and a 4000-character
# description is already large, so leave generous headroom.
max_tokens=6000

render_prompt() {
  awk \
    -v version="${version}" \
    -v evidence="${evidence_path}" \
    -v current="${current_description_path}" '
    {
      gsub(/\{\{VERSION\}\}/, version)
    }
    $0 == "{{EVIDENCE}}" {
      while ((getline line < evidence) > 0) print line
      next
    }
    $0 == "{{CURRENT_DESCRIPTION}}" {
      while ((getline line < current) > 0) print line
      next
    }
    { print }
  ' "${user_prompt_path}"
}

# Models sometimes wrap JSON in a code fence despite the instruction. Strip it
# before validation so one stray fence does not demote a usable generation.
extract_json() {
  sed -e 's/^[[:space:]]*```json[[:space:]]*$//' -e 's/^[[:space:]]*```[[:space:]]*$//' |
    jq -c '.' 2>/dev/null || true
}

# --- Tier 0: a committed override always wins -------------------------------
if [[ -f "${override_path}" ]]; then
  if jq -c '.' "${override_path}" > "${output_json_path}" 2>/dev/null &&
    bash "${validator}" "${output_json_path}"; then
    source_name="repository-override"
  else
    echo "Committed store.json for ${version}/${locale} is unusable; ignoring it." >&2
  fi
fi

# --- Tier 1: the agentic harness --------------------------------------------
if [[ -z "${source_name}" && -n "${agent_output_path}" && -s "${agent_output_path}" ]]; then
  if extract_json < "${agent_output_path}" > "${output_json_path}" &&
    bash "${validator}" "${output_json_path}"; then
    source_name="agentic-harness"
    resolved_model="${STORE_METADATA_AGENT_MODEL:-}"
  else
    echo "Agentic store-metadata output failed validation; trying the router." >&2
  fi
fi

# --- Tier 2: single-model generation through Bifrost ------------------------
if [[ -z "${source_name}" ]] &&
  [[ -n "${model}" && "${model}" != "null" ]] &&
  [[ -f "${system_prompt_path}" && -f "${user_prompt_path}" ]] &&
  [[ -n "${BIFROST_BASE_URL:-}" && -n "${BIFROST_VIRTUAL_KEY:-}" ]]; then

  request_path="${RUNNER_TEMP:-/tmp}/store-metadata-request.json"
  response_path="${RUNNER_TEMP:-/tmp}/store-metadata-response.json"

  # Unprefixed model names on purpose: the virtual key's own provider selection
  # is where weighting and rotation apply. The explicit chain below only covers
  # a model unavailable everywhere, which selection cannot fix.
  fallbacks_json="$(jq -c '.storeMetadataFallbackModels // []' ci/release-config.json)"
  fallbacks_json="$(jq -c --arg m "${model}" 'map(select(. != $m))' <<< "${fallbacks_json}")"

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
      temperature: 0.2,
      response_format: {type: "json_object"}
    }
    + (if ($fallbacks | length) > 0 then {fallbacks: $fallbacks} else {} end)' \
    > "${request_path}"

  bifrost_args=(-H "x-bf-vk: ${BIFROST_VIRTUAL_KEY}")
  if [[ -n "${BIFROST_AUTHORIZATION:-}" ]]; then
    bifrost_args+=(-H "Authorization: ${BIFROST_AUTHORIZATION}")
  fi

  if curl \
    --silent --show-error --fail-with-body \
    --retry 2 --retry-all-errors \
    --connect-timeout 10 --max-time 120 \
    -X POST \
    -H "Content-Type: application/json" \
    "${bifrost_args[@]}" \
    "${BIFROST_BASE_URL%/}/chat/completions" \
    --data-binary "@${request_path}" \
    > "${response_path}"; then

    jq -r '.choices[0].message.content // empty' "${response_path}" |
      extract_json > "${output_json_path}"

    if bash "${validator}" "${output_json_path}"; then
      source_name="bifrost"
      # A fallback may have served this, so record what answered.
      resolved_model="$(jq -r '.model // empty' "${response_path}")"
      resolved_model="${resolved_model:-${model}}"
    else
      echo "Router store-metadata generation was unusable." >&2
    fi
  else
    echo "Router store-metadata request failed." >&2
  fi
fi

# --- Tier 3: keep whatever is live on the App Store -------------------------
if [[ -z "${source_name}" ]]; then
  rm -f "${output_json_path}"
  source_name="copy-from-previous-version"
  resolved_model=""
fi

jq -n \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg locale "${locale}" \
  --arg model "${resolved_model}" \
  --arg source "${source_name}" \
  --arg version "${version}" \
  --argjson fieldsGenerated "$([[ -s "${output_json_path}" ]] && echo true || echo false)" \
  '{
    version: $version,
    locale: $locale,
    source: $source,
    model: (if $model == "" then null else $model end),
    fieldsGenerated: $fieldsGenerated,
    generatedAt: $generatedAt,
    requiresHumanApproval: true
  }' > "${output_metadata_path}"

printf 'source=%s\n' "${source_name}"
