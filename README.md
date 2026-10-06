<p align="center">
  <img src="assets/logo.png" alt="gh-pr-watcher" width="160">
</p>

<h1 align="center">gh-pr-watcher</h1>

<p align="center">
  Keeps your open PRs up to date and tells you when one runs into a conflict.<br>
  A <a href="https://cli.github.com">GitHub CLI</a> extension that runs on its own a few times a day.
</p>

<p align="center">
  <a href="https://github.com/ezeed/gh-pr-watcher/actions/workflows/lint.yml"><img src="https://github.com/ezeed/gh-pr-watcher/actions/workflows/lint.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/ezeed/gh-pr-watcher/releases"><img src="https://img.shields.io/github/v/release/ezeed/gh-pr-watcher" alt="Release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-yellow.svg" alt="License: MIT"></a>
  <a href="https://cli.github.com"><img src="https://img.shields.io/badge/gh-extension-blue" alt="gh extension"></a>
  <a href="https://github.com/ezeed/gh-pr-watcher/stargazers"><img src="https://img.shields.io/github/stars/ezeed/gh-pr-watcher?style=social" alt="Stars"></a>
</p>

<p align="center"><b>English</b> · <a href="README.es.md">Español</a></p>

---

It does what GitHub's **"Update branch"** button does, but for you and on all your PRs at once.
Nothing changes in the repo: no Actions, no bots, no new permissions. It never resolves conflicts,
rebases or forces anything: when a PR conflicts, it only notifies you.

Built for repos with the *"Require branches to be up to date before merging"* rule: every merge to
the base leaves all open PRs behind, and each one has to be updated before it can merge.

<p align="center">
  <img src="assets/notification.gif" alt="Conflict notification" width="600">
</p>

What a run looks like (the same lines go to `gh pr-watcher log`):

```text
$ gh pr-watcher run
2026-10-06 10:00:04 acme/api#412: 3 behind → branch updated from main (CI will run)
2026-10-06 10:00:06 acme/api#418: up to date
2026-10-06 10:00:09 acme/web#97: CONFLICT (5 behind)
```

## Install

```bash
gh extension install ezeed/gh-pr-watcher
gh pr-watcher install          # asks for the config and schedules the run
gh pr-watcher run --dry-run    # test: reports what it would do, without updating any branch
```

To pin a version: `gh extension install ezeed/gh-pr-watcher --pin v0.2.0` (see [releases](https://github.com/ezeed/gh-pr-watcher/releases)).

### With an agent

Ask your coding agent (Claude Code, Codex, Cursor…):

```text
Install gh-pr-watcher following https://github.com/ezeed/gh-pr-watcher/blob/main/AGENTS.md
```

It reads your accounts, orgs and repos with `detect` and installs with flags, no console prompts:

```bash
gh pr-watcher detect
gh pr-watcher install --owners "AcmeCorp" --every 1h
```

### Requirements

- **macOS** for scheduling (launchd). On Linux, `run` works the same and `install` gives you the
  `crontab` line.
- [`gh`](https://cli.github.com) authenticated (`gh auth login`), with write access to each PR's
  branch. Your PRs in the org's repo already have it. From a fork, the PR needs *"Allow edits from
  maintainers"*.
- `jq` (`brew install jq`).
- Optional: `terminal-notifier` (`brew install terminal-notifier`), so clicking the notification
  opens the PR. Without it, notifications go through `osascript` and aren't clickable.

## Configuration

It lives in `~/.config/gh-pr-watcher/config`: `KEY=VALUE` lines that are read, never executed.
Changes apply from the next run; only `EVERY_MINUTES` needs `gh pr-watcher install --yes` to
reschedule.

| Key | Default | What it controls |
|---|---|---|
| `GH_USER` | *(empty)* | `gh` account to use, even if another one is active. Empty = the active `gh` account on each run. |
| `OWNERS` | *(empty)* | Orgs or users whose repos are watched, space-separated. Empty = all your open PRs, in any repo. The installer suggests your orgs. |
| `REPOS` | *(empty)* | Specific `owner/repo` repos, space-separated. If set, **only those** are watched and `OWNERS` is ignored (GitHub search combines org and repo with AND, not OR). |
| `EVERY_MINUTES` | `60` | How often it runs, in minutes: `15`, `30`, `60`, `120` or `180`, counting from 0:00 (`180` = 0:00, 3:00, 6:00…). If the machine is asleep at that time, launchd runs it on wake. Each update triggers CI, so a shorter interval can mean more CI runs when several merges land close together. A config with the old `EVERY_HOURS` keeps working until the next `install`. |
| `INCLUDE_DRAFTS` | `false` | `true` = drafts get updated too. |
| `SKIP_LABEL` | *(empty)* | PRs with this label are left alone. The installer offers `no-autoupdate`; in the file you can use any label. |
| `NOTIFY_IMAGE` | *(the logo)* | Local image (PNG or JPG) shown on the right of the notification. Only with `terminal-notifier`. The icon on the left can't be changed: macOS takes it from the notifying app. |

A misspelled key (`OWNER=`) or a line that isn't `KEY=VALUE` isn't silently ignored: you get a
warning, with a suggestion if it looks like a real key. `install` also checks that every owner and
repo exists and that your account can see it.

The log and state live in `~/.local/state/gh-pr-watcher/`. While a PR stays conflicting, you
get reminded at most once an hour (right away if a new one shows up or the list changes): a single notification for all of them, which opens the PR if there is one or a
local page listing them if there are several. The state only remembers since when each conflict
has been open: deleting it is harmless. Each log keeps its last 2000 lines (from days to a month, depending on the frequency
and how many PRs are open); older ones are dropped on each run.

## Commands

| Command | What it does |
|---|---|
| `install [options]` | Saves the config and schedules the run (launchd on macOS; on Linux it prints the `crontab` line). With a terminal and no options, it asks. |
| `run [--dry-run]` | Runs once now. With `--dry-run` it reports what it would do, without updating branches, notifying or saving state. |
| `status [--json]` | Config, whether the agent is loaded, the last run, the last error and the tail of the log. |
| `doctor [--json]` | Checks everything a run needs and says how to fix each problem. Changes nothing. |
| `log [N]` | The last N log lines (30 by default). |
| `config` | The config file path and contents. |
| `test-notify` | Sends a test notification. |
| `detect [--user LOGIN]` | JSON with accounts, orgs, repos with your PRs, dependencies, config and current install. Meant for agents. |
| `uninstall` | Removes the schedule. Config and log stay. |
| `version` · `help` | Version and help. |

A misspelled command suggests the right one (`rub` → `run`). Errors go to stderr prefixed with
`error:` and a non-zero exit code.

### `install` options

With any of these options (except `--dry-run`), `install` asks nothing: the options override your
existing config and anything missing comes from the defaults.

| Option | What it does |
|---|---|
| `--user LOGIN` | `gh` account to use (`GH_USER`). |
| `--owners "A B"` | Orgs or users to watch (`OWNERS`). `""` = all your PRs. |
| `--repos "o/r o/r"` | Only these repos (`REPOS`); replaces `--owners`. |
| `--every 15m\|30m\|1h\|2h\|3h` | How often it runs (`EVERY_MINUTES`). `--every-hours 1\|2\|3` still works. |
| `--drafts` · `--no-drafts` | Update drafts or not (`INCLUDE_DRAFTS`). |
| `--skip-label L` · `--no-skip-label` | Exclude PRs with label L or not (`SKIP_LABEL`). |
| `--notify-image PATH` | Notification image (`NOTIFY_IMAGE`). `""` = the logo. |
| `--yes` | Don't ask: use the existing config and the defaults. Useful to reschedule after editing the file. |
| `--dry-run` | Shows the config and the LaunchAgent it would write, without touching anything. On its own, it still asks the questions. |

## Troubleshooting

```bash
gh pr-watcher doctor
```

It flags each problem with the command that fixes it and exits non-zero if something fails. It
changes nothing and sends no notifications. It checks:

- `gh` and `jq` installed, and `terminal-notifier` (as a warning only).
- The config: misspelled keys and invalid values.
- The `gh` session, the `repo` scope, and that each owner and repo exists and your account sees it.
- The schedule: that the LaunchAgent is loaded, that it points to a `gh` that still exists (brew
  sometimes moves it) and that its schedule matches `EVERY_MINUTES`.
- **That it actually ran.** No notification covers this: if launchd stops firing, there's no error.
  `doctor` compares the last run with the last scheduled time; if the machine was off at that time
  it doesn't flag it, and if it was asleep it waits for launchd to run it on wake.
- Another watcher running at the same time, the last run's error and a corrupted state.

`doctor --json` returns the same for an agent: `{ok, checks: [{id, status, message, fix}]}`.

## Upgrade and uninstall

```bash
gh extension upgrade pr-watcher     # the schedule keeps working, no need to reinstall
gh pr-watcher uninstall && gh extension remove pr-watcher
```

`uninstall` keeps the config and the log; to start from scratch, also delete
`~/.config/gh-pr-watcher` and `~/.local/state/gh-pr-watcher`.

## License

[MIT](LICENSE).
