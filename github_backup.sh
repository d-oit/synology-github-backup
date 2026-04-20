#!/bin/sh
# github_backup.sh — Synology NAS multi-account GitHub ZIP backup
#
# Tokens file: one PAT per line, blank lines and lines starting with # ignored.
# Logs are APPENDED to $LOG_FILE so history is preserved across runs.
#
# Known issues handled:
#   - HTTP/2 stream errors on Synology DSM  -> forced HTTP/1.1
#   - Empty/uninitialised repos return 400  -> detected and skipped with WARN
#   - Fine-grained PAT scope errors         -> raw GitHub error printed in log
#   - Subshell counter loss in pipes        -> TSV written to temp file first

BACKUP_ROOT="/volume1/homes/Dominik/sourcecode/github"
TOKENS_FILE="/volume1/homes/Dominik/sourcecode/github_tokens.txt"
LOG_FILE="/volume1/homes/Dominik/sourcecode/github_backup.log"
API_VERSION="2022-11-28"

mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_ROOT"

# Append — do not overwrite previous run logs
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

# ── curl wrapper: returns "HTTP_CODE BODY" separated by a sentinel ─────────────
# Always uses --http1.1 (fixes Synology DSM HTTP/2 stream errors)
# Never uses -f so we always get the response body even on 4xx/5xx
api_call() {
  method="$1"; url="$2"; token="$3"
  curl --http1.1 -sS \
    -X "$method" \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    -w "\n===STATUS===%{http_code}" \
    "$url" 2>&1 || true
}

api_download() {
  url="$1"; token="$2"; outfile="$3"
  curl --http1.1 -sS -L \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${token}" \
    -H "X-GitHub-Api-Version: ${API_VERSION}" \
    -w "\n===STATUS===%{http_code}" \
    -o "$outfile" \
    "$url" 2>&1 || true
}

parse_code() { printf '%s' "$1" | grep '===STATUS===' | sed 's/.*===STATUS===//'; }
parse_body() { printf '%s' "$1" | sed '/===STATUS===/d'; }

# ── get_login ──────────────────────────────────────────────────────────────────
# Returns the GitHub login for the given PAT, or empty string on failure.
# Prints detailed diagnostics so token permission issues are visible in the log.
get_login() {
  token="$1"
  raw=$(api_call GET "https://api.github.com/user" "$token")
  code=$(parse_code "$raw")
  body=$(parse_body "$raw")

  if [ "${code:-0}" != "200" ]; then
    err "  GET /user -> HTTP ${code:-curl_error}"
    err "  Response : ${body}"
    err "  Hint     : fine-grained PAT needs Account > User permissions (read)"
    err "             OR use a classic PAT with 'repo' scope"
    return 1
  fi

  login=$(printf '%s' "$body" | jq -r '.login // empty' 2>/dev/null || true)
  if [ -z "${login:-}" ]; then
    err "  Could not parse .login from: ${body}"
    return 1
  fi
  printf '%s' "$login"
}

# ── list_repos_page ────────────────────────────────────────────────────────────
list_repos_page() {
  token="$1"; page="$2"; login="$3"
  raw=$(api_call GET \
    "https://api.github.com/user/repos?type=owner&per_page=100&page=${page}" \
    "$token")
  code=$(parse_code "$raw")
  body=$(parse_body "$raw")

  if [ "${code:-0}" != "200" ]; then
    err "[${login}] GET /user/repos page ${page} -> HTTP ${code:-curl_error}"
    err "[${login}] Response: ${body}"
    printf '[]'
    return 0
  fi
  printf '%s' "$body"
}

# ── download_zipball ───────────────────────────────────────────────────────────
# HTTP 400/409 = empty/uninitialised repo — logged as WARN, not ERROR.
# HTTP 404     = repo gone or no permission — logged as WARN.
# Any other non-2xx = ERROR.
download_zipball() {
  token="$1"; full_name="$2"; outfile="$3"; login="$4"

  tmpfile=$(mktemp "${outfile}.XXXXXX")
  raw=$(api_download \
    "https://api.github.com/repos/${full_name}/zipball" \
    "$token" "$tmpfile")
  code=$(parse_code "$raw")

  # A successful redirect chain ends on 200; check file is non-empty too
  if [ "${code:-0}" -ge 200 ] 2>/dev/null && \
     [ "${code:-0}" -lt 300 ] 2>/dev/null && \
     [ -s "$tmpfile" ]; then
    mv "$tmpfile" "$outfile"
    log "[${login}] OK       ${full_name}  ($(du -k "$outfile" | cut -f1) KB)"
    return 0
  fi

  rm -f "$tmpfile"

  case "${code:-0}" in
    400|409)
      warn "[${login}] EMPTY    ${full_name}  (HTTP ${code} — repo has no commits, skipped)"
      return 2  # distinct exit code: skip, not failure
      ;;
    404)
      warn "[${login}] NOTFOUND ${full_name}  (HTTP 404 — no access or deleted)"
      return 2
      ;;
    *)
      err  "[${login}] FAILED   ${full_name}  (HTTP ${code:-curl_error})"
      return 1
      ;;
  esac
}

# ── main ───────────────────────────────────────────────────────────────────────
[ -f "$TOKENS_FILE" ] || { err "Tokens file not found: $TOKENS_FILE"; exit 1; }

log "========== backup start  (pid $$) =========="
log "BACKUP_ROOT : $BACKUP_ROOT"
log "LOG_FILE    : $LOG_FILE"

while IFS= read -r OAUTH_TOKEN || [ -n "${OAUTH_TOKEN:-}" ]; do
  [ -z "${OAUTH_TOKEN:-}" ] && continue
  case "$OAUTH_TOKEN" in \#*) continue ;; esac

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

      # GitHub API reports size=0 for empty/uninitialised repos — skip early
      if [ "${REPO_SIZE:-1}" = "0" ]; then
        warn "[${LOGIN}] EMPTY    ${FULL_NAME}  (size=0 in API, no commits)"
        ACCOUNT_SKIP=$((ACCOUNT_SKIP + 1))
        SCRIPT_SKIP_EMPTY=$((SCRIPT_SKIP_EMPTY + 1))
        continue
      fi

      download_zipball "$OAUTH_TOKEN" "$FULL_NAME" "$OUTFILE" "$LOGIN"
      rc=$?
      case $rc in
        0) ACCOUNT_OK=$((ACCOUNT_OK + 1));   SCRIPT_OK=$((SCRIPT_OK + 1)) ;;
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
