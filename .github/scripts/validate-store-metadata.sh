#!/bin/bash

# Rejects generated App Store copy that Apple would reject, or that a model
# padded with prose around the JSON. Exits nonzero so callers can fall through
# to the next generation tier rather than pushing unusable metadata.

set -euo pipefail

if [[ "$#" -ne 1 ]]; then
  echo "Usage: validate-store-metadata.sh METADATA_JSON" >&2
  exit 64
fi

metadata_path="$1"

if [[ ! -s "${metadata_path}" ]]; then
  echo "Store metadata is empty: ${metadata_path}" >&2
  exit 1
fi

if ! jq -e 'type == "object"' "${metadata_path}" >/dev/null 2>&1; then
  echo "Store metadata is not a JSON object." >&2
  exit 1
fi

# An extra key would be pushed verbatim to App Store Connect, so treat any
# unexpected field as a failed generation rather than silently dropping it.
if ! jq -e '
  (keys - ["description", "keywords", "promotionalText"]) == []
  and has("description") and has("keywords") and has("promotionalText")
' "${metadata_path}" >/dev/null; then
  echo "Store metadata must contain exactly description, keywords and promotionalText." >&2
  jq -r 'keys | join(", ")' "${metadata_path}" >&2 || true
  exit 1
fi

check_length() {
  local field="$1"
  local limit="$2"
  local value
  value="$(jq -r --arg f "${field}" '.[$f] // ""' "${metadata_path}")"

  if [[ -z "${value// /}" ]]; then
    echo "Store metadata field ${field} is empty." >&2
    exit 1
  fi

  # Count characters, not bytes: Apple's limits are character limits and the
  # copy can carry non-ASCII punctuation.
  local length
  length="$(printf '%s' "${value}" | wc -m | tr -d '[:space:]')"
  if (( length > limit )); then
    echo "Store metadata field ${field} is ${length} characters; limit is ${limit}." >&2
    exit 1
  fi
}

check_length description 4000
check_length keywords 100
check_length promotionalText 170

# A model that "explains" its answer inside the description is a failed run.
if jq -re '.description' "${metadata_path}" | grep -qiE '^\s*(here (is|are)|sure[,!]|as an ai|```)'; then
  echo "Store metadata description contains assistant preamble." >&2
  exit 1
fi

if jq -re '.keywords' "${metadata_path}" | grep -qE '[;|]'; then
  echo "Store metadata keywords must be comma-separated." >&2
  exit 1
fi

exit 0
