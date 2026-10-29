#!/usr/bin/env bash
# fm-gh-account-lib.sh - the single owner of the opt-in per-owner GitHub account
# selection for firstmate's own gh and gh-axi calls: how config/gh-accounts is
# parsed, which login an owner maps to, and how one command runs as that login.
#
# docs/configuration.md "GitHub account per owner" owns the operator-facing
# contract. Loaded on first use by bin/fm-pr-lib.sh's fm_pr_gh_as, which the
# merge, PR-ready, merge-poll, contribution, state, reviewer, and teardown
# GitHub reads all call through. bin/fm-dod-lib.sh's fm_dod_gh_axi also reads
# the selection to render a worker's PR read-back and ready commands.
#
# gh can hold several logins for github.com but answers every command with the
# one active login, and a private repository is invisible to every other login:
# GitHub answers "Could not resolve to a Repository", never a permission error.
# config/gh-accounts maps a repository owner (user or organization) to the gh
# login that can see it, and fm_gh_as runs one command with GH_TOKEN set to that
# login's stored token in that command's environment alone. gh and gh-axi both
# honor GH_TOKEN ahead of the active login. The active account, the gh config,
# and git credentials are never changed, and the token is never printed, logged,
# written to a file, or passed as an argument.
#
# The mapping is opt-in: with no file, every command runs exactly as before. An
# owner the file does not name also runs unchanged on the active login. A
# present file must parse in full and a mapped login must yield a stored token;
# otherwise the command is refused with a reason naming the file, and nothing
# falls back to the active login, which could only answer "not found".
#
# File format: one "<owner> <login>" pair per line, separated by spaces or tabs.
# Blank lines and lines whose first non-blank character is # are ignored. An
# owner uses GitHub's owner alphabet (letters, digits, and single inner hyphens,
# at most 39 characters) and matches case-insensitively, as GitHub does; each
# owner may appear once. A login also allows underscores, as managed-user
# logins do, may not start with a hyphen, and is at most 100 characters. A final
# newline is optional; a CR or any other control byte except the tab separator
# is malformed.

FM_GH_ACCOUNT_LIB_DIR=$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "$d" && pwd)
FM_GH_ACCOUNT_HOST=github.com

# fm_gh_account_file
# Prints this home's mapping path: FM_CONFIG_OVERRIDE when set, else the
# home's config directory, falling back to the code root as every script does.
fm_gh_account_file() {
  if [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s/gh-accounts\n' "$FM_CONFIG_OVERRIDE"
    return 0
  fi
  printf '%s/config/gh-accounts\n' "${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_GH_ACCOUNT_LIB_DIR/..}}"
}

fm_gh_account_owner_valid() {  # <owner>
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 39 ] || return 1
  case "$1" in
    *[!A-Za-z0-9-]* | -* | *- | *--*) return 1 ;;
  esac
}

fm_gh_account_login_valid() {  # <login>
  [ "${#1}" -ge 1 ] && [ "${#1}" -le 100 ] || return 1
  case "$1" in
    *[!A-Za-z0-9_-]* | -*) return 1 ;;
  esac
}

fm_gh_account_lower() {  # <text>
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
}

# fm_gh_account_login <owner>
# Prints the gh login mapped for owner and returns 0. Returns 1 with no output
# when there is no mapping file or the file does not name owner. Returns 2 with
# the reason on stderr when the file is present but unreadable or malformed.
fm_gh_account_login() {
  local owner=$1 file line lineno=0 key login extra want found='' seen=' '
  file=$(fm_gh_account_file)
  [ -e "$file" ] || [ -L "$file" ] || return 1
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    printf 'error: GitHub account mapping %s is not a readable file\n' "$file" >&2
    return 2
  fi
  if LC_ALL=C tr -d '\t\n' < "$file" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    printf 'error: GitHub account mapping %s contains a control character such as a CR\n' "$file" >&2
    return 2
  fi
  want=$(fm_gh_account_lower "$owner")
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    key='' login='' extra=''
    read -r key login extra <<EOF
$line
EOF
    case "$key" in
      '' | '#'*) continue ;;
    esac
    if [ -z "$login" ] || [ -n "$extra" ] || ! fm_gh_account_owner_valid "$key" \
      || ! fm_gh_account_login_valid "$login"; then
      printf 'error: GitHub account mapping %s line %s is not "<owner> <login>"\n' "$file" "$lineno" >&2
      return 2
    fi
    key=$(fm_gh_account_lower "$key")
    case "$seen" in
      *" $key "*)
        printf 'error: GitHub account mapping %s names owner %s more than once\n' "$file" "$key" >&2
        return 2
        ;;
    esac
    seen="$seen$key "
    [ "$key" != "$want" ] || found=$login
  done < "$file"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# fm_gh_as <owner> <command> [args...]
# Runs command, normally gh or gh-axi, as the gh login mapped for owner and
# returns its status. An unmapped owner, or a home with no mapping file, runs
# command unchanged. An unusable mapping or a mapped login with no stored token
# refuses with status 1, runs nothing, and sets FM_GH_AS_REFUSED=1 so a caller
# can tell that refusal from command's own failure; every other outcome sets it
# to 0. The token reaches only command's environment; xtrace is suspended
# around it so a traced caller cannot print it.
FM_GH_AS_REFUSED=0
# shellcheck disable=SC2034  # FM_GH_AS_REFUSED is read by callers after it returns.
fm_gh_as() {
  local owner=$1 login rc=0 token xtrace=''
  shift
  FM_GH_AS_REFUSED=0
  login=$(fm_gh_account_login "$owner") || rc=$?
  case "$rc" in
    0) ;;
    1)
      "$@"
      return
      ;;
    *)
      printf 'error: refusing to run %s for GitHub owner %s on the active gh account while %s is unusable\n' \
        "${1:-a command}" "$owner" "$(fm_gh_account_file)" >&2
      FM_GH_AS_REFUSED=1
      return 1
      ;;
  esac
  case $- in *x*) xtrace=1; set +x ;; esac
  rc=0
  if ! token=$(env -u GH_TOKEN -u GITHUB_TOKEN \
    gh auth token --hostname "$FM_GH_ACCOUNT_HOST" --user "$login" 2>/dev/null) || [ -z "$token" ]; then
    token=''
    [ -z "$xtrace" ] || set -x
    printf 'error: gh login %s, mapped for GitHub owner %s in %s, has no stored token for %s; sign it in with gh auth login rather than switching the active account\n' \
      "$login" "$owner" "$(fm_gh_account_file)" "$FM_GH_ACCOUNT_HOST" >&2
    FM_GH_AS_REFUSED=1
    return 1
  fi
  GH_TOKEN=$token "$@" || rc=$?
  token=''
  [ -z "$xtrace" ] || set -x
  return "$rc"
}

# fm_gh_account_owner_from_remote <remote-url>
# Prints the owner of a github.com remote URL in the https, ssh, or scp-like
# form and returns 0; returns 1 for any other host or shape.
fm_gh_account_owner_from_remote() {
  local rest owner
  case "$1" in
    https://github.com/* | http://github.com/*) rest=${1#*://github.com/} ;;
    https://*@github.com/*) rest=${1#*@github.com/} ;;
    ssh://git@github.com/*) rest=${1#ssh://git@github.com/} ;;
    git@github.com:*) rest=${1#git@github.com:} ;;
    *) return 1 ;;
  esac
  owner=${rest%%/*}
  [ "$owner" != "$rest" ] || return 1
  fm_gh_account_owner_valid "$owner" || return 1
  printf '%s\n' "$owner"
}
