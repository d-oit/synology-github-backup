#!/bin/sh
set -eu

BACKUP_ROOT="/volume1/homes/Dominik/sourcecode/github"
TOKENS_FILE="/volume1/homes/Dominik/sourcecode/github_tokens.txt"
API_VERSION="2022-11-28"
# Force HTTP/1.1 to avoid "HTTP/2 stream 1 was not closed cleanly" errors on Synology DSM
CURL_OPTS="--http1.1 -fsSL"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: missing required command: $1" >&2
    exit 1
  }
}

require_cmd curl
require_cmd jq
require_cmd mktemp

mkdir -p "$BACKUP_ROOT"

get_login() {
  token="$1"
  response=$(curl $CURL_OPTS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "https://api.github.com/user" 2>&1) || true
  printf '%s' "$response" | jq -r '.login // empty' 2>/dev/null || true
}

list_repos_page() {
  token="$1"
  page="$2"
  curl $CURL_OPTS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "https://api.github.com/user/repos?type=owner&per_page=100&page=${page}" || true
}

download_zipball() {
  token="$1"
  full_name="$2"
  outfile="$3"

  tmpfile="$(mktemp "${outfile}.XXXXXX")"
  trap 'rm -f "$tmpfile"' INT TERM HUP EXIT

  curl $CURL_OPTS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "https://api.github.com/repos/${full_name}/zipball" \
    -o "$tmpfile" || {
      echo "WARNING: failed to download ${full_name}, skipping" >&2
      rm -f "$tmpfile"
      trap - INT TERM HUP EXIT
      return 0
    }

  mv "$tmpfile" "$outfile"
  trap - INT TERM HUP EXIT
}

if [ ! -f "$TOKENS_FILE" ]; then
  echo "ERROR: tokens file not found: $TOKENS_FILE" >&2
  exit 1
fi

while IFS= read -r OAUTH_TOKEN || [ -n "${OAUTH_TOKEN:-}" ]; do
  [ -z "${OAUTH_TOKEN:-}" ] && continue

  case "$OAUTH_TOKEN" in
    \#*) continue ;;
  esac

  echo "Resolving login for token..."
  LOGIN="$(get_login "$OAUTH_TOKEN")"

  if [ -z "${LOGIN:-}" ]; then
    echo "ERROR: could not resolve GitHub login — check token and network" >&2
    continue
  fi

  ACCOUNT_PATH="${BACKUP_ROOT}/${LOGIN}"
  mkdir -p "$ACCOUNT_PATH"

  echo "=== Backing up account: ${LOGIN} ==="

  page=1
  while :; do
    JSON="$(list_repos_page "$OAUTH_TOKEN" "$page")"
    COUNT="$(printf '%s' "$JSON" | jq 'length' 2>/dev/null || echo 0)"
    [ "$COUNT" -eq 0 ] && break

    printf '%s' "$JSON" | jq -r '.[] | [.name, .full_name] | @tsv' |
    while IFS="$(printf '\t')" read -r REPONAME FULL_NAME; do
      [ -z "${REPONAME:-}" ] && continue
      OUTFILE="${ACCOUNT_PATH}/${REPONAME}.zip"
      echo "Downloading ${FULL_NAME} -> ${OUTFILE}"
      download_zipball "$OAUTH_TOKEN" "$FULL_NAME" "$OUTFILE"
    done

    page=$((page + 1))
  done
done < "$TOKENS_FILE"

echo "===== backup complete ====="
