#!/bin/sh
# github_backup.sh — Synology NAS multi-account GitHub ZIP backup
#
# Tokens file: one PAT per line, blank/comment lines ignored, CRLF stripped.
# Logs are APPENDED to $LOG_FILE so history is preserved across runs.
#
# Busybox-safe: HTTP code via -o tmpfile + -w %{http_code}.
# Download success is determined by non-empty output file only —
# NOT by HTTP code, because busybox curl -L returns the redirect code (302)
# instead of the final 200, which broke the mv step.

BACKUP_ROOT="/volume1/homes/Dominik/sourcecode/github"
TOKENS_FILE="/volume1/homes/Dominik/sourcecode/github_tokens.txt"
LOG_FILE="/volume1/homes/Dominik/sourcecode/github_backup.log"
API_VERSION="2022-11-28"

mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_ROOT"
exec >> "$LOG_FILE" 2>&1

ts()   { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] INFO  %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARN  %s\n' "$(ts)" "$*"; }
err()  { printf '[%s] ERROR %s\n' "$(ts)" "$*"; }

SCRIPT_OK=0
SCRIPT_FAIL=0
SCRIPT_SKIP_EMPTY=0
SCRIPT_SKIP_ACCOUNT=0

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 1; }
}
require_cmd curl
require_cmd jq
require_cmd mktemp

# Clean up any leftover temp files from previous crashed runs
log "Cleaning up stale temp files in ${BACKUP_ROOT}..."
find "$BACKUP_ROOT" -name '*.zip.*' -type f -delete 2>/dev/null || true

# ── api_call: sets RESP_CODE and RESP_BODY ────────────────────────────────────
api_call() {
  _token="$1"; _url="$2"
  _body_tmp=$(mktemp)
  RESP_CODE=$(curl --http1.1 -sS \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${_token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    -o "$_body_tmp" \
    -w "%{http_code}" \
    "$_url" 2>/dev/null) || RESP_CODE="000"
  RESP_BODY=$(cat "$_body_tmp" 2>/dev/null || true)
  rm -f "$_body_tmp"
}

# ── api_download: downloads to file, success = non-empty file ─────────────────
# We do NOT check HTTP code here because busybox curl -L reports the
# redirect status (302) rather than the final response code (200).
# A non-empty output file is the reliable success indicator.
api_download() {
  _token="$1"; _url="$2"; _outfile="$3"
  curl --http1.1 -sS -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${_token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    -o "$_outfile" \
    "$_url" 2>/dev/null
  return $?
}

# ── get_login ─────────────────────────────────────────────────────────────────
get_login() {
  _token="$1"
  api_call "$_token" "https://api.github.com/user"
  if [ "$RESP_CODE" != "200" ]; then
    err "  GET /user -> HTTP ${RESP_CODE}"
    err "  Response : ${RESP_BODY}"
    err "  Hint     : fine-grained PAT needs 'Account permissions > Profile: Read'"
    err "             Classic PAT needs 'repo' or 'read:user' scope"
    return 1
  fi
  _login=$(printf '%s' "$RESP_BODY" | jq -r '.login // empty' 2>/dev/null || true)
  if [ -z "${_login:-}" ]; then
    err "  Could not parse .login — raw: ${RESP_BODY}"
    return 1
  fi
  printf '%s' "$_login"
}

# ── list_repos_page ───────────────────────────────────────────────────────────
list_repos_page() {
  _token="$1"; _page="$2"; _login="$3"
  api_call "$_token" \
    "https://api.github.com/user/repos?type=owner&per_page=100&page=${_page}"
  if [ "$RESP_CODE" != "200" ]; then
    err "[${_login}] GET /user/repos page ${_page} -> HTTP ${RESP_CODE}"
    err "[${_login}] Response: ${RESP_BODY}"
    printf '[]'
    return 0
  fi
  printf '%s' "$RESP_BODY"
}

# ── download_zipball ──────────────────────────────────────────────────────────
download_zipball() {
  _token="$1"; _full_name="$2"; _outfile="$3"; _login="$4"
  _tmpfile=$(mktemp "${_outfile}.XXXXXX")

  if api_download "$_token" \
       "https://api.github.com/repos/${_full_name}/zipball" \
       "$_tmpfile" && [ -s "$_tmpfile" ]; then
    mv "$_tmpfile" "$_outfile"
    log "[${_login}] OK       ${_full_name}  ($(du -k "$_outfile" | cut -f1) KB)"
    return 0
  else
    # Check if curl wrote a JSON error body (e.g. {"message":"Not Found"})
    _errmsg=$(cat "$_tmpfile" 2>/dev/null | jq -r '.message // empty' 2>/dev/null || true)
    rm -f "$_tmpfile"
    if [ -n "${_errmsg:-}" ]; then
      case "${_errmsg}" in
        *"empty"*|*"no default branch"*|*"409"*)
          warn "[${_login}] EMPTY    ${_full_name}  (${_errmsg})"
          return 2 ;;
        *"Not Found"*)
          warn "[${_login}] NOTFOUND ${_full_name}  (${_errmsg})"
          return 2 ;;
        *)
          err  "[${_login}] FAILED   ${_full_name}  (${_errmsg})"
          return 1 ;;
      esac
    else
      err "[${_login}] FAILED   ${_full_name}  (empty output, curl error)"
      return 1
    fi
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────
[ -f "$TOKENS_FILE" ] || { err "Tokens file not found: $TOKENS_FILE"; exit 1; }

log "========== backup start  (pid $$) =========="
log "BACKUP_ROOT : $BACKUP_ROOT"
log "LOG_FILE    : $LOG_FILE"

while IFS= read -r RAW_LINE || [ -n "${RAW_LINE:-}" ]; do
  OAUTH_TOKEN=$(printf '%s' "${RAW_LINE}" | tr -d '\r')
  case "${OAUTH_TOKEN}" in
    ''|\#*) continue ;;
  esac

  TOKEN_HINT="$(printf '%s' "$OAUTH_TOKEN" | cut -c1-20)..."
  log "--- token: ${TOKEN_HINT}"

  LOGIN=$(get_login "$OAUTH_TOKEN") || {
    err "Skipping token ${TOKEN_HINT} — see errors above"
    SCRIPT_SKIP_ACCOUNT=$((SCRIPT_SKIP_ACCOUNT + 1))
    continue
  }

  log "[${LOGIN}] login OK"
  ACCOUNT_PATH="${BACKUP_ROOT}/${LOGIN}"
  mkdir -p "$ACCOUNT_PATH"

  ACCOUNT_OK=0; ACCOUNT_FAIL=0; ACCOUNT_SKIP=0

  page=1
  while :; do
    log "[${LOGIN}] fetching repo list page ${page}..."
    JSON=$(list_repos_page "$OAUTH_TOKEN" "$page" "$LOGIN")
    COUNT=$(printf '%s' "$JSON" | jq 'length' 2>/dev/null || echo 0)
    [ "$COUNT" -eq 0 ] && { log "[${LOGIN}] page ${page}: 0 repos — done"; break; }
    log "[${LOGIN}] page ${page}: ${COUNT} repos"

    tsv_tmp=$(mktemp)
    printf '%s' "$JSON" | jq -r '.[] | [.name, .full_name, (.size | tostring)] | @tsv' > "$tsv_tmp"

    while IFS="$(printf '\t')" read -r REPONAME FULL_NAME REPO_SIZE; do
      [ -z "${REPONAME:-}" ] && continue
      OUTFILE="${ACCOUNT_PATH}/${REPONAME}.zip"
      if [ "${REPO_SIZE:-1}" = "0" ]; then
        warn "[${LOGIN}] EMPTY    ${FULL_NAME}  (size=0, no commits)"
        ACCOUNT_SKIP=$((ACCOUNT_SKIP + 1))
        SCRIPT_SKIP_EMPTY=$((SCRIPT_SKIP_EMPTY + 1))
        continue
      fi
      download_zipball "$OAUTH_TOKEN" "$FULL_NAME" "$OUTFILE" "$LOGIN"
      rc=$?
      case $rc in
        0) ACCOUNT_OK=$((ACCOUNT_OK + 1));     SCRIPT_OK=$((SCRIPT_OK + 1)) ;;
        2) ACCOUNT_SKIP=$((ACCOUNT_SKIP + 1)); SCRIPT_SKIP_EMPTY=$((SCRIPT_SKIP_EMPTY + 1)) ;;
        *) ACCOUNT_FAIL=$((ACCOUNT_FAIL + 1)); SCRIPT_FAIL=$((SCRIPT_FAIL + 1)) ;;
      esac
    done < "$tsv_tmp"
    rm -f "$tsv_tmp"
    page=$((page + 1))
  done

  log "[${LOGIN}] account done — OK: ${ACCOUNT_OK}  FAILED: ${ACCOUNT_FAIL}  SKIPPED_EMPTY: ${ACCOUNT_SKIP}"
done < "$TOKENS_FILE"

log "========== backup complete — OK: ${SCRIPT_OK}  FAILED: ${SCRIPT_FAIL}  SKIPPED_EMPTY: ${SCRIPT_SKIP_EMPTY}  SKIPPED_ACCOUNTS: ${SCRIPT_SKIP_ACCOUNT} =========="
