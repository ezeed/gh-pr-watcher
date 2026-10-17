#!/usr/bin/env bash
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
search_prs() {
  local spec items='[]'
  for spec in "$@"; do
    items=$(jq --arg s "$spec" '($s | split(" ")) as $w | ($w[0] | split("#")) as $k | . + [{
      repository: {nameWithOwner: $k[0]}, number: ($k[1] | tonumber),
      isDraft: ($w | index("draft") != null),
      labels: [$w[] | select(startswith("label:")) | {name: .[6:]}],
      title: "PR \($k[1])", url: "https://github.com/\($k[0])/pull/\($k[1])"}]' <<<"$items")
  done
  fixture search_prs "$items"
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
    url: "https://github.com/\($r)/pull/\($n)", title: "PR \($n)",
    reviewDecision: "", latestReviews: []}')"
}

# review o/r#N DECISION [REVIEWER] [call]: the PR's reviewDecision, with REVIEWER's latest review
# in that state, on every call or only on that call number. Goes after pr or pr_view.
review() {
  local repo="${1%#*}" num="${1#*#}" base f
  base="$FIXTURES/$(fixture_key "pr_view_${repo}_$num")"
  f="$base.json"
  if [ -n "${4:-}" ]; then
    f="$base.$4.json"
    [ -f "$f" ] || cp "$base.json" "$f"
  fi
  jq --arg d "$2" --arg by "${3:-}" '.reviewDecision = $d
    | .latestReviews = (if $by == "" then [] else [{author: {login: $by}, state: $d}] end)' "$f" >"$f.tmp"
  mv "$f.tmp" "$f"
}

# behind o/r#N COMMITS: how far the head is behind main.
behind() {
  local repo="${1%#*}" num="${1#*#}"
  fixture "api_GET_repos/$repo/compare/main...ana:feat-$num" "{\"behind_by\": $2, \"ahead_by\": 1}"
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
  assert_json "$SANDBOX/out" '.checks[] | select(.id == "notifications") | .message | test("conflicts only")'
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
    changes_requested.html last_run last_error; do
    assert_no_file "$STATE_DIR/$f"
  done
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
    out=$("$t")
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
