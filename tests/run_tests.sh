#!/usr/bin/env bash
# jq filters are single-quoted on purpose: their $vars are jq's, passed with --arg.
# shellcheck disable=SC2016
# Runs gh-pr-watcher against the fakes in tests/bin (gh, terminal-notifier, osascript, launchctl,
# sleep), placed first in PATH: no network, no auth, nothing touched outside a temp sandbox.
#
# Usage: tests/run_tests.sh [pattern]    only the tests whose name matches the pattern
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT="$TESTS_DIR/../gh-pr-watcher"
ORIG_PATH="$PATH"

# Fresh sandbox for each test: its own HOME, config, state, fixtures and call logs.
setup() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/gh-pr-watcher-test.XXXXXX")
  export HOME="$SANDBOX/home" XDG_CONFIG_HOME="$SANDBOX/config" XDG_STATE_HOME="$SANDBOX/state"
  export TMPDIR="$SANDBOX/tmp" FIXTURES="$SANDBOX/fixtures"
  export GH_CALLS="$SANDBOX/gh_calls" NOTIFY_CALLS="$SANDBOX/notify_calls" LAUNCHCTL_CALLS="$SANDBOX/launchctl_calls"
  export PATH="$TESTS_DIR/bin:$ORIG_PATH"
  unset GH_TOKEN GITHUB_TOKEN GH_HOST GH_ENTERPRISE_TOKEN NO_COLOR
  STATE_DIR="$XDG_STATE_HOME/gh-pr-watcher"
  mkdir -p "$HOME" "$TMPDIR" "$FIXTURES" "$XDG_CONFIG_HOME/gh-pr-watcher"
  : >"$GH_CALLS"; : >"$NOTIFY_CALLS"; : >"$LAUNCHCTL_CALLS"
  config
  fixture auth_status '{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com",
    "login":"ana","tokenSource":"keyring","scopes":"gist, read:org, repo","gitProtocol":"ssh"}]}}'
}

# config KEY=VALUE...: the config file, with the defaults for whatever is not passed.
config() { printf '%s\n' "$@" >"$XDG_CONFIG_HOME/gh-pr-watcher/config"; }

# Same key as the fake gh: anything outside [A-Za-z0-9._-] becomes "_".
fixture_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
fixture() { printf '%s\n' "$2" >"$FIXTURES/$(fixture_key "$1").json"; }
fixture_err() { printf '%s\n' "$2" >"$FIXTURES/$(fixture_key "$1").err"; }

# search_prs "o/r#N[ draft][ label:L]"...: the open PRs the search returns.
search_prs() { search_fixture search_prs "$@"; }

# author_prs LOGIN "o/r#N[ draft][ label:L]"...: the open PRs the search for LOGIN's PRs returns.
author_prs() {
  local login="$1"
  shift
  search_fixture "search_prs_author_$login" "$@"
}

search_fixture() {
  local key="$1" spec items='[]'
  shift
  for spec in "$@"; do
    items=$(jq --arg s "$spec" '($s | split(" ")) as $w | ($w[0] | split("#")) as $k | . + [{
      repository: {nameWithOwner: $k[0]}, number: ($k[1] | tonumber),
      isDraft: ($w | index("draft") != null),
      labels: [$w[] | select(startswith("label:")) | {name: .[6:]}],
      title: "PR \($k[1])", url: "https://github.com/\($k[0])/pull/\($k[1])"}]' <<<"$items")
  done
  fixture "$key" "$items"
}

# pr_view o/r#N MERGEABLE|CONFLICTING|UNKNOWN [call]: what gh pr view returns, on every call or
# only on that call number. The head is always ana:feat-N at sha head-N, over main.
pr_view() {
  local repo="${1%#*}" num="${1#*#}" key
  key="pr_view_${repo}_$num"
  [ -n "${3:-}" ] && key="$key.$3"
  fixture "$key" "$(jq -n --arg r "$repo" --argjson n "$num" --arg m "$2" '{
    mergeable: $m, headRefOid: "head-\($n)", headRefName: "feat-\($n)",
    headRepositoryOwner: {login: "ana"}, baseRefName: "main",
    url: "https://github.com/\($r)/pull/\($n)", title: "PR \($n)", createdAt: (now - 7200 | todate),
    reviewDecision: "", latestReviews: [], reviews: [], statusCheckRollup: []}')"
}

# patch_view o/r#N CALL|"" JQ [jq args...]: edits what gh pr view returns, on every call or only
# on that call number (starting from the every-call answer). Goes after pr or pr_view.
patch_view() {
  local repo="${1%#*}" num="${1#*#}" call="$2" filter="$3" base f
  shift 3
  base="$FIXTURES/$(fixture_key "pr_view_${repo}_$num")"
  f="$base.json"
  if [ -n "$call" ]; then
    f="$base.$call.json"
    [ -f "$f" ] || cp "$base.json" "$f"
  fi
  jq "$@" "$filter" "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

# review o/r#N DECISION [REVIEWER] [call]: the PR's reviewDecision, with REVIEWER's latest review
# in that state.
review() {
  patch_view "$1" "${4:-}" '.reviewDecision = $d
    | .latestReviews = (if $by == "" then [] else [{author: {login: $by}, state: $d}] end)' \
    --arg d "$2" --arg by "${3:-}"
}

# head_at o/r#N SHA CALL: the head the PR has on that call.
head_at() { patch_view "$1" "$3" '.headRefOid = $s' --arg s "$2"; }

# checks o/r#N CALL "name:CONCLUSION"...: the head's checks on that call; IN_PROGRESS = still running.
checks() {
  local pr="$1" call="$2" rollup
  shift 2
  rollup=$(printf '%s\n' "$@" | jq -R 'split(":") | {__typename: "CheckRun", name: .[0], workflowName: "ci",
    status: (if .[1] == "IN_PROGRESS" then "IN_PROGRESS" else "COMPLETED" end),
    conclusion: (if .[1] == "IN_PROGRESS" then "" else .[1] end)}' | jq -s .)
  patch_view "$pr" "$call" '.statusCheckRollup = $r' --argjson r "$rollup"
}

# approvable o/r#N AUTHOR: AUTHOR's PR with passing checks, which GitHub accepts approving.
approvable() {
  local repo="${1%#*}" num="${1#*#}"
  pr_view "$1" MERGEABLE
  patch_view "$1" "" '.author = {login: $a}' --arg a "$2"
  checks "$1" '' 'test:SUCCESS'
  fixture "api_POST_repos/$repo/pulls/$num/reviews" '{"state": "APPROVED"}'
}

# my_reviews o/r#N STATE...: ana's reviews on the PR, oldest first, after one from another reviewer.
my_reviews() {
  local pr="$1"
  shift
  patch_view "$pr" "" '.reviews = [{author: {login: "carol"}, state: "APPROVED", submittedAt: "2026-01-01T00:00:00Z"}]
    + ($s | to_entries | map({author: {login: "ana"}, state: .value,
        submittedAt: "2026-01-0\(.key + 2)T00:00:00Z"}))' --argjson s "$(printf '%s\n' "$@" | jq -R . | jq -s .)"
}

today_plus() { date -v+"$1"d +%F 2>/dev/null || date -d "+$1 days" +%F; }

# commit o/r SHA PARENT...: the commit, as gh api repos/o/r/commits/SHA returns it.
commit() {
  local repo="$1" sha="$2"
  shift 2
  fixture "api_GET_repos/$repo/commits/$sha" "$(printf '%s\n' "$@" | jq -R '{sha: .}' | jq -s --arg s "$sha" '{sha: $s, parents: .}')"
}

# behind o/r#N COMMITS [call]: how far the head is behind main, on every call or only on that one.
behind() {
  local repo="${1%#*}" num="${1#*#}" key
  key="api_GET_repos/$repo/compare/main...ana:feat-$num"
  [ -n "${3:-}" ] && key="$key.$3"
  fixture "$key" "{\"behind_by\": $2, \"ahead_by\": 1}"
}

# pr o/r#N MERGEABLE|CONFLICTING|UNKNOWN COMMITS_BEHIND: a PR GitHub accepts updating.
pr() {
  local repo="${1%#*}" num="${1#*#}"
  pr_view "$1" "$2"
  behind "$1" "$3"
  fixture "api_PUT_repos/$repo/pulls/$num/update-branch" '{"message": "Updating pull request branch."}'
}

# age SECONDS: moves the saved conflicts and the last reminder that far into the past, as if
# that much time had gone by since the previous run.
age() {
  local f
  for f in conflicts.json conflicts_reminded.json; do
    [ -s "$STATE_DIR/$f" ] || continue
    jq --argjson s "$1" 'if type == "array" then map(.since -= $s) else .at -= $s end' "$STATE_DIR/$f" >"$STATE_DIR/$f.tmp"
    mv "$STATE_DIR/$f.tmp" "$STATE_DIR/$f"
  done
}

# Runs the script; its output lands in $SANDBOX/out and the exit code in RC.
watcher() {
  bash "$SCRIPT" "$@" >"$SANDBOX/out" 2>&1
  RC=$?
}

# A test passes when it prints nothing: each failed assertion prints one line.
fail() { printf '    ✗ %s\n' "$*"; }

assert_rc() { [ "$RC" = "$1" ] || fail "exit code $RC, expected $1"; }

# assert_has FILE ERE [N]: some line matches (exactly N lines, if N is given).
assert_has() {
  local n
  n=$(grep -cE -- "$2" "$1" 2>/dev/null) || n=0
  if [ -n "${3:-}" ]; then
    [ "$n" = "$3" ] || fail "$(basename "$1"): $n line(s) match /$2/, expected $3"
  else
    [ "$n" -gt 0 ] || fail "$(basename "$1"): no line matches /$2/"
  fi
}
assert_lacks() { assert_has "$1" "$2" 0; }
# assert_notified N: notifications sent (a -remove only takes one down).
assert_notified() { assert_has "$NOTIFY_CALLS" '^-title |^osascript ' "$1"; }
assert_log() { assert_has "$STATE_DIR/watcher.log" "$@"; }

assert_file() { [ -f "$1" ] || fail "missing $(basename "$1")"; }
assert_no_file() { [ ! -e "$1" ] || fail "$(basename "$1") should not exist"; }

# assert_json FILE FILTER: the jq filter is true on the file.
assert_json() {
  jq -e "$2" "$1" >/dev/null 2>&1 || fail "$(basename "$1") doesn't satisfy $2 ($(tr -d '\n' <"$1" 2>/dev/null | cut -c1-200))"
}

# ── run: updating branches ─────────────────────────────────────────────────────────────────────

test_behind_pr_gets_updated_with_its_head_sha() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 3
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" '^api -X PUT repos/acme/api/pulls/7/update-branch -f expected_head_sha=head-7$' 1
  assert_log 'acme/api#7: 3 behind → branch updated from main'
  assert_json "$STATE_DIR/state.json" '.["acme/api#7"] == "MERGEABLE"'
  assert_notified 0
}

test_up_to_date_pr_is_left_alone() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 0
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" 'update-branch'
  assert_log 'acme/api#7: up to date'
}

test_rejected_update_waits_for_next_run() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 2
  rm "$FIXTURES/$(fixture_key api_PUT_repos/acme/api/pulls/7/update-branch).json"
  fixture_err api_PUT_repos/acme/api/pulls/7/update-branch 'gh: expected head sha didn'"'"'t match current head ref. (HTTP 422)'
  watcher run
  assert_rc 0
  assert_log 'acme/api#7: 2 behind, not updated: .*HTTP 422'
  assert_no_file "$STATE_DIR/last_error"
  assert_notified 0
}

# ── run: conflicts ─────────────────────────────────────────────────────────────────────────────

test_conflict_notifies_once_and_is_saved() {
  search_prs 'acme/api#8'
  pr 'acme/api#8' CONFLICTING 5
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" 'update-branch'
  assert_has "$NOTIFY_CALLS" '-subtitle api#8 · conflict needs attention .*-open https://github.com/acme/api/pull/8 ' 1
  assert_has "$NOTIFY_CALLS" '-group gh-pr-watcher-conflicts' 1
  assert_json "$STATE_DIR/conflicts.json" 'length == 1 and .[0].key == "acme/api#8" and .[0].behind == "5"'
  assert_json "$STATE_DIR/state.json" '.["acme/api#8"] == "CONFLICTING"'

  # Within the hour, a conflict already notified is not notified again.
  age 600
  watcher run
  assert_notified 1
  assert_log 'acme/api#8: still conflicting'
  assert_log '1 PR\(s\) still conflicting, already reminded'

  # After an hour, it is reminded.
  age 3000
  watcher run
  assert_notified 2
  assert_has "$NOTIFY_CALLS" '-subtitle api#8 · still conflicting since [0-9]{2}:[0-9]{2} ' 1
}

test_several_conflicts_share_one_notification_and_page() {
  search_prs 'acme/api#8' 'acme/web#9'
  pr 'acme/api#8' CONFLICTING 5
  pr 'acme/web#9' CONFLICTING 1
  watcher run
  assert_rc 0
  assert_has "$NOTIFY_CALLS" "-subtitle 2 PRs with conflicts \(2 new\) -message api#8, web#9 -open file://$STATE_DIR/conflicts.html" 1
  assert_has "$STATE_DIR/conflicts.html" 'href="https://github.com/acme/api/pull/8"'
  assert_has "$STATE_DIR/conflicts.html" 'href="https://github.com/acme/web/pull/9"'
}

test_resolved_conflict_removes_the_notification() {
  search_prs 'acme/api#8'
  pr 'acme/api#8' MERGEABLE 0
  pr_view 'acme/api#8' CONFLICTING 1
  watcher run
  assert_has "$NOTIFY_CALLS" 'conflict needs attention' 1
  watcher run
  assert_rc 0
  assert_log 'acme/api#8: conflict resolved'
  assert_has "$NOTIFY_CALLS" '^-remove gh-pr-watcher-conflicts$' 1
  assert_json "$STATE_DIR/conflicts.json" 'length == 0'
  assert_no_file "$STATE_DIR/conflicts_reminded.json"
}

# ── run: mergeable still being computed ────────────────────────────────────────────────────────

test_unknown_mergeable_is_retried_then_skipped() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' UNKNOWN 3
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" '^pr view 7 -R acme/api ' 4
  assert_lacks "$GH_CALLS" 'update-branch'
  assert_log 'acme/api#7: GitHub is still computing mergeable \(UNKNOWN\), skipping this run'
  assert_json "$STATE_DIR/state.json" 'has("acme/api#7") | not'
}

test_unknown_mergeable_resolved_on_a_retry() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 3
  pr_view 'acme/api#7' UNKNOWN 1
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" '^pr view 7 -R acme/api ' 2
  assert_has "$GH_CALLS" 'update-branch -f expected_head_sha=head-7$' 1
}

test_unknown_mergeable_keeps_a_known_conflict() {
  search_prs 'acme/api#8'
  pr 'acme/api#8' UNKNOWN 5
  pr_view 'acme/api#8' CONFLICTING 1
  watcher run
  age 600
  watcher run
  assert_rc 0
  assert_json "$STATE_DIR/state.json" '.["acme/api#8"] == "CONFLICTING"'
  assert_json "$STATE_DIR/conflicts.json" 'length == 1 and .[0].key == "acme/api#8"'
  assert_notified 1
}

# ── run: what is left alone ────────────────────────────────────────────────────────────────────

test_drafts_and_skip_label_are_untouched() {
  config SKIP_LABEL=no-autoupdate
  search_prs 'acme/api#1 draft' 'acme/api#2 label:no-autoupdate' 'acme/api#3'
  pr 'acme/api#1' MERGEABLE 4
  pr 'acme/api#2' MERGEABLE 4
  pr 'acme/api#3' MERGEABLE 0
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" '^pr view (1|2) '
  assert_lacks "$GH_CALLS" 'update-branch'
  assert_log 'acme/api#1: draft, left alone'
  assert_log 'acme/api#2: label no-autoupdate, left alone'
  assert_log 'acme/api#3: up to date'
}

test_drafts_are_updated_with_include_drafts() {
  config INCLUDE_DRAFTS=true
  search_prs 'acme/api#1 draft'
  pr 'acme/api#1' MERGEABLE 4
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" 'pulls/1/update-branch' 1
}

test_search_uses_owners_or_repos() {
  config 'OWNERS=acme beta'
  search_prs
  watcher run
  assert_has "$GH_CALLS" '^search prs .* --owner acme --owner beta$' 1
  assert_log 'no open PRs'

  config 'OWNERS=acme' 'REPOS=acme/api beta/web'
  watcher run
  assert_has "$GH_CALLS" '^search prs .* --repo acme/api --repo beta/web$' 1
  assert_lacks "$GH_CALLS" '^search prs .*--owner acme$'
}

# ── run: reviews that request changes ──────────────────────────────────────────────────────────

test_changes_requested_notifies_once() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 0
  review 'acme/api#7' CHANGES_REQUESTED bob
  watcher run
  assert_rc 0
  assert_has "$NOTIFY_CALLS" '-subtitle api#7 · changes requested -message PR 7 · by bob -open https://github.com/acme/api/pull/7 .*-group gh-pr-watcher-changes' 1
  assert_log 'acme/api#7: changes requested by bob'
  assert_json "$STATE_DIR/changes_requested.json" 'length == 1 and .[0].key == "acme/api#7" and .[0].by == "bob"'

  age 3600
  watcher run
  assert_notified 1
  watcher status --json
  assert_json "$SANDBOX/out" '.changes_requested[0].key == "acme/api#7" and .config.values.NOTIFY_CHANGES_REQUESTED == true'
}

test_changes_requested_on_several_prs_share_a_page() {
  search_prs 'acme/api#7' 'acme/web#9'
  pr 'acme/api#7' MERGEABLE 0
  pr 'acme/web#9' CONFLICTING 2
  review 'acme/api#7' CHANGES_REQUESTED bob
  review 'acme/web#9' CHANGES_REQUESTED carol
  watcher run
  assert_rc 0
  assert_has "$NOTIFY_CALLS" "-subtitle 2 PRs with changes requested -message api#7, web#9 -open file://$STATE_DIR/changes_requested.html" 1
  assert_has "$STATE_DIR/changes_requested.html" 'changes requested by carol'
  # The conflict keeps its own notification.
  assert_has "$NOTIFY_CALLS" '-subtitle web#9 · conflict needs attention' 1
}

test_changes_requested_again_after_approval_notifies_again() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 0
  review 'acme/api#7' CHANGES_REQUESTED bob 1
  review 'acme/api#7' APPROVED bob 2
  review 'acme/api#7' CHANGES_REQUESTED carol 3
  watcher run
  watcher run
  assert_log 'acme/api#7: changes no longer requested'
  assert_json "$STATE_DIR/changes_requested.json" 'length == 0'
  watcher run
  assert_notified 2
  assert_has "$NOTIFY_CALLS" '-message PR 7 · by carol ' 1
}

test_changes_requested_kept_when_the_pr_cant_be_read() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 0
  review 'acme/api#7' CHANGES_REQUESTED bob 1
  fixture_err pr_view_acme/api_7 'HTTP 502: Bad Gateway'
  rm "$FIXTURES/$(fixture_key pr_view_acme/api_7).json"
  watcher run
  watcher run
  assert_log 'acme/api#7: could not read the PR'
  assert_json "$STATE_DIR/changes_requested.json" 'length == 1'
  assert_notified 1
}

test_changes_requested_not_notified_when_off() {
  config NOTIFY_CHANGES_REQUESTED=false
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 0
  review 'acme/api#7' CHANGES_REQUESTED bob
  watcher run
  assert_rc 0
  assert_notified 0
  assert_log '1 PR\(s\) with changes requested, not notified \(NOTIFY_CHANGES_REQUESTED=false\)'
  assert_json "$STATE_DIR/changes_requested.json" 'length == 1'
}

test_notify_changes_requested_config_and_flags() {
  watcher install --dry-run --no-notify-changes-requested
  assert_rc 0
  assert_has "$SANDBOX/out" '^NOTIFY_CHANGES_REQUESTED=false$' 1
  watcher install --dry-run --notify-changes-requested
  assert_has "$SANDBOX/out" '^NOTIFY_CHANGES_REQUESTED=true$' 1

  config NOTIFY_CHANGES_REQUESTED=maybe
  watcher run
  assert_rc 1
  assert_log 'NOTIFY_CHANGES_REQUESTED must be true or false'

  config NOTIFY_CHANGES_REQUESTED=false
  watcher doctor --json
  assert_json "$SANDBOX/out" '.checks[] | select(.id == "notifications") | .message == "notifies: conflicts"'
}

# ── run: CI failing after an update ────────────────────────────────────────────────────────────

# A PR behind on the first run, updated by the watcher into merge-N (parents head-N and main).
updated_pr() {
  local repo="${1%#*}" num="${1#*#}"
  pr "$1" MERGEABLE 0
  behind "$1" 3 1
  head_at "$1" "merge-$num" 2
  commit "$repo" "merge-$num" "head-$num" main-sha
  patch_view "$1" "" '.headRefOid = $s' --arg s "merge-$num"
  patch_view "$1" 1 '.headRefOid = "head-\(.title | ltrimstr("PR "))"'
}

test_ci_failure_on_the_watchers_update_notifies_once() {
  config NOTIFY_CI_FAILED=true
  search_prs 'acme/api#7'
  updated_pr 'acme/api#7'
  checks 'acme/api#7' 2 'lint:SUCCESS' 'test:FAILURE'
  checks 'acme/api#7' '' 'lint:SUCCESS' 'test:FAILURE'
  watcher run
  assert_json "$STATE_DIR/updates.json" '.["acme/api#7"].from == "head-7"'
  assert_notified 0
  watcher run
  assert_rc 0
  assert_log 'acme/api#7: CI failed on the watcher.s update \(test\)'
  assert_has "$NOTIFY_CALLS" '-subtitle api#7 · CI failed after the update -message PR 7 · failed: test -open https://github.com/acme/api/pull/7/checks .*-group gh-pr-watcher-ci' 1
  assert_json "$STATE_DIR/updates.json" '.["acme/api#7"].sha == "merge-7"'

  watcher run
  assert_notified 1
  assert_log 'CI still failing on the watcher.s update'
  watcher status --json
  assert_json "$SANDBOX/out" '.ci_failed == [{key: "acme/api#7", sha: "merge-7", failed: "test"}]'
}

test_ci_passing_on_the_watchers_update_is_quiet() {
  config NOTIFY_CI_FAILED=true
  search_prs 'acme/api#7'
  updated_pr 'acme/api#7'
  checks 'acme/api#7' 2 'lint:SUCCESS' 'test:IN_PROGRESS'
  checks 'acme/api#7' 3 'lint:SUCCESS' 'test:SUCCESS'
  watcher run
  watcher run
  assert_json "$STATE_DIR/updates.json" '.["acme/api#7"].sha == "merge-7"'
  watcher run
  assert_rc 0
  assert_log 'acme/api#7: CI passed on the watcher.s update'
  assert_json "$STATE_DIR/updates.json" '. == {}'
  assert_notified 0
}

test_ci_failure_after_your_own_push_is_not_notified() {
  config NOTIFY_CI_FAILED=true
  search_prs 'acme/api#7'
  updated_pr 'acme/api#7'
  # You pushed before GitHub merged: the new head is your commit, on top of the old one.
  head_at 'acme/api#7' mine-7 2
  patch_view 'acme/api#7' "" '.headRefOid = "mine-7"'
  commit acme/api mine-7 head-7
  checks 'acme/api#7' '' 'test:FAILURE'
  watcher run
  watcher run
  assert_log 'acme/api#7: the head moved by a push of yours'
  watcher run
  assert_notified 0
  assert_json "$STATE_DIR/updates.json" '. == {}'
}

test_ci_failure_after_a_push_on_top_is_not_notified() {
  config NOTIFY_CI_FAILED=true
  search_prs 'acme/api#7'
  updated_pr 'acme/api#7'
  checks 'acme/api#7' 2 'test:IN_PROGRESS'
  head_at 'acme/api#7' mine-7 3
  checks 'acme/api#7' 3 'test:FAILURE'
  watcher run
  watcher run
  watcher run
  assert_notified 0
  assert_json "$STATE_DIR/updates.json" '. == {}'
}

test_ci_failures_on_several_updates_share_a_page() {
  config NOTIFY_CI_FAILED=true
  search_prs 'acme/api#7' 'acme/web#9'
  updated_pr 'acme/api#7'
  updated_pr 'acme/web#9'
  checks 'acme/api#7' 2 'test:FAILURE'
  checks 'acme/web#9' 2 'build:TIMED_OUT'
  watcher run
  watcher run
  assert_has "$NOTIFY_CALLS" "-subtitle 2 PRs with CI failing after the update -message api#7, web#9 -open file://$STATE_DIR/ci_failed.html" 1
  assert_has "$STATE_DIR/ci_failed.html" 'failed: build · after merging main into it'
}

test_ci_failures_are_not_followed_by_default() {
  search_prs 'acme/api#7'
  updated_pr 'acme/api#7'
  checks 'acme/api#7' '' 'test:FAILURE'
  watcher run
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" '/commits/'
  assert_notified 0
  assert_json "$STATE_DIR/updates.json" '. == {}'
}

test_notify_ci_failed_config_and_flags() {
  watcher install --dry-run --notify-ci-failed
  assert_rc 0
  assert_has "$SANDBOX/out" '^NOTIFY_CI_FAILED=true$' 1
  config NOTIFY_CI_FAILED=yes
  watcher run
  assert_rc 1
  assert_log 'NOTIFY_CI_FAILED must be true or false'
  config NOTIFY_CI_FAILED=true
  watcher doctor --json
  assert_json "$SANDBOX/out" '.checks[] | select(.id == "notifications") | .message
    == "notifies: conflicts, reviews that request changes, CI failing after an update"'
}

# ── run: auto-approval ─────────────────────────────────────────────────────────────────────────

test_auto_approve_approves_a_ready_pr_of_an_author() {
  config 'AUTO_APPROVE_AUTHORS=bob' 'OWNERS=acme'
  search_prs
  author_prs bob 'acme/api#5'
  approvable 'acme/api#5' bob
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" '^search prs --author bob --state open .* --owner acme$' 1
  assert_has "$GH_CALLS" '^api -X POST repos/acme/api/pulls/5/reviews -f event=APPROVE -f commit_id=head-5$' 1
  assert_log 'acme/api#5: approved as ana \(by bob · PR 5\)'
  assert_json "$STATE_DIR/last_actions.json" '.prs["acme/api#5"] | startswith("approved as ana")'
  assert_notified 0
}

test_auto_approve_skips_drafts_and_skip_label() {
  config 'AUTO_APPROVE_AUTHORS=bob' INCLUDE_DRAFTS=true SKIP_LABEL=no-autoupdate
  search_prs
  author_prs bob 'acme/api#5 draft' 'acme/api#6 label:no-autoupdate'
  approvable 'acme/api#5' bob
  approvable 'acme/api#6' bob
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" '^pr view '
  assert_lacks "$GH_CALLS" '/reviews'
  assert_log 'acme/api#5: draft by bob, not approved'
  assert_log 'acme/api#6: label no-autoupdate, not approved'
}

test_auto_approve_skips_a_live_approval_and_approves_after_dismissal() {
  config 'AUTO_APPROVE_AUTHORS=bob'
  search_prs
  author_prs bob 'acme/api#5' 'acme/api#6' 'acme/api#7'
  approvable 'acme/api#5' bob
  approvable 'acme/api#6' bob
  approvable 'acme/api#7' bob
  my_reviews 'acme/api#5' CHANGES_REQUESTED APPROVED COMMENTED
  my_reviews 'acme/api#6' APPROVED DISMISSED
  my_reviews 'acme/api#7' APPROVED CHANGES_REQUESTED
  watcher run
  assert_rc 0
  assert_log 'acme/api#5: already approved by you'
  assert_lacks "$GH_CALLS" 'pulls/5/reviews'
  assert_has "$GH_CALLS" '^api -X POST repos/acme/api/pulls/6/reviews ' 1
  assert_has "$GH_CALLS" '^api -X POST repos/acme/api/pulls/7/reviews ' 1
}

test_auto_approve_waits_for_ci() {
  config 'AUTO_APPROVE_AUTHORS=bob'
  search_prs
  author_prs bob 'acme/api#5' 'acme/api#6' 'acme/api#7' 'acme/api#8' 'acme/api#9'
  local n
  for n in 5 6 7 8 9; do approvable "acme/api#$n" bob; done
  checks 'acme/api#5' '' 'lint:SUCCESS' 'test:IN_PROGRESS'
  checks 'acme/api#6' '' 'lint:SUCCESS' 'test:FAILURE'
  patch_view 'acme/api#7' '' '.statusCheckRollup = []'
  checks 'acme/api#8' '' 'lint:SUCCESS' 'test:CANCELLED'
  checks 'acme/api#9' '' 'lint:SUCCESS' 'docs:SKIPPED' 'bench:NEUTRAL'
  watcher run
  assert_rc 0
  assert_log 'acme/api#5: CI pending, not approved yet'
  assert_log 'acme/api#6: CI failing \(test\), not approved'
  assert_log 'acme/api#7: no checks yet, not approved'
  assert_log 'acme/api#8: CI failing \(test\), not approved'
  assert_lacks "$GH_CALLS" 'pulls/[5-8]/reviews'
  assert_has "$GH_CALLS" '^api -X POST repos/acme/api/pulls/9/reviews ' 1
}

test_auto_approve_without_require_ci_ignores_checks() {
  config 'AUTO_APPROVE_AUTHORS=bob' AUTO_APPROVE_REQUIRE_CI=false
  search_prs
  author_prs bob 'acme/api#5'
  approvable 'acme/api#5' bob
  checks 'acme/api#5' '' 'test:FAILURE'
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" '^api -X POST repos/acme/api/pulls/5/reviews ' 1
}

test_auto_approve_never_approves_your_own_prs() {
  config 'AUTO_APPROVE_AUTHORS=Ana bob'
  search_prs
  author_prs Ana 'acme/api#4'
  author_prs bob 'acme/api#5'
  approvable 'acme/api#4' ana
  # A result of bob's search that turns out to be yours.
  approvable 'acme/api#5' ana
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" '--author Ana'
  assert_lacks "$GH_CALLS" '/reviews'
}

test_auto_approve_expired_approves_nothing_and_logs_once() {
  config 'AUTO_APPROVE_AUTHORS=bob' AUTO_APPROVE_UNTIL=2000-01-01
  search_prs
  author_prs bob 'acme/api#5'
  approvable 'acme/api#5' bob
  watcher run --dry-run
  assert_no_file "$STATE_DIR/auto_approve_expired"
  watcher run
  watcher run
  assert_rc 0
  assert_lacks "$GH_CALLS" '--author bob'
  assert_lacks "$GH_CALLS" '/reviews'
  assert_log '^[0-9-]+ [0-9:]+ auto-approve expired on 2000-01-01$' 1
  watcher doctor --json
  assert_json "$SANDBOX/out" '.checks[] | select(.id == "auto_approve") | .status == "warn"
    and .message == "auto-approve ended on 2000-01-01" and (.fix | test("--auto-approve-for 1w"))'
}

test_auto_approve_dry_run_approves_nothing() {
  config 'AUTO_APPROVE_AUTHORS=bob'
  search_prs
  author_prs bob 'acme/api#5'
  approvable 'acme/api#5' bob
  watcher run --dry-run
  assert_rc 0
  assert_lacks "$GH_CALLS" '/reviews'
  assert_log 'acme/api#5: \(dry-run\) would approve \(by bob · PR 5\)'
  assert_no_file "$STATE_DIR/last_actions.json"
}

test_auto_approve_is_off_without_authors() {
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 0
  watcher run
  assert_rc 0
  assert_has "$GH_CALLS" '^search prs ' 1
  assert_lacks "$GH_CALLS" '/reviews'
  watcher doctor --json
  assert_json "$SANDBOX/out" 'all(.checks[]; .id != "auto_approve")'
}

test_auto_approve_failure_is_retried_next_run() {
  config 'AUTO_APPROVE_AUTHORS=bob'
  search_prs
  author_prs bob 'acme/api#5' 'acme/api#6'
  approvable 'acme/api#5' bob
  approvable 'acme/api#6' bob
  fixture_err api_POST_repos/acme/api/pulls/5/reviews.1 'HTTP 502: Bad Gateway'
  fixture_err api_POST_repos/acme/api/pulls/6/reviews.1 'HTTP 422: Unprocessable Entity'
  watcher run
  assert_rc 0
  assert_log 'acme/api#5: GitHub is failing, not approved, will retry next run'
  assert_log 'acme/api#6: not approved: HTTP 422'
  assert_no_file "$STATE_DIR/last_error"
  assert_notified 0
  watcher run
  assert_log 'acme/api#5: approved as ana'
}

test_auto_approve_search_hiccup_leaves_the_rest_of_the_run() {
  config 'AUTO_APPROVE_AUTHORS=bob carol'
  search_prs 'acme/api#7'
  pr 'acme/api#7' MERGEABLE 3
  fixture_err search_prs_author_bob 'HTTP 429: rate limit exceeded'
  author_prs carol 'acme/api#5'
  approvable 'acme/api#5' carol
  watcher run
  assert_rc 0
  assert_log 'GitHub rate limit hit, skipping the PRs by bob this run'
  assert_has "$GH_CALLS" '^api -X POST repos/acme/api/pulls/5/reviews ' 1
  assert_has "$GH_CALLS" 'pulls/7/update-branch' 1
  assert_no_file "$STATE_DIR/last_error"

  fixture_err search_prs_author_bob 'HTTP 422: Validation Failed'
  watcher run
  assert_rc 1
  assert_log 'the search for PRs by bob on GitHub failed: HTTP 422'
  assert_file "$STATE_DIR/last_error"
}

test_auto_approve_config_and_flags() {
  fixture api_GET_users/bob '{"login": "bob"}'
  fixture api_GET_users/carol '{"login": "carol"}'
  watcher install --dry-run --auto-approve 'bob carol' --auto-approve-for 1w
  assert_rc 0
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_AUTHORS=bob carol$' 1
  assert_has "$SANDBOX/out" "^AUTO_APPROVE_UNTIL=$(today_plus 7)\$" 1
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_REQUIRE_CI=true$' 1
  watcher install --dry-run --auto-approve bob
  assert_has "$SANDBOX/out" "^AUTO_APPROVE_UNTIL=$(today_plus 7)\$" 1
  watcher install --dry-run --auto-approve bob --auto-approve-for 3d --no-auto-approve-require-ci
  assert_has "$SANDBOX/out" "^AUTO_APPROVE_UNTIL=$(today_plus 3)\$" 1
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_REQUIRE_CI=false$' 1
  watcher install --dry-run --auto-approve bob --auto-approve-for forever
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_UNTIL=$' 1
  watcher install --dry-run --auto-approve bob --auto-approve-until 2030-02-01
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_UNTIL=2030-02-01$' 1
  config AUTO_APPROVE_UNTIL=2030-05-01
  watcher install --dry-run --auto-approve bob
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_UNTIL=2030-05-01$' 1
  config 'AUTO_APPROVE_AUTHORS=bob'
  watcher install --dry-run --no-auto-approve
  assert_has "$SANDBOX/out" '^AUTO_APPROVE_AUTHORS=$' 1

  watcher install --dry-run --auto-approve ghost
  assert_rc 1
  assert_has "$SANDBOX/out" "error: user 'ghost' in AUTO_APPROVE_AUTHORS does not exist on GitHub" 1
  watcher install --dry-run --auto-approve bob --auto-approve-for 2x
  assert_rc 1
  assert_has "$SANDBOX/out" "error: --auto-approve-for must be 1w, <N>d or forever \(got '2x'\)" 1

  config 'AUTO_APPROVE_AUTHORS=bob,carol'
  watcher run
  assert_rc 1
  assert_log 'AUTO_APPROVE_AUTHORS must be separated by spaces, not commas'
  config AUTO_APPROVE_UNTIL=2026-13-01
  watcher run
  assert_rc 1
  assert_log "AUTO_APPROVE_UNTIL must be a date as YYYY-MM-DD \(got '2026-13-01'\)"
  config 'AUTO_APPROVE_UNTIL=next week'
  watcher run
  assert_rc 1
  assert_log "AUTO_APPROVE_UNTIL must be a date as YYYY-MM-DD \(got 'next week'\)"
  config AUTO_APPROVE_REQUIRE_CI=maybe
  watcher run
  assert_rc 1
  assert_log 'AUTO_APPROVE_REQUIRE_CI must be true or false'

  config 'AUTO_APPROVE_AUTHORS=bob carol' AUTO_APPROVE_UNTIL=2999-12-31
  watcher doctor --json
  assert_json "$SANDBOX/out" '.checks[] | select(.id == "auto_approve") | .status == "ok"
    and .message == "auto-approves PRs by bob, carol until 2999-12-31, once CI passes"'
  watcher status --json
  assert_json "$SANDBOX/out" '.config.values | .AUTO_APPROVE_AUTHORS == "bob carol"
    and .AUTO_APPROVE_UNTIL == "2999-12-31" and .AUTO_APPROVE_REQUIRE_CI == true'
  watcher detect
  assert_json "$SANDBOX/out" '.config.values.AUTO_APPROVE_AUTHORS == "bob carol"'
  config 'AUTO_APPROVE_AUTHORS=ghost'
  watcher doctor --json
  assert_json "$SANDBOX/out" '.checks[] | select(.id == "targets") | .status == "fail"
    and .fix == "fix the login in AUTO_APPROVE_AUTHORS"'
}

# ── run --dry-run ──────────────────────────────────────────────────────────────────────────────

test_dry_run_changes_nothing() {
  search_prs 'acme/api#7' 'acme/api#8'
  pr 'acme/api#7' MERGEABLE 3
  pr 'acme/api#8' CONFLICTING 1
  review 'acme/api#7' CHANGES_REQUESTED bob
  watcher run --dry-run
  assert_rc 0
  assert_lacks "$GH_CALLS" 'update-branch'
  assert_notified 0
  assert_log 'acme/api#7: 3 behind → \(dry-run\) would update the branch'
  assert_log '\(dry-run\) would notify: api#8 · conflict needs attention'
  assert_log '\(dry-run\) would notify: api#7 · changes requested'
  local f
  for f in state.json conflicts.json conflicts.html conflicts_reminded.json changes_requested.json \
    changes_requested.html updates.json ci_failed.html last_actions.json last_run last_error auto_approve_expired; do
    assert_no_file "$STATE_DIR/$f"
  done
}

# ── list ───────────────────────────────────────────────────────────────────────────────────────

test_list_puts_what_needs_you_first() {
  search_prs 'acme/api#1' 'acme/api#2' 'acme/api#3' 'acme/api#4' 'acme/api#5'
  pr 'acme/api#1' MERGEABLE 0
  pr 'acme/api#2' MERGEABLE 3
  pr 'acme/api#3' CONFLICTING 5
  pr 'acme/api#4' MERGEABLE 0
  review 'acme/api#4' CHANGES_REQUESTED bob
  pr 'acme/api#5' MERGEABLE 0
  checks 'acme/api#5' '' 'lint:SUCCESS' 'test:FAILURE'
  checks 'acme/api#1' '' 'lint:SUCCESS'
  review 'acme/api#1' APPROVED
  watcher list
  assert_rc 0
  [ "$(awk 'NR > 1 {printf "%s ", $2}' "$SANDBOX/out")" = "#3 #4 #5 #2 #1 " ] \
    || fail "rows out of order: $(awk 'NR > 1 {printf "%s ", $2}' "$SANDBOX/out")"
  assert_has "$SANDBOX/out" '^REPO +PR +STATE +CI +REVIEWS +LAST RUN +AGE +TITLE$' 1
  assert_has "$SANDBOX/out" '^acme/api +#3 +conflict +- +- +- +2h +PR 3$' 1
  assert_has "$SANDBOX/out" '^acme/api +#4 +up to date +- +changes requested +- +2h +PR 4$' 1
  assert_has "$SANDBOX/out" '^acme/api +#5 +up to date +failing +' 1
  assert_has "$SANDBOX/out" '^acme/api +#2 +3 behind +' 1
  assert_has "$SANDBOX/out" '^acme/api +#1 +up to date +passing +approved +' 1
  # It only reads.
  assert_lacks "$GH_CALLS" 'update-branch'
  assert_notified 0
  assert_no_file "$STATE_DIR/state.json"
  assert_no_file "$STATE_DIR/last_run"
  assert_no_file "$STATE_DIR/watcher.log"
}

test_list_shows_what_the_last_run_did() {
  search_prs 'acme/api#7' 'acme/api#8' 'acme/api#9 draft'
  pr 'acme/api#7' MERGEABLE 3
  pr 'acme/api#8' CONFLICTING 1
  watcher run
  watcher list
  assert_rc 0
  assert_has "$SANDBOX/out" '^acme/api +#7 +3 behind +- +- +3 behind → branch updated from main \(CI will run\) +2h +PR 7$' 1
  assert_has "$SANDBOX/out" '^acme/api +#8 +conflict +- +- +CONFLICT \(1 behind\) ' 1
  assert_json "$STATE_DIR/last_actions.json" '.prs["acme/api#9"] == "draft, left alone"'
}

test_list_json_has_one_object_per_pr() {
  search_prs 'acme/api#7' 'acme/web#9'
  pr 'acme/api#7' MERGEABLE 2
  checks 'acme/api#7' '' 'test:IN_PROGRESS'
  pr_view 'acme/web#9' UNKNOWN
  watcher list --json
  assert_rc 0
  assert_json "$SANDBOX/out" 'length == 2 and (map(.number) == [7, 9])'
  assert_json "$SANDBOX/out" '.[0] | .repo == "acme/api" and .state == "behind" and .behind == 2 and .ci == "pending"
    and .review == null and .last_run == null and .url == "https://github.com/acme/api/pull/7" and .title == "PR 7"'
  assert_json "$SANDBOX/out" '.[1] | .state == "unknown" and .mergeable == "UNKNOWN"'
}

test_list_uses_the_same_filters_as_run() {
  config 'REPOS=acme/api' SKIP_LABEL=no-autoupdate
  search_prs 'acme/api#7' 'acme/api#8 draft' 'acme/api#9 label:no-autoupdate'
  pr 'acme/api#7' MERGEABLE 0
  watcher list --json
  assert_rc 0
  assert_has "$GH_CALLS" '^search prs .* --repo acme/api$' 1
  assert_json "$SANDBOX/out" 'map(.number) == [7]'
  search_prs
  watcher list
  assert_has "$SANDBOX/out" '^no open PRs$' 1
  watcher list --wide
  assert_rc 1
  assert_has "$SANDBOX/out" 'error: unknown option for list: --wide' 1
}

# ── run: errors ────────────────────────────────────────────────────────────────────────────────

test_transient_error_waits_silently() {
  fixture_err search_prs 'HTTP 502: Bad Gateway (https://api.github.com/search/issues)'
  watcher run
  assert_rc 0
  assert_log 'GitHub is failing, will retry next run'
  assert_notified 0
  assert_no_file "$STATE_DIR/last_error"
}

test_real_error_notifies_once() {
  fixture_err search_prs 'HTTP 422: Validation Failed (https://api.github.com/search/issues)'
  watcher run
  assert_rc 1
  assert_has "$NOTIFY_CALLS" '-subtitle stopped working · gh pr-watcher doctor -message the PR search on GitHub failed: HTTP 422' 1
  assert_file "$STATE_DIR/last_error"
  watcher run
  assert_notified 1

  # The next run that works clears the error.
  rm "$FIXTURES/search_prs.err"
  search_prs
  watcher run
  assert_rc 0
  assert_no_file "$STATE_DIR/last_error"
  assert_log 'working again'
}

# ── runner ─────────────────────────────────────────────────────────────────────────────────────

passed=0 failed=0
for t in $(declare -F | awk '{print $3}' | grep '^test_'); do
  [ -z "${1:-}" ] || [[ "$t" == *$1* ]] || continue
  if (
    setup
    # A test that aborts (an unset variable, a failing helper) fails too, with what it said.
    out=$("$t" 2>&1) || out="${out:+$out
}    ✗ the test aborted (exit $?)"
    if [ -z "$out" ]; then rm -rf "$SANDBOX"; exit 0; fi
    printf '✗ %s\n%s\n    sandbox: %s\n' "${t#test_}" "$out" "$SANDBOX"
    exit 1
  ); then
    printf '✓ %s\n' "${t#test_}"
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
  fi
done

echo
echo "$passed passed, $failed failed"
[ "$failed" = "0" ] && [ "$passed" -gt 0 ]
