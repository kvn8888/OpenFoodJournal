#!/bin/bash

set -euo pipefail

if [[ "$#" -ne 2 ]]; then
  echo "Usage: validate-release-notes.sh NOTES_FILE LOCALE" >&2
  exit 64
fi

notes_path="$1"
locale="$2"

if [[ ! -f "${notes_path}" ]]; then
  echo "Release-notes file does not exist: ${notes_path}" >&2
  exit 1
fi

if [[ ! "${locale}" =~ ^[a-z]{2}(-[A-Z]{2})?$ ]]; then
  echo "Invalid App Store locale: ${locale}" >&2
  exit 1
fi

character_count="$(jq -Rs 'length' < "${notes_path}")"
non_whitespace_count="$(tr -d '[:space:]' < "${notes_path}" | wc -c | tr -d ' ')"

if [[ "${non_whitespace_count}" -eq 0 ]]; then
  echo "Release notes cannot be empty." >&2
  exit 1
fi

if [[ "${character_count}" -gt 4000 ]]; then
  echo "Release notes contain ${character_count} characters; App Store Connect allows at most 4000." >&2
  exit 1
fi

if LC_ALL=C grep -q '[[:cntrl:]]' "${notes_path}"; then
  echo "Release notes contain unsupported control characters." >&2
  exit 1
fi

printf 'Validated %s release-note characters for %s.\n' "${character_count}" "${locale}"
