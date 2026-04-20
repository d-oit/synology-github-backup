#!/bin/sh
# github_backup.sh — Synology NAS multi-account GitHub ZIP backup
# Logs to $LOG_FILE. On failure the raw API response is printed for diagnosis.

BACKUP_ROOT="/volume1/homes/Dominik/sourcecode/github"
TOKENS_FILE="/volume1/homes/Dominik/sourcecode/github_tokens.txt"
LOG_FILE="/volume1/homes/Dominik/sourcecode/github_backup.log"
API_VERSION="2022-11-28"
# --http1.1 avoids "HTTP/2 stream 1 was not closed cleanly" on Synology DSM curl
CURL="curl --http1.1 -fsSL"
CURL_VERBOSE="curl --http1.1 -sS"

# ── logging ──────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > "$LOG_FILE" 2>&1

log()  { printf '[%s] INFO  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
err()  { printf '[%s] ERROR %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# ── counters (script-level, not subshell) ─────────────────────────────────────
SCRIPT_OK=0
SCRIPT_FAIL=0
SCRIPT_SKIP=0

# ── helpers ──────────────────────────────────────────────────────────────────
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command not found: $1"
    exit 1
  }
}

require_cmd curl
require_cmd jq
require_cmd mktemp

mkdir -p "$BACKUP_ROOT"

# Call GET /user and return the login field.
# On failure print the raw API response so the error is visible in the log.
get_login() {
  token="$1"
  http_code=0
  response=$($CURL_VERBOSE \
    -w '\n__HTTP_CODE__%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "https://api.github.com/user" 2>&1) || true

  # Split body and HTTP status code
  http_code=$(printf '%s' "$response" | grep '__HTTP_CODE__' | sed 's/.*__HTTP_CODE__//')
  body=$(printf '%s' "$response" | sed '/__HTTP_CODE__/d')

  if [ "$http_code" != "200" ]; then
    err "GET /user returned HTTP ${http_code:-unknown}"
    err "Raw API response: ${body}"
    return 1
  fi

  login=$(printf '%s' "$body" | jq -r '.login // empty' 2>/dev/null)
  if [ -z "${login:-}" ]; then
    err "Could not parse login from response: ${body}"
    return 1
  fi

  printf '%s' "$login"
}

# Fetch one page of owned repos. Returns raw JSON.
list_repos_page() {
  token="$1"
  page="$2"
  login="$3"
  response=$($CURL_VERBOSE \
    -w '\n__HTTP_CODE__%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    "https://api.github.com/user/repos?type=owner&per_page=100&page=${page}" 2>&1) || true

  http_code=$(printf '%s' "$response" | grep '__HTTP_CODE__' | sed 's/.*__HTTP_CODE__//')
  body=$(printf '%s' "$response" | sed '/__HTTP_CODE__/d')

  if [ "$http_code" != "200" ]; then
    err "[${login}] GET /user/repos page ${page} returned HTTP ${http_code:-unknown}"
    err "[${login}] Raw API response: ${body}"
    printf '[]'
    return 0
  fi

  printf '%s' "$body"
}

# Download a single repo as a ZIP. Uses a temp file so partial downloads are
# never left as the final file. Returns 0 even on failure (logged as WARN).
download_zipball() {
  token="$1"
  full_name="$2"
  outfile="$3"
  login="$4"

  tmpfile=$(mktemp "${outfile}.XXXXXX")

  http_code=$($CURL_VERBOSE \
    -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    -L \
    "https://api.github.com/repos/${full_name}/zipball" \
    -o "$tmpfile" 2>&1) || true

  # http_code may be on its own or appended after curl error text
  code=$(printf '%s' "$http_code" | tr -d '[:space:]' | grep -oE '[0-9]{3}$' || true)

  if [ "${code:-0}" -ge 200 ] && [ "${code:-0}" -lt 300 ] && [ -s "$tmpfile" ]; then
    mv "$tmpfile" "$outfile"
    log "[${login}] OK       ${full_name} -> $(basename "$outfile")"
    return 0
  else
    warn "[${login}] FAILED   ${full_name} (HTTP ${code:-unknown})"
    rm -f "$tmpfile"
    return 1
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────
if [ ! -f "$TOKENS_FILE" ]; then
  err "Tokens file not found: $TOKENS_FILE"
  exit 1
fi

log "========== backup start =========="
log "BACKUP_ROOT : $BACKUP_ROOT"
log "TOKENS_FILE : $TOKENS_FILE"

while IFS= read -r OAUTH_TOKEN || [ -n "${OAUTH_TOKEN:-}" ]; do
  [ -z "${OAUTH_TOKEN:-}" ] && continue
  case "$OAUTH_TOKEN" in \#*) continue ;; esac

  # Mask token in log: show first 12 chars only
  TOKEN_HINT=$(printf '%s' "$OAUTH_TOKEN" | cut -c1-20)"..."
  log "--- processing token ${TOKEN_HINT}"

  LOGIN=$(get_login "$OAUTH_TOKEN") || {
    err "Skipping token ${TOKEN_HINT} — login resolution failed (see above)"
    SCRIPT_SKIP=$((SCRIPT_SKIP + 1))
    continue
  }

  log "[${LOGIN}] Resolved login: ${LOGIN}"

  ACCOUNT_PATH="${BACKUP_ROOT}/${LOGIN}"
  mkdir -p "$ACCOUNT_PATH"

  ACCOUNT_OK=0
  ACCOUNT_FAIL=0

  page=1
  while :; do
    log "[${LOGIN}] Fetching repo list page ${page}"
    JSON=$(list_repos_page "$OAUTH_TOKEN" "$page" "$LOGIN")
    COUNT=$(printf '%s' "$JSON" | jq 'length' 2>/dev/null || echo 0)
    log "[${LOGIN}] Page ${page}: ${COUNT} repos"
    [ "$COUNT" -eq 0 ] && break

    # Write tsv to a temp file to avoid subshell counter problem
    tsv_tmp=$(mktemp)
    printf '%s' "$JSON" | jq -r '.[] | [.name, .full_name] | @tsv' > "$tsv_tmp"

    while IFS="$(printf '\t')" read -r REPONAME FULL_NAME; do
      [ -z "${REPONAME:-}" ] && continue
      OUTFILE="${ACCOUNT_PATH}/${REPONAME}.zip"
      if download_zipball "$OAUTH_TOKEN" "$FULL_NAME" "$OUTFILE" "$LOGIN"; then
        ACCOUNT_OK=$((ACCOUNT_OK + 1))
        SCRIPT_OK=$((SCRIPT_OK + 1))
      else
        ACCOUNT_FAIL=$((ACCOUNT_FAIL + 1))
        SCRIPT_FAIL=$((SCRIPT_FAIL + 1))
      fi
    done < "$tsv_tmp"
    rm -f "$tsv_tmp"

    page=$((page + 1))
  done

  log "[${LOGIN}] Done — OK: ${ACCOUNT_OK}  FAILED: ${ACCOUNT_FAIL}"
done < "$TOKENS_FILE"

log "========== backup complete — OK: ${SCRIPT_OK}  FAILED: ${SCRIPT_FAIL}  SKIPPED_ACCOUNTS: ${SCRIPT_SKIP} =========="
