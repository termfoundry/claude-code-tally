# How claude-code-tally works

The details behind the [README](../README.md): what each part of the status line means exactly, where each number comes from, how the running totals are kept, where it was tested, and what the tests check.

## Each line in detail

| Line | Parts |
| --- | --- |
| 1 | Main model and effort (`fast` when fast mode is on) · permission mode (`auto`, `plan`, `accept edits`, red `bypass`; nothing for default), as of your last prompt · git repository name (for a worktree, its repository's), else the project folder · `⎇` branch, `↑`/`↓` commits ahead/behind its upstream · lines `+added −removed in N` files against `HEAD`, `●` staged, `✚` unstaged, `?` untracked (`clean` when nothing changed) · how long the last turn took |
| `ctx` | Context window fill, then the tokens in the context now / the window size: what the model read on the last request, the same count as the percentage |
| `5h`, `7d` | Plan limit used, `(pace)`, the difference from the pace, time until the reset. Only on claude.ai Pro and Max plans, from the session's first response on: otherwise these two lines are left out. Once the reset time has passed, `0%` until the next response |
| last | Tokens per model for the whole session: `↑` in (fresh + cache read + cache write), `↓` out, `⚡` share served from the prompt cache, and on the main model the main conversation's cache misses (Claude Code's count, across the models it used, subagents not included). The main model comes first, then the two largest others; the rest fold into `+N more`. Then `🔧` tool calls and `✗` errors, turns (see [Turns and active time](#turns-and-active-time)), cost, `⏱` how long the session has been open (Claude Code's count, added up across resumes) and the time Claude actually worked. In a narrow terminal the line drops detail until it fits: the folded rest, then the cache shares, then the other models, then the tool calls |
| review *(optional)* | Scores per round while a review loop of your own runs; hidden otherwise (see [the README](../README.md#optional-live-review-scores)) |

## Where the numbers come from

| From | Figures |
| --- | --- |
| Claude Code's status line JSON | model, effort, fast mode, context, limits, cost, cache misses |
| The session transcript, and its subagents' (those of Workflow runs too) | tokens per model, tool calls and errors, turns, turn times, permission mode |
| `git`, on each refresh, without optional locks (so it never blocks a git command Claude runs at the same moment) and without the repository's `core.fsmonitor` (so its `.git/config` can't run a program through it) | branch, ahead/behind, diff and file states |

Each API response is counted once (one response can span several transcript rows; the last row's usage counts). Requests that leave no response in the transcript, such as the summary call of a compaction, are not in the token totals; the cost includes them. The cost is what Claude Code reports: on a subscription plan it is the API-price equivalent, not a charge.

The permission mode comes from the transcript, as of your last prompt or Claude Code's latest note of it, so a switch with shift+tab shows with the next prompt.

## Turns and active time

Turns are the prompts you typed, picked from a suggestion or queued (one Claude takes into the turn under way too), the slash commands you typed that set Claude to work (a skill, `/code-review`), and a `!` command that Claude answers; a local command such as `/model`, a background task reporting back and a compaction summary are not.

Active time adds up the turns Claude Code timed, each from the prompt that started it, and the turns you interrupted, from their prompt to the interrupt; a turn that resumes when a subagent reports back counts from where the one before it ended, so that time counts once. A stretch with nothing written to any of the session's transcripts for more than 15 minutes (the computer asleep, a wait for a usage limit, a permission prompt or a question left unanswered) counts only its first 15 minutes; a subagent at work keeps the time counting.

## Running totals

Totals are kept per transcript in `~/.claude/statusline-state/transcript/`, a few hundred bytes each, a few KB for a long, busy session. Each refresh reads only the lines added since the last one; a line still being written waits for the next refresh. The first refresh of a long session reads its whole transcript (25 MB took about 2 s on a Mac), in pieces of up to 4 MB (a longer line, such as a pasted image, is a piece of its own), saving the totals after each: Claude Code cancels a refresh that is still running when the next one is due, and the next one carries on where it stopped. After that a refresh takes about 0.2 s. Two refreshes running at the same time never count anything twice.

When Claude Code takes a row out of a transcript (now and then, a reply it tried again), the reading carries on after the last row read, and the row taken out stays counted; only if that row is gone too is the transcript read again. The files are named after the session's id, so a transcript Claude Code moves to another project folder (`/cd`, a worktree) keeps its totals.

The files are safe to delete at any time: the session is counted again from its transcript, with the same result.

## Refreshes

Claude Code refreshes the status line when something happens in the main session; `refreshInterval` refreshes it every 10 seconds as well. Without it, the totals and `⏱` stand still while Claude waits for background agents, and with a Stop hook that takes a moment (a sound, a notification), the time of the turn that just ended is written after the last refresh and shows only at your next prompt.

## Platforms and versions

It needs `jq` 1.6 or later and `git` 2.15 or later (plus `awk`, `sed`, `stat`, `od`, usually present). With an older git a refresh can take git's index lock (before 2.15), or the git part is left out (before 2.11). Tested on macOS, Rocky Linux 8, Alpine 3.20 and Debian 12: `sh` as bash, dash and BusyBox; the BSD, GNU, mawk and BusyBox versions of `awk`. Numbers always use a decimal point, whatever the locale. On Windows (Git Bash), the CR LF line ends of a native `jq.exe` are handled; that is tested with a stand-in, not on Windows itself.

## Tests

```sh
sh tests/run.sh          # or: sh tests/run.sh dash
```

Needs `jq`, `git` and `python3`; it takes about 50 s on a Mac, 3–4 minutes on a Raspberry Pi. It generates a synthetic session (a 2 MB transcript, four subagents and a Workflow run's two, the same every time), counts it separately in Python, and checks that the script's totals and times match, read at once, in pieces (a line longer than a piece too) and after cancelled refreshes. It also checks idle time, turns started by a slash command, held up by a question or interrupted, a row Claude Code takes out of a transcript, a transcript moved to another project folder, worktrees, the git index, that a repository's `core.fsmonitor` is not run, reset times that are fractions, expressions or past, install.sh with `CDPATH` set, the terminal width, model names, locales, backslashes, `ACT_START_HHMM`, review scores with GNU `stat`, `jq`'s CR LF line ends on Windows and simultaneous refreshes, and compares the output with the last commit (`REF=<commit>` to pick another). It prints each check and exits 1 if one fails.
