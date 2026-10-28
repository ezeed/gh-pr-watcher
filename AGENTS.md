# Installing gh-pr-watcher from an agent

A guide for a coding agent (Claude Code, Codex, Cursor…) that installs or reconfigures the
extension on a person's behalf. The agent has no interactive terminal: everything goes through
`detect` (read, JSON) and `install` with flags (write). With no flags and no terminal, `install`
asks nothing: it uses the existing config plus the defaults.

## What it does (so you can explain it)

Each run searches the person's open PRs (`gh search prs --author @me`) in the configured orgs or
repos and, for each one:

| PR state | Action |
|---|---|
| Draft | Nothing (unless `INCLUDE_DRAFTS=true`). |
| Has the `SKIP_LABEL` label | Nothing. |
| Mergeable and behind its base | `PUT /repos/{repo}/pulls/{n}/update-branch`: merges the base into the branch, which triggers CI. |
| Mergeable and up to date | Nothing. |
| Conflicting | Notification while it stays conflicting, grouped with the other conflicting PRs: at most once an hour, and right away when a new one shows up or the list changes. |
| GitHub still computing mergeability | Retries for a few seconds; otherwise it waits for the next run. |
| A review moves it to changes requested | One notification, once (unless `NOTIFY_CHANGES_REQUESTED=false`). Independent of the rows above. |
| CI fails on a branch the watcher updated | One notification, once (only with `NOTIFY_CI_FAILED=true`). Not for the person's own pushes. |
| Someone else's open PR, by a login in `AUTO_APPROVE_AUTHORS` | Approved as `GH_USER` (only when `AUTO_APPROVE_AUTHORS` is set, up to `AUTO_APPROVE_UNTIL`). Not drafts, not PRs with `SKIP_LABEL`, never the person's own; not when that account's latest approval is still live; with `AUTO_APPROVE_REQUIRE_CI=true` (the default), only when the head has checks and all of them passed. |

- **It does not resolve conflicts.** If GitHub's three-way merge applies cleanly, it updates the
  branch; if a single line clashes, it only notifies. When the PR becomes mergeable again there is
  no notification; if it is behind, it gets updated like any other.
- It never forces anything, never rebases and never pushes from the machine. It sends
  `expected_head_sha`: if the person pushed between the read and the update, GitHub rejects it and
  the PR waits for the next run.
- **Merge, not rebase.** With squash merges it leaves no trace; in repos that require linear
  history, those merge commits get in the way.
- **The person's `git push` may bounce** if the watcher updated a branch they have checked out:
  `git pull` fixes it.
- **Every update triggers CI.** With "require branches to be up to date", each merge to the base
  can mean one extra CI run per ready PR per person using it. The cap is the number of runs per
  day (`EVERY_MINUTES`): a shorter interval batches fewer merges into one update.
- `gh` reads its token from the keychain, which works under launchd.
- **Auto-approval approves code on the person's behalf.** It searches the PRs of each login in
  `AUTO_APPROVE_AUTHORS` in the same orgs or repos (with neither, everywhere those people have open
  PRs) and approves them as `GH_USER`. A push that dismisses the approval, or a review of the
  person's that requests changes, makes the PR eligible again. That's why CI is required by default
  and an end date is recommended: `--auto-approve` without one sets a week. Past the end date it
  approves nothing and logs `auto-approve expired on <date>` once.

There are four notifications; the conflict and stopped-working ones can't be turned off:

- **Conflict:** one notification for all conflicting PRs, replacing the previous one, repeated at most
  once an hour unless a new one shows up or the list changes.
  With one PR, `<repo>#<n> · conflict needs attention` (or `· still conflicting since HH:MM`), and
  clicking it opens the PR. With several, `N PRs with conflicts (M new)` listing them, and clicking
  it opens `~/.local/state/gh-pr-watcher/conflicts.html`, a page with a link to each one. When no
  conflict is left, the notification is removed.
- **Changes requested** (`NOTIFY_CHANGES_REQUESTED`, on by default): when a review moves a PR to
  changes requested, `<repo>#<n> · changes requested` with the title and who asked, opening the PR.
  Several in the same run: `N PRs with changes requested`, opening
  `~/.local/state/gh-pr-watcher/changes_requested.html`. Once per PR: it comes back only if the PR
  leaves that state (approved, review dismissed) and changes are requested again. With the option
  off, it still keeps track, so turning it on doesn't notify the old ones.
- **CI failed** (`NOTIFY_CI_FAILED`, off by default): after updating a branch, the watcher remembers
  the head it updated from. On later runs, if the new head is its own merge commit (two parents, the
  first one that head), it reads that commit's checks: if any fails, `<repo>#<n> · CI failed after
  the update` with the failing checks, opening the PR's checks tab; several in the same run open
  `~/.local/state/gh-pr-watcher/ci_failed.html`. Once per update. If the person pushes in between or
  on top, it stops following it. It stops after 24 h without a result too.
- **Stopped working:** `stopped working · gh pr-watcher doctor`, with the error as the body (expired
  `gh` session, invalid config, an owner that doesn't exist). Clicking it opens the log. It isn't
  repeated while the error stays the same. A known transient failure (no network, a timeout,
  a GitHub 5xx or rate limit; the list is `TRANSIENT_ERRORS` in the script) notifies nothing: it
  logs it and tries again next run.

## 1. Check dependencies

```bash
command -v gh && gh auth status        # no session: the person runs `gh auth login` (interactive)
command -v jq                          # if missing: brew install jq
gh extension list | grep pr-watcher || gh extension install ezeed/gh-pr-watcher
```

`jq` is required: it parses `gh`'s output, keeps the state file and builds the JSON of `detect` and
`doctor --json`. `terminal-notifier` is optional (clickable notifications with an image); without
it, notifications go through `osascript` with no click.

`gh auth login` and `brew install` change the machine: ask for permission before running them.

## 2. Read the current state

```bash
gh pr-watcher detect            # or: detect --user LOGIN, to see another account's orgs and repos
```

It returns JSON like this:

```json
{
  "os": "Darwin", "scheduler": "launchd",
  "deps": {"gh": "/opt/homebrew/bin/gh", "jq": "/usr/bin/jq", "terminal_notifier": null},
  "accounts": [{"login": "ana", "active": true}],
  "account": "ana",
  "orgs": ["AcmeCorp"],
  "repos_with_prs": ["AcmeCorp/api", "AcmeCorp/web", "ana/dotfiles"],
  "config": {"path": "...", "exists": false,
             "values": {"GH_USER": "", "OWNERS": "", "REPOS": "", "EVERY_MINUTES": 60,
                        "INCLUDE_DRAFTS": false, "SKIP_LABEL": "",
                        "NOTIFY_CHANGES_REQUESTED": true, "NOTIFY_CI_FAILED": false,
                        "AUTO_APPROVE_AUTHORS": "", "AUTO_APPROVE_UNTIL": "",
                        "AUTO_APPROVE_REQUIRE_CI": true}},
  "installed": {"plist_exists": false, "agent_loaded": false, ...},
  "last_run_error": null,
  "other_watcher_agents": [],
  "errors": []
}
```

- `repos_with_prs` are the repos where the account has PRs, open or among its 100 most recent.
  They are the candidates to watch.
- `config.values` is what the file holds. If `exists` is false, these are the defaults.
- If `installed.agent_loaded` is true, it's already installed: `install` reschedules it without
  duplicating it.
- A non-empty `errors` means something above couldn't be read (no `gh`, no session, no network).
  An empty `orgs` with errors does **not** mean "no orgs": fix the error before deciding.
- `last_run_error` is why the last scheduled run failed, if it did.
- `other_watcher_agents` lists other LaunchAgents with "pr-watcher" or "babysitter" in their name
  (for example, an earlier home-made script). If there is one, say so: both would run at once.

## 3. Decide or ask

Decide on your own, without asking, whatever `detect` settles:

| Situation | Decision |
|---|---|
| A single account in `accounts` | Don't pass `--user`. |
| No orgs in `orgs` | Don't pass `--owners`: it watches all the account's PRs. |
| `repos_with_prs` falls entirely within one org | `--owners <org>`. |
| The person didn't mention frequency, drafts, label, notifications or approvals | The defaults: every hour, no drafts, no label, changes-requested notification on, CI-failed off, auto-approval off. |

Ask the person, in a single question with the options from `detect` in view:

- **Which account**, if `accounts` has more than one.
- **What to watch**, if they have orgs or repos spread across several owners. Show `orgs`,
  `repos_with_prs` and the option of their personal repos.
- **Whether it replaces a previous watcher**, when `other_watcher_agents` isn't empty. Never unload
  it without their OK.
- **Whether the CI cost is fine**, when it will watch shared repos (see "What it does").

Don't turn on auto-approval unless the person asks for it. When they do, confirm the logins and
how long (`--auto-approve-for 1w` if they don't say), and say that it approves code as their account.

Don't ask about notifications: the conflict one is always on, and the changes-requested one stays on
unless the person says they don't want it (`--no-notify-changes-requested`). The CI-failed one stays
off unless they ask for it (`--notify-ci-failed`).

## 4. Install

First show what it will write, then install:

```bash
gh pr-watcher install --dry-run --owners "AcmeCorp" --every 1h --no-drafts --no-skip-label
gh pr-watcher install           --owners "AcmeCorp" --every 1h --no-drafts --no-skip-label
```

| Flag | Key | Value |
|---|---|---|
| `--user LOGIN` | `GH_USER` | One of `accounts[].login`. Empty = the active account on each run. |
| `--owners "A B"` | `OWNERS` | Orgs or users, space-separated. `""` = all PRs. |
| `--repos "o/r o/r"` | `REPOS` | Only those repos. **Replaces** `OWNERS` (GitHub search combines org and repo with AND). |
| `--every 15m\|30m\|1h\|2h\|3h` | `EVERY_MINUTES` | Counting from 0:00. Default `1h`. |
| `--drafts` / `--no-drafts` | `INCLUDE_DRAFTS` | |
| `--skip-label L` / `--no-skip-label` | `SKIP_LABEL` | The convention is `no-autoupdate`. |
| `--notify-image PATH` | `NOTIFY_IMAGE` | Image attached to notifications. `""` = the bundled one. |
| `--notify-changes-requested` / `--no-notify-changes-requested` | `NOTIFY_CHANGES_REQUESTED` | Default on. |
| `--notify-ci-failed` / `--no-notify-ci-failed` | `NOTIFY_CI_FAILED` | Default off. |
| `--auto-approve "a b"` / `--no-auto-approve` | `AUTO_APPROVE_AUTHORS` | GitHub logins, space-separated. Empty = off (the default). |
| `--auto-approve-for 1w\|<N>d\|forever` | `AUTO_APPROVE_UNTIL` | Last day it approves: today + the duration (`1w` = today + 7), or no end date with `forever`. `--auto-approve` with no end date anywhere sets `1w`. |
| `--auto-approve-until YYYY-MM-DD` | `AUTO_APPROVE_UNTIL` | The same, as a date. |
| `--auto-approve-require-ci` / `--no-auto-approve-require-ci` | `AUTO_APPROVE_REQUIRE_CI` | Default on: approve only when every check passed. |

`install` validates before writing anything: the format of each value, that the `gh` session is
valid and has the `repo` scope, and that every owner, repo and auto-approved login exists. If
something fails, nothing is left half-done. Flags you don't pass keep the value from the existing
config. `--yes` forces the no-questions mode even with a terminal.

Installing loads a LaunchAgent in the person's session: ask for their OK before running `install`
without `--dry-run`.

## 5. Verify

```bash
gh pr-watcher doctor --json     # ok: true; otherwise the "fail" checks say how to fix them
gh pr-watcher run --dry-run     # lists which PRs it would update, without touching any
```

Right after installing, the `last_run` check says `not due to run yet (next: … h)`: that's expected.

`run --dry-run` doesn't update branches, notify or save state: you can run it without asking.
`list --json` neither: it gives, per PR, `state` (`conflict`, `behind`, `up_to_date`, `unknown`),
`behind`, `ci` (`failing`, `pending`, `passing` or null), `failed_checks`, `review`, `last_run` (what
the last run did to it) and `created_at`, with the ones that need the person first.
`test-notify` does send a notification (to check that macOS shows them): ask first.

## Errors

For any problem (the person says it doesn't work, or `detect` has a `last_run_error`), start with:

```bash
gh pr-watcher doctor --json
```

```json
{"ok": false, "checks": [
  {"id": "session", "status": "fail", "message": "the token for 'ana' is missing the repo scope; run gh auth refresh -h github.com -s repo", "fix": null},
  {"id": "last_run", "status": "fail", "message": "should have run at 2026-09-29 12:00 and didn't (last: never)", "fix": "check launchctl print gui/<uid>/local.gh-pr-watcher and <state>/launchd.err.log; then gh pr-watcher install --yes"}
]}
```

Check ids: `gh`, `jq`, `config`, `notifications`, `auto_approve`, `session`, `targets`, `agent`, `last_run`. `status` is `ok`,
`warn` (works, with a caveat) or `fail`. The fix is in `fix`, or inside `message` when the message
already carries the command. `doctor` changes nothing and doesn't notify: you can run it without
asking. Applying a `fix` does change things: ask for permission as with `install`.

Outside `doctor`, every error goes to stderr prefixed with `error:` and exits non-zero. The most
common ones:

| Message | What to do |
|---|---|
| `jq is missing` / `gh, the GitHub CLI, is missing` / `your gh is too old` | `brew install jq`, `brew install gh` or `brew upgrade gh`, with permission. |
| `gh has no session on github.com` / `gh has no session as 'X'` | The person runs `gh auth login`. |
| `the gh session for 'X' is not valid` / `the token for 'X' is missing the repo scope` | The person runs the `gh auth refresh …` the message shows. |
| `no connection to GitHub, try again later` / `GitHub is failing, try again later` / `GitHub rate limit hit, try again later` | Transient: retry in a few minutes; it isn't a config problem. If it persists without network, check the proxy. |
| `user or org 'X' does not exist on GitHub` / `repo 'X' does not exist or your account has no access to it` | Fix `--owners`/`--repos` with the values from `detect`. |
| `… must be separated by spaces, not commas` / `REPOS has an invalid repo` | Owners and repos are space-separated; repos are `owner/repo`. |
| `user 'X' in AUTO_APPROVE_AUTHORS does not exist on GitHub` | Fix the login in `--auto-approve`. |
| `AUTO_APPROVE_UNTIL must be a date as YYYY-MM-DD` / `--auto-approve-for must be 1w, <N>d or forever` | `--auto-approve-for 1w`, `--auto-approve-until 2026-12-31` or `forever`. |
| `auto-approve ended on <date>` (doctor, `warn`) | It approves nothing anymore. If the person wants more: `install --auto-approve-for 1w`. |
| `EVERY_MINUTES must be one of 15 30 60 120 180` / `--every must be …` | `--every 15m`, `30m`, `1h`, `2h` or `3h`. |
| `EVERY_HOURS=N is no longer offered` | An old config with more than 3 h: pass `--every` with one of the offered values. |
| `NOTIFY_IMAGE is not a readable file` | An existing local path, or `--notify-image ""`. |
| `launchctl bootstrap failed` | Check the plist at `detect.installed.plist` with `plutil -lint`. |

## Uninstall

```bash
gh pr-watcher uninstall && gh extension remove pr-watcher
```

The config stays at `config.path` and the log in `~/.local/state/gh-pr-watcher/`. Deleting them is
harmless.
