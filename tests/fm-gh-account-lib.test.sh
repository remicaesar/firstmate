#!/usr/bin/env bash
# Behavioral tests for bin/fm-gh-account-lib.sh: config/gh-accounts selects the
# gh login per GitHub owner, an absent file leaves every command as it was, an
# unusable mapping refuses instead of falling back to the active login, and no
# token ever reaches output.
# shellcheck disable=SC2016  # Each in_home snippet expands inside the shell that sources the library.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-gh-account-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-gh-account-lib-tests)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
BASE_PATH=$PATH

# The fake gh stores one token per signed-in login, named after the login so a
# case can tell which login a command carried. Every call is logged as the
# GH_TOKEN it saw (or "none") followed by its arguments; that log is the only
# place a fake token is written, and it is test evidence, not output under test.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${GH_TOKEN:-none}" "$*" >> "$FM_TEST_GH_LOG"
if [ "${1:-} ${2:-}" = "auth token" ]; then
  user=
  while [ "$#" -gt 0 ]; do
    [ "$1" != --user ] || user=${2:-}
    shift
  done
  case " ${FM_TEST_SIGNED_IN:-} " in
    *" $user "*) printf 'fake-token-for-%s\n' "$user"; exit 0 ;;
  esac
  printf 'no oauth token found for github.com account %s\n' "$user" >&2
  exit 1
fi
case "$*" in
  "pr view "*" --json state,mergedAt,isDraft,headRefOid,author,mergeable,reviewDecision --jq "*)
    printf '%s\n' state=merged merged_at=2026-10-28T00:00:00Z draft=false \
      head=c2eac54c17a1ddc2633ad51b83e21e5fe888142e author=someone mergeability=unknown review_decision=
    ;;
  *) printf 'ran: %s\n' "$*" ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# new_home <name> [mapping-line]...: a home whose config holds those lines as
# config/gh-accounts, or no file when none are given.
new_home() {
  local home="$TMP_ROOT/$1"
  shift
  mkdir -p "$home/config"
  [ "$#" -eq 0 ] || printf '%s\n' "$@" > "$home/config/gh-accounts"
  : > "$home/gh.log"
  printf '%s\n' "$home"
}

# in_home <home> <shell snippet>: runs the snippet in bash with the library
# sourced for that home and the fake gh first on PATH.
in_home() {
  local home=$1
  shift
  FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" FM_TEST_SIGNED_IN="${FM_TEST_SIGNED_IN-alt work}" \
    PATH="$FAKEBIN:$BASE_PATH" bash -c '. "$1"; shift; eval "$1"' _ "$LIB" "$1"
}

assert_no_token_in() {  # <label> <text>...
  local label=$1
  shift
  case "$*" in
    *fake-token-for-*) fail "$label: a token reached output"$'\n'"$*" ;;
  esac
}

test_mapped_owner_runs_as_its_login() {
  local home out
  home=$(new_home mapped '# fleet accounts' '' 'RemiCaesar	alt' 'lovieco work')
  out=$(in_home "$home" 'fm_gh_as remicaesar gh pr view 1; fm_gh_as LovieCo gh api repos/lovieco/x' 2>&1) \
    || fail "mapped commands failed: $out"
  assert_grep 'fake-token-for-alt pr view 1' "$home/gh.log" "the remicaesar command did not carry the alt login"
  assert_grep 'fake-token-for-work api repos/lovieco/x' "$home/gh.log" "the lovieco command did not carry the work login"
  assert_grep 'none auth token --hostname github.com --user alt' "$home/gh.log" \
    "the token lookup did not name the mapped login on github.com"
  assert_no_token_in "mapped" "$out"
  pass "each mapped owner's command runs as that owner's login, matched case-insensitively"
}

test_unmapped_owner_and_absent_file_are_unchanged() {
  local home out
  home=$(new_home unmapped 'lovieco work')
  out=$(in_home "$home" 'fm_gh_as someone-else gh pr view 2; printf "rc=%s refused=%s\n" "$?" "$FM_GH_AS_REFUSED"') \
    || fail "unmapped command failed: $out"
  assert_contains "$out" 'rc=0 refused=0' "an unmapped owner did not run unchanged"
  assert_grep 'none pr view 2' "$home/gh.log" "an unmapped owner's command carried a token"
  assert_no_grep 'auth token' "$home/gh.log" "an unmapped owner looked up a token"

  home=$(new_home absent)
  out=$(in_home "$home" 'GH_TOKEN=ambient fm_gh_as remicaesar gh pr view 3; fm_gh_as remicaesar sh -c "exit 7"; printf "rc=%s\n" "$?"') \
    || fail "absent-file command failed: $out"
  assert_grep 'ambient pr view 3' "$home/gh.log" "an absent file changed the caller's own environment"
  assert_no_grep 'auth token' "$home/gh.log" "an absent file looked up a token"
  assert_contains "$out" 'rc=7' "an absent file did not return the command's own status"
  pass "an unmapped owner and an absent mapping run the command exactly as before"
}

test_mapped_status_and_ambient_token_handling() {
  local home out
  home=$(new_home status 'o alt')
  out=$(in_home "$home" 'GH_TOKEN=ambient GITHUB_TOKEN=ambient2 fm_gh_as o sh -c "printf \"%s\n\" \"\${GH_TOKEN:+set}\"; exit 5"; printf "rc=%s refused=%s after=%s\n" "$?" "$FM_GH_AS_REFUSED" "${GH_TOKEN:-unset}"') \
    || fail "status case failed: $out"
  assert_contains "$out" 'rc=5 refused=0 after=unset' "a mapped command's status or environment leaked past the call"
  assert_grep 'none auth token --hostname github.com --user alt' "$home/gh.log" \
    "the token lookup saw the caller's ambient GH_TOKEN"
  assert_no_token_in "status" "$out"
  pass "a mapped command keeps its own status and its token stays in that command alone"
}

test_signed_out_login_refuses_without_fallback() {
  local home out
  home=$(new_home signed-out 'o ghost')
  out=$(in_home "$home" 'fm_gh_as o gh pr view 4; printf "rc=%s refused=%s\n" "$?" "$FM_GH_AS_REFUSED"' 2>&1) \
    || fail "signed-out case failed: $out"
  assert_contains "$out" 'rc=1 refused=1' "a signed-out login did not refuse"
  assert_contains "$out" 'gh login ghost, mapped for GitHub owner o' "the refusal did not name the login"
  assert_contains "$out" "$home/config/gh-accounts" "the refusal did not name the mapping file"
  assert_no_grep 'pr view 4' "$home/gh.log" "a signed-out login fell back to the active account"
  pass "a mapped login with no stored token refuses and never falls back to the active login"
}

test_malformed_mapping_refuses_every_owner() {
  local name line home out
  for name in three-fields bad-owner dash-login duplicate cr; do
    case "$name" in
      three-fields) line='o alt extra' ;;
      bad-owner) line='o_wner alt' ;;
      dash-login) line='o -alt' ;;
      duplicate) line=$'o alt\nO work' ;;
      cr) line=$'o alt\r' ;;
    esac
    home=$(new_home "malformed-$name" "$line")
    out=$(in_home "$home" 'fm_gh_as unrelated gh pr view 5; printf "rc=%s refused=%s\n" "$?" "$FM_GH_AS_REFUSED"' 2>&1) \
      || fail "$name: malformed case failed: $out"
    assert_contains "$out" 'rc=1 refused=1' "$name: a malformed mapping did not refuse"
    assert_contains "$out" "$home/config/gh-accounts" "$name: the refusal did not name the file"
    assert_no_grep 'pr view 5' "$home/gh.log" "$name: a malformed mapping ran the command"
  done
  pass "a malformed mapping refuses every GitHub command and names the file"
}

test_config_override_and_xtrace_keep_the_token_private() {
  local home out
  home=$(new_home override)
  mkdir -p "$home/other"
  printf 'o alt\n' > "$home/other/gh-accounts"
  out=$(FM_CONFIG_OVERRIDE="$home/other" in_home "$home" 'set -x; fm_gh_as o gh pr view 6; set +x' 2>&1) \
    || fail "override case failed: $out"
  assert_grep 'fake-token-for-alt pr view 6' "$home/gh.log" "FM_CONFIG_OVERRIDE did not select the mapping"
  assert_no_token_in "xtrace" "$out"
  pass "FM_CONFIG_OVERRIDE selects the mapping and a traced caller never prints the token"
}

test_owner_from_remote_forms() {
  local out
  out=$(in_home "$(new_home remotes)" '
    for u in https://github.com/RemiCaesar/qith.git git@github.com:remicaesar/qith.git \
      ssh://git@github.com/remicaesar/qith https://x-access-token@github.com/o/r \
      https://github.com/o/r/pull/9; do
      fm_gh_account_owner_from_remote "$u" || printf "none\n"
    done
    for u in https://gitlab.com/o/r git@example.com:o/r.git https://github.com/o; do
      fm_gh_account_owner_from_remote "$u" || printf "none\n"
    done') || fail "remote parsing failed: $out"
  assert_equals $'RemiCaesar\nremicaesar\nremicaesar\no\no\nnone\nnone\nnone' "$out" \
    "github.com remotes and PR URLs did not yield their owner"
  pass "a github.com remote or PR URL yields its owner and any other host yields none"
}

test_pr_state_reads_as_the_mapped_login() {
  local home out
  home=$(new_home pr-state 'o alt')
  out=$(FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" FM_TEST_SIGNED_IN=alt PATH="$FAKEBIN:$BASE_PATH" \
    "$ROOT/bin/fm-pr-state.sh" https://github.com/o/r/pull/7 2>&1) || fail "fm-pr-state.sh failed: $out"
  assert_contains "$out" 'STATE: merged at 2026-10-28T00:00:00Z' "fm-pr-state.sh did not read the pull request"
  assert_grep 'fake-token-for-alt pr view https://github.com/o/r/pull/7' "$home/gh.log" \
    "fm-pr-state.sh did not read as the mapped login"
  assert_no_token_in "pr-state" "$out"

  home=$(new_home pr-state-absent)
  out=$(FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" PATH="$FAKEBIN:$BASE_PATH" \
    "$ROOT/bin/fm-pr-state.sh" https://github.com/o/r/pull/7 2>&1) || fail "fm-pr-state.sh failed without a mapping: $out"
  assert_grep 'none pr view https://github.com/o/r/pull/7' "$home/gh.log" \
    "fm-pr-state.sh without a mapping did not read on the active login"
  assert_no_grep 'auth token' "$home/gh.log" "fm-pr-state.sh without a mapping looked up a token"
  pass "fm-pr-state.sh reads as the mapped login and is unchanged without a mapping"
}

failures=0
for test_name in test_mapped_owner_runs_as_its_login test_unmapped_owner_and_absent_file_are_unchanged \
  test_mapped_status_and_ambient_token_handling test_signed_out_login_refuses_without_fallback \
  test_malformed_mapping_refuses_every_owner test_config_override_and_xtrace_keep_the_token_private \
  test_owner_from_remote_forms test_pr_state_reads_as_the_mapped_login; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures GitHub account selection regressions"
