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

# --- restart_agent --------------------------------------------------------
#
# `launchctl bootout` returns before the domain releases the label, so the
# bootstrap that follows used to fail with "Input/output error" and leave the
# daemon stopped — an installer that reports success while shipping nothing.
# Stub launchctl and sleep to drive the two races deterministically.

# Stub launchctl and sleep to drive the two races deterministically. State
# lives in files, not variables: restart_agent captures bootstrap's output in a
# command substitution, and a subshell's variable writes never come back.
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT
launchctl() {
  echo "$1" >> "$STUB_DIR/calls"
  local left
  case $1 in
    bootout) return 0 ;;
    print)
      left=$(cat "$STUB_DIR/print_hits")
      if [[ $left -gt 0 ]]; then echo $((left - 1)) > "$STUB_DIR/print_hits"; return 0; fi
      return 1 ;; # label is gone
    bootstrap)
      left=$(cat "$STUB_DIR/bootstrap_failures")
      if [[ $left -gt 0 ]]; then
        echo $((left - 1)) > "$STUB_DIR/bootstrap_failures"
        echo "Bootstrap failed: 5: Input/output error" >&2
        return 5
      fi
      return 0 ;;
  esac
}
sleep() { echo x >> "$STUB_DIR/slept"; }
count_calls() { grep -c "^$1$" "$STUB_DIR/calls" 2>/dev/null || echo 0; }
count_sleeps() { wc -l < "$STUB_DIR/slept" | tr -d ' '; }
reset_launchctl() { # reset_launchctl <print_hits> <bootstrap_failures>
  : > "$STUB_DIR/calls"; : > "$STUB_DIR/slept"
  echo "${1:-0}" > "$STUB_DIR/print_hits"
  echo "${2:-0}" > "$STUB_DIR/bootstrap_failures"
}

# Clean case: label already gone, bootstrap takes on the first try.
reset_launchctl 0 0
rc=0; restart_agent "gui/501" "com.example.agent" "/tmp/agent.plist" || rc=$?
check "clean restart succeeds" "0" "$rc"
check "clean restart bootstraps exactly once" "1" "$(count_calls bootstrap)"
check "clean restart does not wait" "0" "$(count_sleeps)"

# The teardown race: the label lingers in the domain for a few polls.
reset_launchctl 3 0
rc=0; restart_agent "gui/501" "com.example.agent" "/tmp/agent.plist" || rc=$?
check "lingering label is waited out, not bootstrapped over" "0" "$rc"
check "waiting polls until the label leaves the domain" "4" "$(count_calls print)"
check "each poll pauses" "3" "$(count_sleeps)"

# The residual race: bootstrap itself fails twice, then lands.
reset_launchctl 0 2
rc=0; restart_agent "gui/501" "com.example.agent" "/tmp/agent.plist" || rc=$?
check "a losing bootstrap is retried rather than reported as installed" "0" "$rc"
check "retries stop as soon as one succeeds" "3" "$(count_calls bootstrap)"

# Persistent failure must be loud and nonzero: silence here is how a fixed
# build never reaches the meeting.
reset_launchctl 0 99
rc=0; err=$(restart_agent "gui/501" "com.example.agent" "/tmp/agent.plist" 2>&1) || rc=$?
check "a daemon that will not start fails the install" "1" "$rc"
check "bootstrap is not retried forever" "5" "$(count_calls bootstrap)"
check "the launchctl diagnostic is surfaced" "0" \
  "$(case $err in *"Input/output error"*) echo 0 ;; *) echo "missing: $err" ;; esac)"

unset -f launchctl sleep

# --- Summary --------------------------------------------------------------

total=$((pass + fail))
if [[ $fail -eq 0 ]]; then
  echo "all $total assertions passed"
  exit 0
else
  echo "$fail/$total assertions FAILED"
  exit 1
fi
