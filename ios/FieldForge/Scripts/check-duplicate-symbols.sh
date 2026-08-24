#!/bin/bash
#
# check-duplicate-symbols.sh
#
# Finds the "defined twice" and "referenced but never defined" breakages that
# come from a local tree drifting away from the branch.
#
# Background: commit 81a8ebd added calls to PaymentGatewayRegistry's
# applyStripeSettings() and defaultMerchantIdentifier without ever committing
# their definitions, so a Mac that builds must be carrying an uncommitted copy.
# Commit 87f1783 added the real definitions to the branch. Both present at once
# is an "invalid redeclaration" build failure.
#
# Reports only. It never edits or deletes anything — uncommitted work is yours
# to keep or discard, and some of it may be unrelated to the duplicate.
#
# Run from anywhere:
#     bash ios/FieldForge/Scripts/check-duplicate-symbols.sh
#
# Exits 0 when the tree is clean, 1 when something needs your attention.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

FAILURES=0
note()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
pass()  { printf '  \033[32mok\033[0m    %s\n' "$1"; }
fail()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# Every definition below must appear exactly once in the tree.
#   label | expected count | ripgrep-free grep pattern
expect_once() {
  local label="$1" pattern="$2"
  local hits
  hits="$(grep -rn --include=*.swift -e "$pattern" . 2>/dev/null)"
  local count
  count="$(printf '%s' "$hits" | grep -c . )"
  if [ "$count" -eq 1 ]; then
    pass "$label"
  else
    fail "$label — found $count, expected 1"
    printf '%s\n' "$hits" | sed 's/^/          /'
  fi
}

note "1. Single definition of each shared payment symbol"
# The registry's own constant is the one assigned a string literal.
# StripePaymentSettings.defaultMerchantIdentifier aliases it and is legitimate.
expect_once "PaymentGatewayRegistry.defaultMerchantIdentifier" \
            'static let defaultMerchantIdentifier = "'
expect_once "applyStripeSettings()"          'func applyStripeSettings'
expect_once "final class PaymentGatewayRegistry" 'final class PaymentGatewayRegistry'
expect_once "PaymentGatewayRegistry.shared"  'static let shared = PaymentGatewayRegistry()'
expect_once "struct SimulatedProcessorGateway"  'struct SimulatedProcessorGateway'
expect_once "struct StripePaymentIntentGateway" 'struct StripePaymentIntentGateway'
expect_once "struct ProcessorChargeResult"      'struct ProcessorChargeResult'
expect_once "enum ProcessorError"               'enum ProcessorError'

note "2. Files the branch does not know about"
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  UNTRACKED="$(git ls-files --others --exclude-standard -- . | grep '\.swift$')"
  MODIFIED="$(git diff --name-only -- . | grep '\.swift$')"
  if [ -z "$UNTRACKED" ] && [ -z "$MODIFIED" ]; then
    pass "no untracked or modified Swift files"
  else
    [ -n "$UNTRACKED" ] && {
      fail "untracked Swift files — a duplicate definition most likely lives here"
      printf '%s\n' "$UNTRACKED" | sed 's/^/          /'
    }
    [ -n "$MODIFIED" ] && {
      printf '  \033[33mnote\033[0m  modified Swift files (review before discarding):\n'
      printf '%s\n' "$MODIFIED" | sed 's/^/          /'
    }
  fi
else
  printf '  \033[33mnote\033[0m  not a git checkout; skipping\n'
fi

note "3. No Stripe Terminal call may run on the main thread"
# A Cancelable.cancel on the main actor is what froze the UI on the Cancel tap:
# tearing down a live reader session blocks, and a blocked main thread cannot
# re-render the overlay away. Every such call must sit inside TerminalQueue.
TERMINAL_FILE="FieldForge/Payments/StripeTerminalTapToPayBackend.swift"
if [ -f "$TERMINAL_FILE" ]; then
  STRAY="$(grep -n '\.cancel { _ in }' "$TERMINAL_FILE" | grep -v 'TerminalQueue.detach')"
  if [ -z "$STRAY" ]; then
    pass "every Cancelable.cancel is dispatched to TerminalQueue"
  else
    fail "Cancelable.cancel outside TerminalQueue — this is the freeze"
    printf '%s\n' "$STRAY" | sed 's/^/          /'
  fi
  if grep -q 'func cancelTapToPay()' FieldForge/Payments/PaymentCoordinator.swift 2>/dev/null; then
    pass "cancelTapToPay is synchronous (cannot await Stripe)"
  else
    fail "cancelTapToPay is no longer synchronous — Cancel may await Stripe"
  fi
else
  printf '  \033[33mnote\033[0m  Terminal backend not found; skipping\n'
fi

note "4. Secrets must never reach iOS"
SECRETS="$(grep -rn --include=*.swift --include=*.plist --include=*.entitlements --include=*.yml \
             -e 'sk_test_[A-Za-z0-9]\{8,\}' -e 'sk_live_' -e 'tml_[A-Za-z0-9]\{8,\}' . 2>/dev/null \
           | grep -v 'FieldForgeTests/')"
if [ -z "$SECRETS" ]; then
  pass "no sk_ or tml_ literals outside test fixtures"
else
  fail "secret-shaped literal in shipping code"
  printf '%s\n' "$SECRETS" | sed 's/^/          /'
fi

note "5. Staff Wallet stays out of capture"
if grep -q 'presentsStaffApplePayInCapture = false' FieldForge/Payments/PaymentCoordinator.swift 2>/dev/null; then
  pass "presentsStaffApplePayInCapture is false"
else
  fail "staff Apple Pay may be presented in capture"
fi

note "6. Tap to Pay still ships off"
if grep -q 'isTapToPayEnabled = defaults.bool(forKey: Keys.tapToPayEnabled)' \
     FieldForge/Payments/StripePaymentSettings.swift 2>/dev/null; then
  pass "absent key means off"
else
  fail "Tap to Pay default may no longer be off"
fi

if [ "$FAILURES" -eq 0 ]; then
  printf '\n\033[32mClean.\033[0m Safe to xcodegen generate and build.\n\n'
  exit 0
fi

cat <<'EOF'

Resolving a duplicate
---------------------
The branch's definitions live in FieldForge/Payments/PaymentProcessorGateway.swift
(defaultMerchantIdentifier and applyStripeSettings, in the extension at the
bottom). Keep those and remove the local copy:

  * If the copy is in an untracked file that holds nothing else, delete it.
  * If the copy is an edit to a tracked file, look at the diff first —
        git diff -- FieldForge/Payments/PaymentProcessorGateway.swift
    then drop only the duplicated declarations, or take the branch's whole
    version with
        git checkout -- FieldForge/Payments/PaymentProcessorGateway.swift
    once you are sure nothing else in that file is worth keeping.

Then re-run this script, xcodegen generate, and build.
EOF
exit 1
