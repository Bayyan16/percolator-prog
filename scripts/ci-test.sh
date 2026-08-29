#!/usr/bin/env bash
# Run the wrapper test suite the way it actually has to be run.
#
# Three things this script exists to enforce:
#
#  1. --no-fail-fast. `cargo test` ABORTS at the first failing suite. Without this
#     flag the run stopped at v16_cu and never executed 17 of 25 suites, reporting
#     "137 passed / 11 failed" when the truth was 546 / 55. Any aggregate number
#     produced without --no-fail-fast is not a measurement.
#
#  2. Sibling program BPFs. The wrapper compiles the engine by path and mounts the
#     matcher / nft / stake .so files for its cross-program suites. Without them
#     v16_five_program_crosscut and v16_nft_e2e report 0 passing -- the whole
#     cross-program safety net silently does nothing. Building all four takes the
#     failure count from 86 to 55.
#
#  3. WHICH nft is mounted. See NFT_PIN below. This is not a detail: pinning the nft
#     sibling to a build that is not deployed is how the P5 nft regression became
#     invisible to a suite specifically written to catch cross-program breakage.
#
# Verdict rule: compare the failing set against tests/KNOWN_FAILING.txt.
#   - a NEW failure          -> RED (a regression)
#   - an allowlisted test that now PASSES -> RED (remove it from the list)
# Silence is never success here.
#
# ---------------------------------------------------------------------------------------
# NFT_PIN  (fix | deployed)   -- default: fix
#
#   fix       The nft sibling is f18da24, the unmerged branch carrying ce6b051 ("accept
#             wrapper VERSION 17") and 58911ab (allowlist the DhSkE7u wrapper). This is the
#             mix tests/KNOWN_FAILING.txt was MEASURED against (567 passed / 34 failed,
#             2026-08-23/26), so the rule is EXACT MATCH, unchanged from before.
#
#   deployed  The nft sibling is cf56ba5 = nft main = the bytes actually running on devnet.
#             That nft requires wrapper header VERSION 16 while the deployed wrapper stamps
#             17, and its fail-closed wrapper allowlist names FxfD37s..., not the live
#             DhSkE7u.... So it MUST produce failures the `fix` pin does not. The rule is:
#
#               - the failing set must be a SUPERSET of tests/KNOWN_FAILING.txt
#                 (nothing that passes under `fix` may be lost for an unrelated reason);
#               - there must be AT LEAST ONE extra failure -- otherwise either the nft was
#                 redeployed with the fixes (collapse the matrix back to one pin) or the
#                 crosscut suite has gone blind to the regression, and both need a human;
#               - every extra failure must come from a suite that actually mounts the nft
#                 .so, derived from the test sources below rather than hardcoded.
#
#             The extras are NOT added to tests/KNOWN_FAILING.txt. Allowlisting them is what
#             would re-hide the defect; the point is that CI asserts the defect is PRESENT
#             and VISIBLE, and goes red the moment that stops being true.
#
# No assertion in any test is relaxed, skipped or re-scoped by any of this.
# ---------------------------------------------------------------------------------------
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NFT_PIN="${NFT_PIN:-fix}"
case "$NFT_PIN" in
  fix|deployed) ;;
  *) echo "FATAL: NFT_PIN must be 'fix' or 'deployed', got '${NFT_PIN}'"; exit 1;;
esac

# --- PROOF OF LIFE: the nft sibling really is the ref this run claims -------------------
# Without this the matrix is decorative: if both legs silently checked out the same commit,
# the `deployed` leg's superset rule would be satisfied by the `fix` leg's own failures and
# the whole mechanism would pass while measuring nothing.
REFS_FILE="$ROOT/ci/deployed-refs.env"
[ -r "$REFS_FILE" ] || { echo "FATAL: $REFS_FILE missing"; exit 1; }
# shellcheck disable=SC1090
set -a; . "$REFS_FILE"; set +a
case "$NFT_PIN" in
  fix)      want_nft="$NFT_FIX";;
  deployed) want_nft="$NFT_DEPLOYED";;
esac
have_nft="$(git -C ../percolator-nft rev-parse HEAD 2>/dev/null || true)"
if [ -z "$have_nft" ]; then
  echo "FATAL: ../percolator-nft is not a git checkout — cannot verify which nft is mounted"; exit 1
fi
if [ "$have_nft" != "$want_nft" ]; then
  echo "FATAL: NFT_PIN=${NFT_PIN} expects nft ${want_nft} but ../percolator-nft is at ${have_nft}."
  echo "       Refusing to run: the verdict rules below are meaningless against the wrong sibling."
  exit 1
fi
echo "nft sibling verified: NFT_PIN=${NFT_PIN} -> ${have_nft}"

echo "::group::build sibling program BPFs"
for sib in percolator-match percolator-nft percolator-stake; do
  if [ -d "../$sib" ]; then
    ( cd "../$sib" && cargo build-sbf ) || { echo "FATAL: $sib BPF build failed"; exit 1; }
    echo "  built $sib"
  else
    echo "FATAL: ../$sib missing — the cross-program suites cannot run without it"; exit 1
  fi
done
echo "::endgroup::"

echo "::group::build wrapper BPF"
cargo build-sbf --no-default-features || exit 1
echo "::endgroup::"

echo "::group::cargo test --no-fail-fast"
cargo test --no-fail-fast 2>&1 | tee /tmp/ci_test.log | tail -40
echo "::endgroup::"

# Bare test names, as before, for the allowlist diff.
grep -E "^test [A-Za-z0-9_:]+ \.\.\. FAILED$" /tmp/ci_test.log | sed "s/^test //;s/ \.\.\. FAILED$//" | sort -u > /tmp/ci_failing.txt
# The same failures QUALIFIED by the suite they came from. `cargo test` prints the test name
# alone, so the owning binary has to be tracked from the preceding "Running tests/<x>.rs" line.
awk '
  /^[[:space:]]*Running /   { s=$0; sub(/^.*Running (unittests )?/,"",s); sub(/[[:space:]]*\(.*$/,"",s);
                              sub(/^tests\//,"",s); sub(/\.rs$/,"",s); suite=s; next }
  /^test .* \.\.\. FAILED$/ { n=$2; print suite "\t" n }
' /tmp/ci_test.log | sort -u > /tmp/ci_failing_qualified.txt
grep -vE "^\s*(#|$)" tests/KNOWN_FAILING.txt | sort -u > /tmp/ci_known.txt

passed=$(grep -E "^test result:" /tmp/ci_test.log | awk '{p+=$4} END{print p}')
failed=$(grep -E "^test result:" /tmp/ci_test.log | awk '{f+=$6} END{print f}')
echo "TOTALS: passed=$passed failed=$failed  (allowlisted: $(wc -l < /tmp/ci_known.txt))  NFT_PIN=$NFT_PIN"

# PROOF OF LIFE for the parsers: a `cargo test` output shape change would otherwise turn
# every comparison below into an empty-set comparison, i.e. a vacuous pass.
[ -n "${passed:-}" ] && [ "${passed:-0}" -gt 0 ] || { echo "::error::parsed 0 passing tests — the cargo output parser missed; every verdict below would be vacuous"; exit 1; }
if [ -s /tmp/ci_failing.txt ] && [ ! -s /tmp/ci_failing_qualified.txt ]; then
  echo "::error::failures were found but NONE could be attributed to a suite — the 'Running tests/<x>.rs' parser missed"; exit 1
fi

new_failures=$(comm -23 /tmp/ci_failing.txt /tmp/ci_known.txt)
now_passing=$(comm -13 /tmp/ci_failing.txt /tmp/ci_known.txt)

rc=0

if [ -n "$now_passing" ]; then
  echo "::error::allowlisted tests now PASS — remove them from tests/KNOWN_FAILING.txt:"
  echo "$now_passing" | sed 's/^/    /'
  rc=1
fi

if [ "$NFT_PIN" = "fix" ]; then
  if [ -n "$new_failures" ]; then
    echo "::error::NEW failures not in tests/KNOWN_FAILING.txt — this is a regression:"
    echo "$new_failures" | sed 's/^/    /'
    rc=1
  fi
  [ $rc -eq 0 ] && echo "OK: failing set matches the allowlist exactly (NFT_PIN=fix)"
else
  # Suites that actually mount the nft .so, derived from the sources so the list cannot rot.
  nft_suites=$(grep -ln 'nft_so_path\|assemble_five_program_svm\|percolator_nft\.so' tests/*.rs \
               | sed 's|^tests/||; s|\.rs$||' | sort -u)
  [ -n "$nft_suites" ] || { echo "::error::could not derive which suites mount the nft .so — the grep missed"; exit 1; }
  printf '%s\n' "$nft_suites" | grep -qx 'v16_nft_e2e' \
    || { echo "::error::derived nft-suite list does not contain v16_nft_e2e — the grep is wrong"; exit 1; }
  echo "suites that mount the nft .so:"; printf '%s\n' "$nft_suites" | sed 's/^/    /'

  extras=$(printf '%s\n' "$new_failures" | grep -v '^$' || true)
  n_extras=$(printf '%s\n' "$extras" | grep -c '[^[:space:]]')
  echo "extra failures vs the fix-pin baseline: ${n_extras}"
  [ "$n_extras" -gt 0 ] && printf '%s\n' "$extras" | sed 's/^/    /'

  if [ "$n_extras" -eq 0 ]; then
    echo "::error::NFT_PIN=deployed produced NO failures beyond the fix-pin allowlist."
    echo "    The nft on devnet (${NFT_DEPLOYED}) requires wrapper header VERSION 16 while the"
    echo "    deployed wrapper stamps 17, and its allowlist names a wrapper that is not live, so"
    echo "    the cross-program suites MUST notice. Either the nft was redeployed with the fixes"
    echo "    — in which case update ci/deployed-refs.env and collapse the nft_pin matrix back to"
    echo "    a single pin — or the crosscut suite has gone blind to it. Both need a human."
    rc=1
  fi

  # Every extra must be attributable to a suite that mounts the nft .so. An extra from
  # anywhere else is an unrelated regression wearing the nft regression's coat.
  misattributed=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    suite=$(awk -F'\t' -v n="$t" '$2==n {print $1}' /tmp/ci_failing_qualified.txt | head -1)
    if [ -z "$suite" ]; then
      misattributed="${misattributed}    ${t}  (NO SUITE — the qualified-failure parser missed)\n"
      continue
    fi
    printf '%s\n' "$nft_suites" | grep -qx "$suite" \
      || misattributed="${misattributed}    ${t}  (from ${suite}, which does not mount the nft .so)\n"
  done <<< "$extras"

  if [ -n "$misattributed" ]; then
    echo "::error::extra failures under NFT_PIN=deployed that are NOT nft fallout:"
    printf "%b" "$misattributed"
    echo "    These are ordinary regressions and must be fixed, not attributed to the nft pin."
    rc=1
  fi

  [ $rc -eq 0 ] && echo "OK: NFT_PIN=deployed is a strict superset of the allowlist, ${n_extras} extra failure(s), all from nft-mounting suites — the on-chain nft regression IS visible to CI"
fi

exit $rc
