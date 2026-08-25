#!/usr/bin/env bash
# Installer logic tests: source bin/meeting-capture-install in lib-only mode
# with a stubbed `security` function, and pin the signing tri-state contract.
# Run via tests/run.sh (also run directly).
set -uo pipefail

pass=0
fail=0
check() { # check <description> <expected> <actual>
  if [[ $2 == "$3" ]]; then
    pass=$((pass + 1))
    printf 'ok %d - %s\n' "$((pass + fail))" "$1"
  else
    fail=$((fail + 1))
    printf 'not ok %d - %s\n     want: %s\n     got:  %s\n' "$((pass + fail))" "$1" "$2" "$3"
  fi
}

export MC_INSTALL_LIB_ONLY=1
source "$(dirname "$0")/../bin/meeting-capture-install"
unset MC_INSTALL_LIB_ONLY

# Stub the security binary as a bash function. Scenarios set SECURITY_RC and
# SECURITY_OUT before calling code under test.
SECURITY_RC=0
SECURITY_OUT=""
security() {
  local out="$SECURITY_OUT"
  if [[ $SECURITY_RC -ne 0 ]]; then
    printf '%s\n' "error: cannot list code-signing identities" >&2
    return "$SECURITY_RC"
  fi
  printf '%s\n' "$out"
  return 0
}

CERT_LINE="  1) valid identities present \"/Users/ephemeral/certs/meeting-capture-signing\""

# The sourced installer sets `set -euo pipefail`, so every failing command must
# be part of a ||-compound or subshell or it kills this whole script.

# --- list_signing_identities ---------------------------------------------

SECURITY_RC=0; SECURITY_OUT="keychain output"
out=$(list_signing_identities)
check "list passes keychain output through on success" "keychain output" "$out"

SECURITY_RC=36
rc=0; list_signing_identities >/dev/null 2>&1 || rc=$?
check "list propagates nonzero rc when the keychain is unreadable" "36" "$rc"

# --- signing_cert_exists tri-state ---------------------------------------

# 0 = certificate exists. 1 = lookup succeeded, certificate genuinely absent.
# 2 = keychain could not be consulted — NEVER treated as absent.
SECURITY_RC=0; SECURITY_OUT="$CERT_LINE"
rc=0; signing_cert_exists || rc=$?
check "tri-state 0: certificate exists" "0" "$rc"

SECURITY_RC=0; SECURITY_OUT="  1) valid identities present \"/tmp/other-identity\""
rc=0; signing_cert_exists || rc=$?
check "tri-state 1: lookup fine, cert absent" "1" "$rc"

SECURITY_RC=36
rc=0; signing_cert_exists >/dev/null 2>&1 || rc=$?
check "tri-state 2: unreadable keychain is its own state" "2" "$rc"

# --- find_sign_id ---------------------------------------------------------

# Explicit override wins without consulting the keychain at all.
MEETING_CAPTURE_SIGN_ID="Developer ID Application: Me"
out=$(find_sign_id)
check "override identity wins verbatim" "Developer ID Application: Me" "$out"
unset MEETING_CAPTURE_SIGN_ID

# Unreadable keychain must abort (exit 1), not silently fall back to ad-hoc:
# rebuilding ad-hoc would drop the Accessibility grant. find_sign_id calls
# exit(1) — run it in a subshell so our harness survives, and use an
# ||-compound because the sourced installer left `set -e` active.
SECURITY_RC=36
rc=0; out=$(find_sign_id 2>/dev/null) || rc=$?
check "unreadable keychain aborts with exit 1" "1" "$rc"
check "aborted lookup prints nothing as an id" "" "$out"

SECURITY_RC=0; SECURITY_OUT="$CERT_LINE"
out=$(find_sign_id)
check "matching certificate prints its name" "meeting-capture-signing" "$out"

SECURITY_RC=0; SECURITY_OUT='  1) valid identities present "/tmp/other"'
out=$(find_sign_id)
check "absent cert falls back to ad-hoc marker only after clean lookup" "-" "$out"

# --- Summary --------------------------------------------------------------

total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  echo "all $total assertions passed"
  exit 0
else
  echo "$fail/$total assertions FAILED"
  exit 1
fi
