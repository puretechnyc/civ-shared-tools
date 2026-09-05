#!/usr/bin/env bash
# cf_preflight v1.0 — 2026-09-05
# =============================================================================
# cf_preflight.sh — FAIL-CLOSED Cloudflare credential preflight
# =============================================================================
# PURPOSE
#   Kill the recurring FALSE "no CLOUDFLARE_API_TOKEN" alarm once and for all.
#   The token lives on-box under CF-prefixed names (CF_API_TOKEN / CF_ACCOUNT_ID
#   etc.) but wrangler + the CF SDKs want CLOUDFLARE_*-named vars. A checklist
#   note kept failing because it was PROCEDURAL (a human/agent had to remember).
#   This replaces the note with a MECHANISM.
#
# INVARIANT (why this is fail-closed)
#   A caller that sources this script CANNOT falsely conclude "no CF token".
#   The "blocked" verdict is UNREACHABLE until a real, read-only CF API probe
#   has actually returned success:false. Presence of an env var is NEVER
#   treated as proof — we verify BY-EFFECT.
#
# USAGE
#   As a preflight (sets CLOUDFLARE_* in the CALLER shell, then run wrangler):
#       source /home/aiciv/tools/cf_preflight.sh   # exports on success, returns non-zero on fail
#       wrangler pages deploy ...                  # only reached if source succeeded
#
#   Standalone verdict (does not need to be sourced):
#       /home/aiciv/tools/cf_preflight.sh --check
#
#   In a script, fail-closed one-liner:
#       source /home/aiciv/tools/cf_preflight.sh || { echo "CF auth failed"; exit 1; }
#
# GUARANTEES
#   - Exit/return 0  ONLY if a live GET /user/tokens/verify returned success:true.
#   - Exit/return !=0 with a clear message if it genuinely cannot authenticate.
#   - Never prints secret VALUES — only the RESOLVED SOURCE var name + verdict.
#
# SHARED SKILL
#   Safe for Chy, Aether, and Morphe to source before ANY wrangler/CF op.
# =============================================================================

# Detect if we are being sourced (so we `return` instead of `exit` in caller).
# shellcheck disable=SC2296
if [ -n "${ZSH_VERSION:-}" ]; then
  case "${ZSH_EVAL_CONTEXT:-}" in *:file) _cfpf_sourced=1;; *) _cfpf_sourced=0;; esac
else
  # bash: BASH_SOURCE[0] != $0 means sourced
  if [ "${BASH_SOURCE[0]:-$0}" != "${0}" ]; then _cfpf_sourced=1; else _cfpf_sourced=0; fi
fi

# _cfpf_die CODE MSG — return if sourced, exit if standalone.
_cfpf_die() {
  local code="$1"; shift
  echo "cf_preflight: $*" >&2
  if [ "${_cfpf_sourced}" = "1" ]; then return "$code"; else exit "$code"; fi
}

_cfpf_main() {
  local ENV_FILE="/home/aiciv/.env"
  local VERBOSE=0
  case "${1:-}" in
    --check) VERBOSE=1 ;;
    --help|-h)
      grep -E '^#( |$)' "${BASH_SOURCE[0]:-$0}" | sed 's/^# \{0,1\}//'
      return 0 ;;
  esac

  # 1) Source the env file if present (do not fail if absent — vars may be inherited).
  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE" 2>/dev/null || true
    set +a
  fi

  # 2) Auto-alias: resolve CLOUDFLARE_API_TOKEN from plausible CF-named vars.
  #    Ordered by specificity/likelihood. First non-empty wins.
  local TOKEN="" TOKEN_SRC=""
  local -a token_candidates=(
    CLOUDFLARE_API_TOKEN
    CF_API_TOKEN
    CF_PAGES_TOKEN
    CF_MANAGEMENT_TOKEN
    CF_EMAIL_ROUTING_TOKEN
    CLOUDFLARE_TOKEN
    CF_TOKEN
  )
  local v
  for v in "${token_candidates[@]}"; do
    if [ -n "${!v:-}" ]; then TOKEN="${!v}"; TOKEN_SRC="$v"; break; fi
  done

  # Account id alias (not required for token verify, but exported for wrangler).
  local ACCT="" ACCT_SRC=""
  local -a acct_candidates=(CLOUDFLARE_ACCOUNT_ID CF_ACCOUNT_ID CLOUDFLARE_ACCOUNT CF_ACCOUNT)
  for v in "${acct_candidates[@]}"; do
    if [ -n "${!v:-}" ]; then ACCT="${!v}"; ACCT_SRC="$v"; break; fi
  done

  if [ -z "$TOKEN" ]; then
    _cfpf_die 3 "no CF token found on-box (checked: ${token_candidates[*]}). This is a GENUINE missing-cred, not a name-gap."
    return $?
  fi

  # 3) PROBE BY-EFFECT — real, cheap, read-only CF API call. Never trust presence.
  command -v curl >/dev/null 2>&1 || { _cfpf_die 4 "curl not available; cannot probe by-effect."; return $?; }

  local resp http body ok
  resp="$(curl -sS -m 15 -w $'\n%{http_code}' \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4/user/tokens/verify" 2>/dev/null)"
  http="$(printf '%s' "$resp" | tail -n1)"
  body="$(printf '%s' "$resp" | sed '$d')"

  if command -v jq >/dev/null 2>&1; then
    ok="$(printf '%s' "$body" | jq -r '.success // false' 2>/dev/null)"
  else
    # Fallback string match if jq missing.
    case "$body" in *'"success":true'*) ok=true;; *) ok=false;; esac
  fi

  if [ "$ok" = "true" ]; then
    # 4) SUCCESS → export CLOUDFLARE_* for the caller (wrangler/SDK).
    export CLOUDFLARE_API_TOKEN="$TOKEN"
    [ -n "$ACCT" ] && export CLOUDFLARE_ACCOUNT_ID="$ACCT"
    if [ "$VERBOSE" = "1" ]; then
      echo "cf_preflight: OK — CF auth verified BY-EFFECT (GET /user/tokens/verify -> success:true)"
      echo "cf_preflight: resolved CLOUDFLARE_API_TOKEN  <= source var: ${TOKEN_SRC}"
      if [ -n "$ACCT" ]; then
        echo "cf_preflight: resolved CLOUDFLARE_ACCOUNT_ID <= source var: ${ACCT_SRC}"
      else
        echo "cf_preflight: WARN — no account-id var found (token still valid; some ops need it)"
      fi
    fi
    if [ "${_cfpf_sourced}" = "1" ]; then return 0; else exit 0; fi
  else
    # 5) FAIL-CLOSED → the probe genuinely returned false. Only NOW may we say blocked.
    local reason=""
    if command -v jq >/dev/null 2>&1; then
      reason="$(printf '%s' "$body" | jq -r '.errors[0].message // empty' 2>/dev/null)"
    fi
    _cfpf_die 5 "CF token from '${TOKEN_SRC}' FAILED live verify (http=${http}${reason:+, error=$reason}). Token present but NOT authenticating."
    return $?
  fi
}

_cfpf_main "$@"
_cfpf_rc=$?
# Clean up helper state so sourcing doesn't leak into caller namespace beyond exports.
unset -f _cfpf_main _cfpf_die 2>/dev/null || true
if [ "${_cfpf_sourced}" = "1" ]; then
  unset _cfpf_sourced
  return $_cfpf_rc 2>/dev/null || true
fi
