#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
# claude-code-tally
# A multi-line status line for Claude Code:
#   • model + effort · permission mode · repo or project name · ⎇ branch with
#     ahead/behind · diff size and staged/unstaged/untracked counts · last turn
#   • context-window bar (zoned coloring) + tokens in the context / window size
#   • 5h / 7d rate-limit bars with a "pace" overlay, target %, signed delta and
#     a countdown to reset (the 7d pace only advances during your active hours)
#   • tokens per model for the whole session, subagents included (top 3, the
#     rest folded), cache share and misses, tool calls and errors, turns, cost,
#     session duration and active time
#   • an optional live line of loop-review round scores (see "Optional" below)
#
# Repo:    https://github.com/termfoundry/claude-code-tally
#          built on https://github.com/tablesguru/claude-code-statusline
# License: MIT (see LICENSE)
#
# Requires: jq (mandatory) + git/awk/date/sed/stat/od (usually already present).
# POSIX sh — no bash needed. No network calls. Session totals are worked out
# from the transcript Claude Code names on stdin and kept as small running
# totals under ~/.claude/statusline-state/transcript/ (safe to delete: they
# are counted again from the transcript). Claude Code feeds session JSON on
# stdin; this script prints the status line.
# ─────────────────────────────────────────────────────────────────────────────
input=$(cat)

# Numbers in the C style (17.18, not 17,18) whatever the user's locale. The
# character locale stays, for the width of UTF-8 text; LC_ALL would override
# LC_NUMERIC, so its value moves to LC_CTYPE.
if [ -n "${LC_ALL:-}" ]; then LC_CTYPE=$LC_ALL; export LC_CTYPE; unset LC_ALL; fi
LC_NUMERIC=C; export LC_NUMERIC

# Git without optional locks: `git status` would otherwise take .git/index.lock
# for a moment to refresh the index, and a git command Claude runs at that
# moment fails with "Unable to create index.lock: File exists". `git diff`
# refreshes the index even so; the plumbing `git diff-index` never does.
GIT_OPTIONAL_LOCKS=0; export GIT_OPTIONAL_LOCKS
# Git without the repository's fsmonitor: `git status` and `git diff-index`
# would run whatever program core.fsmonitor in its .git/config names, on every
# refresh, outside Claude Code's sandbox. Empty turns it off in every git
# version (before 2.36 the setting is a hook's path).
git() { command git -c core.fsmonitor= "$@"; }

# On Windows a native jq.exe ends its lines with CR LF; the CR would break the
# arithmetic and every field read from it.
case "${OS:-}" in Windows_NT) jq() { command jq "$@" | tr -d '\r'; } ;; esac

# ── Colors (ANSI) ──────────────────────────────────────────
# Real escape characters, not "\033" text: the line is printed as it is, so a
# backslash in a folder, branch or model name is never read as a code.
ESC=$(printf '\033')
RESET="${ESC}[0m"
DIM="${ESC}[2m"
CYAN="${ESC}[36m"
GREEN="${ESC}[32m"
YELLOW="${ESC}[33m"
RED="${ESC}[31m"
BLUE="${ESC}[34m"
WHITE="${ESC}[37m"
GRAY="${RESET}${DIM}"   # empty cells use the same dim gray as the ctx/5h/7d labels

# ── Bar geometry ───────────────────────────────────────────
# All three bars share the same VISUAL width (34 columns) so the "%" column
# lines up. ctx is solid; 5h is split into 5 hour-groups (6 cells = 1 hour),
# 7d into 7 day-groups (4 cells = 1 day). Single-space separators between groups:
#   5h: 5×6 + 4 = 34   ·   7d: 7×4 + 6 = 34   ·   ctx: 34.
CTX_CELLS=34
FIVE_CELLS=30; FIVE_GROUP=6
WEEK_CELLS=28; WEEK_GROUP=4

# ── Active-hours window (7d pace) ──────────────────────────
# The weekly limit isn't spent around the clock: there's no work overnight, so
# the target pace only advances INSIDE a working window and freezes at night.
# That way daytime actual and pace grow together (no false "red"), and at night
# both stand still (no overnight "catch-up"). Window is in the machine's LOCAL
# time. Default: 10:00–22:00 (12 hours) — change to match your own hours.
ACT_START_HHMM=1000   # window start, HHMM
ACT_LEN_H=12          # window length, hours
# Leading zeros stripped, so $(( )) doesn't read 0900 as octal.
act_hhmm=$ACT_START_HHMM; while [ "${act_hhmm#0}" != "$act_hhmm" ]; do act_hhmm=${act_hhmm#0}; done
ACT_S=$(( (${act_hhmm:-0} / 100) * 3600 + (${act_hhmm:-0} % 100) * 60 ))
ACT_L=$(( ACT_LEN_H * 3600 ))

# Local-time offset from UTC in seconds (from `date +%z`, format ±HHMM).
# Strip leading zeros so $(( )) doesn't read "08"/"09" as octal.
off_raw=$(date +%z)
off_sign=$(printf '%s' "$off_raw" | cut -c1)
off_h=$(printf '%s' "$off_raw" | cut -c2-3); off_h=${off_h#0}; [ -z "$off_h" ] && off_h=0
off_m=$(printf '%s' "$off_raw" | cut -c4-5); off_m=${off_m#0}; [ -z "$off_m" ] && off_m=0
OFF=$(( off_h * 3600 + off_m * 60 ))
[ "$off_sign" = "-" ] && OFF=$(( 0 - OFF ))

# Active seconds from "local day 0" up to the moment $1 (unix ts). The
# difference of two calls = active seconds over that interval. A full 7×24h span
# yields exactly 7×ACT_L active seconds (the window is periodic, period 24h).
active_secs_until() {
  _t=$(( $1 + OFF ))
  _day=$(( _t / 86400 ))
  _sod=$(( _t - _day * 86400 ))
  _p=$(( _sod - ACT_S ))
  if [ "$_p" -lt 0 ]; then _p=0; fi
  if [ "$_p" -gt "$ACT_L" ]; then _p=$ACT_L; fi
  echo $(( _day * ACT_L + _p ))
}

# Pace bar (5h/7d): blue = actual; a gray "filler" is the headroom up to the
# target pace (same dim gray as the empty tail); red = overshoot (actual above
# pace). Groups are separated by a space every $2 cells. Result goes to RESULT.
render_pace_bar() {
  _cells=$1; _group=$2; _fact=$3; _tgt=$4
  _ff=$(( (_fact * _cells + 50) / 100 ))   # round to nearest cell, not down: 7%·28=1.96 → 2, not 1
  if [ "$_ff" -eq 0 ] && [ "$_fact" -gt 0 ]; then _ff=1; fi
  if [ "$_ff" -gt "$_cells" ]; then _ff=$_cells; fi
  _tf=$(( (_tgt * _cells + 50) / 100 ))
  if [ "$_tf" -eq 0 ] && [ "$_tgt" -gt 0 ]; then _tf=1; fi
  if [ "$_tf" -gt "$_cells" ]; then _tf=$_cells; fi
  if [ "$_tgt" -lt 3 ]; then
    # pace not meaningful yet — draw a simple bar (actual blue, tail gray)
    _b1=$_ff; _b2=$_ff; _mid=$BLUE
  elif [ "$_tf" -ge "$_ff" ]; then
    _b1=$_ff; _b2=$_tf; _mid=$GRAY
  else
    _b1=$_tf; _b2=$_ff; _mid=$RED
  fi
  _out="${BLUE}"
  _i=0
  while [ "$_i" -lt "$_cells" ]; do
    if [ "$_i" -lt "$_b1" ]; then
      _out="${_out}◼"
    elif [ "$_i" -lt "$_b2" ]; then
      if [ "$_i" -eq "$_b1" ]; then _out="${_out}${_mid}"; fi
      _out="${_out}◼"
    else
      if [ "$_i" -eq "$_b2" ]; then _out="${_out}${GRAY}"; fi
      _out="${_out}◻"
    fi
    _i=$(( _i + 1 ))
    if [ "$_i" -lt "$_cells" ] && [ $(( _i % _group )) -eq 0 ]; then
      _out="${_out} "
    fi
  done
  _out="${_out}${RESET}"
  RESULT="$_out"
}

# Pace delta: actual − target, in percentage points. Positive (actual above
# target — over pace, "behind") is red; zero/negative (within pace) is green.
# Fixed-width field (5 = "+100%") so the arrow to its right stays a neat column.
render_delta() {
  _d=$(( $1 - $2 ))
  if [ "$_d" -gt 0 ]; then _s="+${_d}%"; _c=$RED
  elif [ "$_d" -lt 0 ]; then _s="-$(( 0 - _d ))%"; _c=$GREEN
  else _s="0%"; _c=$GREEN
  fi
  DELTA_PART=" ${_c}$(printf '%-5s' "$_s")${RESET}"
}

# ── 1. Model ───────────────────────────────────────────────
model=$(printf '%s\n' "$input" | jq -r '.model.display_name // "Claude"')
# Shorten display: "Claude 3.5 Sonnet" → "Sonnet 3.5", "Claude 3 Opus" → "Opus 3", etc.
short_model=$(printf '%s\n' "$model" | sed 's/Claude //' | sed 's/ *(.*)//')

# ── 2. Context bar (solid) ─────────────────────────────────
used=$(printf '%s\n' "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  filled=$(( (used_int * CTX_CELLS + 50) / 100 ))
  if [ "$filled" -eq 0 ] && [ "$used_int" -gt 0 ]; then filled=1; fi
  if [ "$filled" -gt "$CTX_CELLS" ]; then filled=$CTX_CELLS; fi
  # Zoned fill: each cell is colored by its POSITION in the bar, not all one
  # color. On a 1M window the ≈150k and ≈200k marks are where a session starts
  # to get expensive:
  #   cells [0, green_end)       → green  (< 15%)
  #   cells [green_end, yel_end) → yellow (15–20%)
  #   cells [yel_end, …)         → red    (≥ 20%)
  green_end=$(( 15 * CTX_CELLS / 100 ))
  yel_end=$(( 20 * CTX_CELLS / 100 ))
  bar=""
  cur=""
  i=0
  while [ "$i" -lt "$CTX_CELLS" ]; do
    if [ "$i" -lt "$filled" ]; then
      if [ "$i" -lt "$green_end" ]; then z="$GREEN"
      elif [ "$i" -lt "$yel_end" ]; then z="$YELLOW"
      else z="$RED"
      fi
      if [ "$z" != "$cur" ]; then bar="${bar}${z}"; cur="$z"; fi
      bar="${bar}◼"
    else
      if [ "$cur" != "$GRAY" ]; then bar="${bar}${GRAY}"; cur="$GRAY"; fi
      bar="${bar}◻"
    fi
    i=$(( i + 1 ))
  done
  bar="${bar}${RESET}"
  # Percentage color — by the zone the current value sits in.
  if [ "$used_int" -ge 20 ]; then
    ctx_color="$RED"
  elif [ "$used_int" -ge 15 ]; then
    ctx_color="$YELLOW"
  else
    ctx_color="$GREEN"
  fi
  if [ "$used_int" -ge 75 ]; then
    ctx_warn=" ⚠"
  else
    ctx_warn=""
  fi
  # Right-align the percentage in a 4-char field ("100%") so it lines up in a
  # neat column with the 5h/7d percentages.
  ctx_pct=$(printf '%4s' "${used_int}%")
  ctx_part="${bar} ${ctx_color}${ctx_pct}${ctx_warn}${RESET}"
else
  ctx_part="${DIM}—${RESET}"
fi

# ── 2b. 5h rate limit bar (pace — wall clock, 18000s) ─────
five_pct_inline=$(printf '%s\n' "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
# Whole seconds only: the value goes into $(( )), where a fraction ends dash and
# bash would run a command named in an expression.
five_reset=$(printf '%s\n' "$input" | jq -r '.rate_limits.five_hour.resets_at // empty | numbers | floor' 2>/dev/null)
case "$five_reset" in *[!0-9]*) five_reset="" ;; esac
now_ts=$(date +%s)
five_part=""
if [ -n "$five_pct_inline" ]; then
  five_int_inline=$(printf "%.0f" "$five_pct_inline")
  # Past the reset a new window has begun with nothing used: Claude Code keeps
  # the old figures until the next response.
  if [ -n "$five_reset" ] && [ "$five_reset" -le "$now_ts" ]; then five_int_inline=0; five_reset=""; fi
  reset_part=""
  five_target=0
  if [ -n "$five_reset" ]; then
    diff=$(( five_reset - now_ts ))
    if [ "$diff" -gt 0 ]; then
      r_h=$(( diff / 3600 ))
      r_m=$(( (diff % 3600) / 60 ))
      reset_part=" →${r_h}:$(printf "%02d" "$r_m")"
    fi
    # "Pace" target: what % an even burn would have reached in the 5h window.
    # elapsed = window − remaining; target = elapsed/window.
    five_remaining=$diff
    if [ "$five_remaining" -lt 0 ]; then five_remaining=0; fi
    if [ "$five_remaining" -gt 18000 ]; then five_remaining=18000; fi
    five_target=$(( (18000 - five_remaining) * 100 / 18000 ))
  fi
  render_pace_bar "$FIVE_CELLS" "$FIVE_GROUP" "$five_int_inline" "$five_target"
  five_bar="$RESULT"
  five_target_part=""
  five_delta_part=""
  if [ -n "$five_reset" ]; then
    # Left-align the parenthesis in a 6-char field ("(100%)").
    five_target_part=" $(printf '%-6s' "(${five_target}%)")"
    render_delta "$five_int_inline" "$five_target"
    five_delta_part="$DELTA_PART"
  fi
  five_pct=$(printf '%4s' "${five_int_inline}%")
  five_part="${five_bar} ${BLUE}${five_pct}${RESET}${DIM}${five_target_part}${RESET}${five_delta_part}${DIM}${reset_part}${RESET}"
fi

# ── 2c. 7-day rate limit bar (pace — active hours) ────────
week_pct_inline=$(printf '%s\n' "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_reset_inline=$(printf '%s\n' "$input" | jq -r '.rate_limits.seven_day.resets_at // empty | numbers | floor' 2>/dev/null)
case "$week_reset_inline" in *[!0-9]*) week_reset_inline="" ;; esac
week_part=""
if [ -n "$week_pct_inline" ]; then
  week_int_inline=$(printf "%.0f" "$week_pct_inline")
  if [ -n "$week_reset_inline" ] && [ "$week_reset_inline" -le "$now_ts" ]; then week_int_inline=0; week_reset_inline=""; fi
  week_reset_part=""
  week_target=0
  if [ -n "$week_reset_inline" ]; then
    week_diff=$(( week_reset_inline - now_ts ))
    if [ "$week_diff" -gt 0 ]; then
      wr_d=$(( week_diff / 86400 ))
      wr_h=$(( (week_diff % 86400) / 3600 ))
      if [ "$wr_d" -gt 0 ]; then
        week_reset_part=" →${wr_d}d${wr_h}h"
      else
        wr_m=$(( (week_diff % 3600) / 60 ))
        week_reset_part=" →${wr_h}:$(printf "%02d" "$wr_m")"
      fi
    fi
    # Target pace by ACTIVE hours: the share of the window's active seconds that
    # have elapsed by "now". total = 7×ACT_L; night hours never enter the sum.
    window_start=$(( week_reset_inline - 604800 ))
    aw_start=$(active_secs_until "$window_start")
    aw_now=$(active_secs_until "$now_ts")
    active_elapsed=$(( aw_now - aw_start ))
    if [ "$active_elapsed" -lt 0 ]; then active_elapsed=0; fi
    total_active=$(( 7 * ACT_L ))
    if [ "$active_elapsed" -gt "$total_active" ]; then active_elapsed=$total_active; fi
    week_target=$(( active_elapsed * 100 / total_active ))
  fi
  render_pace_bar "$WEEK_CELLS" "$WEEK_GROUP" "$week_int_inline" "$week_target"
  week_bar="$RESULT"
  week_target_part=""
  week_delta_part=""
  if [ -n "$week_reset_inline" ]; then
    week_target_part=" $(printf '%-6s' "(${week_target}%)")"
    render_delta "$week_int_inline" "$week_target"
    week_delta_part="$DELTA_PART"
  fi
  week_pct=$(printf '%4s' "${week_int_inline}%")
  week_part="${week_bar} ${BLUE}${week_pct}${RESET}${DIM}${week_target_part}${RESET}${week_delta_part}${DIM}${week_reset_part}${RESET}"
fi

# ── 3. Git: ⎇ branch ↑ahead ↓behind, then +added −removed in Nf ●staged ✚unstaged ?untracked
cwd=$(printf '%s\n' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
git_part=""
git_diff_part=""
if [ -n "$cwd" ] && git_status=$(git -C "$cwd" status --porcelain=v2 --branch 2>/dev/null); then
  # head ahead behind staged unstaged untracked (a detached head shows its short sha)
  set -- $(printf '%s\n' "$git_status" | awk '
    /^# branch.oid /  { oid = $3 }
    /^# branch.head / { head = $3 }
    /^# branch.ab /   { a = $3; b = $4; sub(/^\+/, "", a); sub(/^-/, "", b) }
    /^[12] /          { if (substr($2, 1, 1) != ".") st++; if (substr($2, 2, 1) != ".") un++ }
    /^u /             { un++ }
    /^\? /            { ut++ }
    END { if (head == "(detached)") head = substr(oid, 1, 7); printf "%s %d %d %d %d %d\n", head, a, b, st, un, ut }')
  g_head=$1 g_ahead=$2 g_behind=$3 g_staged=$4 g_unstaged=$5 g_untracked=$6
  # lines added, removed, files changed against HEAD (staged and unstaged together)
  set -- $(git -C "$cwd" diff-index -M --numstat HEAD 2>/dev/null | awk '
    { f++; if ($1 != "-") ad += $1; if ($2 != "-") rm += $2 }
    END { printf "%d %d %d\n", ad, rm, f }')
  g_added=$1 g_removed=$2 g_files=$3

  git_part="${BLUE}⎇ ${g_head}${RESET}"
  [ "$g_ahead" -gt 0 ] && git_part="${git_part}${YELLOW} ↑${g_ahead}${RESET}"
  [ "$g_behind" -gt 0 ] && git_part="${git_part}${YELLOW} ↓${g_behind}${RESET}"
  if [ "$g_files" -eq 0 ] && [ "$g_untracked" -eq 0 ]; then
    git_diff_part="${DIM}clean${RESET}"
  else
    git_diff_part="${GREEN}+${g_added}${RESET} ${RED}−${g_removed}${RESET}${DIM} in ${g_files}f${RESET}"
    [ "$g_staged" -gt 0 ] && git_diff_part="${git_diff_part} ${GREEN}●${g_staged}${RESET}"
    [ "$g_unstaged" -gt 0 ] && git_diff_part="${git_diff_part} ${YELLOW}✚${g_unstaged}${RESET}"
    [ "$g_untracked" -gt 0 ] && git_diff_part="${git_diff_part} ${DIM}?${g_untracked}${RESET}"
  fi
fi

# ── 4. Tokens in the context ──────────────────────────────
# The last request's input (fresh + cache read + cache write): the count
# used_percentage comes from, so the two always agree. The last reply's output
# joins the context only with the next request.
ctx_tokens=$(printf '%s\n' "$input" | jq -r '.context_window.total_input_tokens // empty | numbers | floor' 2>/dev/null)
case "$ctx_tokens" in ''|*[!0-9]*) ctx_tokens=0 ;; esac
# 63855 → "64k", 1000000 → "1M", 1500000 → "1.5M"
tokens_short() {
  awk -v n="$1" 'BEGIN { if (n >= 999500) { s = sprintf("%.1f", n / 1000000); sub(/\.0$/, "", s); print s "M" } else if (n >= 1000) print int(n / 1000 + 0.5) "k"; else print n }'
}

# ── 5. Session duration ───────────────────────────────────
# How long the session has been open: Claude Code's total_duration_ms, added up
# across resumes, without the time it was closed. When it is missing (older
# Claude Code), the time since the transcript began.
elapsed=$(printf '%s\n' "$input" | jq -r '.cost.total_duration_ms // empty | numbers | . / 1000 | floor' 2>/dev/null)
case "$elapsed" in ''|*[!0-9]*) elapsed="" ;; esac
transcript=$(printf '%s\n' "$input" | jq -r '.transcript_path // empty')
if [ -z "$elapsed" ] && [ -n "$transcript" ] && [ -f "$transcript" ]; then
  # When the session began: the transcript's first timestamp (UTC, as
  # 2026-10-15T12:46:45.409Z), turned into seconds by plain arithmetic (the
  # days-from-civil formula), not jq's date functions, which jq 1.6 gets an
  # hour wrong under daylight saving time. Else the file's creation time:
  # `stat -f %B` (BSD, macOS), then `stat -c %W` (GNU, 0 when unknown). GNU
  # stat reads `-f` as "file system" and prints a report, so only a plain
  # number is accepted.
  start_ts=$(head -n 200 "$transcript" | jq -rR '
    fromjson? | .timestamp // empty | strings
    | select(length >= 19 and .[4:5] == "-" and .[7:8] == "-" and .[10:11] == "T" and .[13:14] == ":" and .[16:17] == ":")
    | (.[0:4] | tonumber) as $Y | (.[5:7] | tonumber) as $M | (.[8:10] | tonumber) as $D
    | (if $M <= 2 then $Y - 1 else $Y end) as $y
    | (($y / 400) | floor) as $era | ($y - $era * 400) as $yoe
    | ((((153 * (($M + 9) % 12)) + 2) / 5 | floor) + $D - 1) as $doy
    | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy) as $doe
    | (($era * 146097 + $doe - 719468) * 86400
       + (.[11:13] | tonumber) * 3600 + (.[14:16] | tonumber) * 60 + (.[17:19] | tonumber))' 2>/dev/null | head -n 1)
  case "$start_ts" in
    ''|*[!0-9]*) start_ts=$(stat -f "%B" "$transcript" 2>/dev/null)
      case "$start_ts" in ''|*[!0-9]*) start_ts=$(stat -c "%W" "$transcript" 2>/dev/null) ;; esac ;;
  esac
  case "$start_ts" in ''|0|*[!0-9]*) start_ts="" ;; esac
  now_ts=$(date +%s)
  [ -n "$start_ts" ] && elapsed=$(( now_ts - start_ts ))
fi
dur_part=""
if [ -n "$elapsed" ]; then
  hours=$(( elapsed / 3600 ))
  mins=$(( (elapsed % 3600) / 60 ))
  if [ "$hours" -gt 0 ]; then
    dur_part="${DIM}⏱ ${hours}h${mins}m${RESET}"
  else
    dur_part="${DIM}⏱ ${mins}m${RESET}"
  fi
fi

# ── 6. CWD (last folder) ──────────────────────────────────
if [ -n "$cwd" ]; then
  folder=$(basename "$cwd")
  dir_part="${BLUE}~/${folder}${RESET}"
else
  dir_part=""
fi

# ── Assemble (column layout, one block per line) ──────────
NL='
'

# ── 7. Session totals, worked out from the transcript ─────
# The session JSON gives the transcript's path but no running totals, so they
# are summed here: tokens per model (each API response once), tool calls and
# errors, prompts typed, turn times. Subagent transcripts count too. Only what
# was appended since the last refresh is read: the totals so far are kept per
# transcript file under $HOME/.claude/statusline-state/transcript/.
ST_DIR="$HOME/.claude/statusline-state/transcript"
# Events, one per row: A(ssistant response) id model in cache_read cache_write out tool_uses,
# R(esults) count errors, P(rompt typed) ms, B(ang: a `!` command) ms, T(urn) duration_ms end_ms,
# X (an interrupt) ms, M(ode) name,
# each row first giving its time as Z(time) ms. Times are the rows' UTC
# timestamps in milliseconds (same arithmetic as the session start above);
# end_ms is empty when the row has none.
JQ_EVENTS='def epoch_ms:
    strings
    | select(length >= 19 and .[4:5] == "-" and .[7:8] == "-" and .[10:11] == "T" and .[13:14] == ":" and .[16:17] == ":")
    | (.[0:4] | tonumber) as $Y | (.[5:7] | tonumber) as $M | (.[8:10] | tonumber) as $D
    | (if $M <= 2 then $Y - 1 else $Y end) as $y
    | (($y / 400) | floor) as $era | ($y - $era * 400) as $yoe
    | ((((153 * (($M + 9) % 12)) + 2) / 5 | floor) + $D - 1) as $doy
    | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy) as $doe
    | (.[20:23] | if length == 3 and (explode | all(. >= 48 and . <= 57)) then tonumber else 0 end) as $ms
    | ((($era * 146097 + $doe - 719468) * 86400
        + (.[11:13] | tonumber) * 3600 + (.[14:16] | tonumber) * 60 + (.[17:19] | tonumber)) * 1000 + $ms);
fromjson? // empty
  | ((.timestamp | epoch_ms) // empty | "Z\t\(.)"),
  # Each row that counts has a uuid (U): where the reading is, should rows
  # before it be taken out.
  (.uuid | strings | "U\t\(.)"),
  # Each prompt typed carries the permission mode; Claude Code writes its
  # permission-mode rows only now and then, so either can be the latest.
  (if .type == "user" and (.isSidechain | not) and .origin.kind == "human" and (.permissionMode | type) == "string"
   then "M\t\(.permissionMode)" else empty end),
  (if .type == "assistant" and .message.usage != null then
      ["A", (.message.id // ""), (.message.model // "?"),
       (.message.usage.input_tokens // 0), (.message.usage.cache_read_input_tokens // 0),
       (.message.usage.cache_creation_input_tokens // 0), (.message.usage.output_tokens // 0),
       ([.message.content[]? | select(.type == "tool_use")] | length)] | @tsv
    elif .type == "user" then
      # Tool results count in every transcript (subagents too); prompts only
      # when typed in the main conversation. Claude Code marks those with
      # origin "human" (typed, a suggestion taken, or queued); a background
      # task reporting back, a message from another session, a compaction
      # summary and the output of a `!` command are not prompts; the `!`
      # command itself is one when Claude answers it (B: decided later on).
      # A slash command typed that runs the model (a skill, /code-review) is
      # one; a local one (/model, /effort) has no origin. Older transcripts have
      # no origin at all: there the text decides.
      .message.content as $c
      | ((.isSidechain | not) and (.isMeta | not) and (.isCompactSummary | not)
         and (.origin == null or .origin.kind == "human")) as $typed
      | ["P", ((.timestamp | epoch_ms) // "")] as $p
      # An interrupt (Esc, or a new prompt cutting in) ends the turn: Claude
      # Code times no such turn.
      | ["X", ((.timestamp | epoch_ms) // "")] as $x
      | if ($c | type) == "array" then
          [$c[]? | select(.type == "tool_result")] as $r
          | if ($r | length) > 0 then ["R", ($r | length), ([$r[] | select(.is_error == true)] | length)] | @tsv
            elif $typed and ([$c[]? | select(.type == "text" and ((.text // "") | startswith("[Request interrupted") | not))] | length) > 0 then $p | @tsv
            elif (.isSidechain | not) and ([$c[]? | select(.type == "text" and ((.text // "") | startswith("[Request interrupted")))] | length) > 0 then $x | @tsv
            else empty end
        elif $typed and ($c | type) == "string"
             and ((.origin.kind == "human" and ($c | startswith("<command-")))
                  or (($c | startswith("<command-") or startswith("<local-command") or startswith("[Request interrupted")
                       or startswith("<bash-") or startswith("<task-notification")) | not)) then $p | @tsv
        elif $typed and ($c | type) == "string" and ($c | startswith("<bash-input>")) then ["B", ((.timestamp | epoch_ms) // "")] | @tsv
        elif (.isSidechain | not) and ($c | type) == "string" and ($c | startswith("[Request interrupted")) then $x | @tsv
        else empty end
    # A prompt typed while Claude works and taken into the turn under way: no
    # user row, only this note. A turn of its own, but not where one starts.
    elif .type == "attachment" and (.isSidechain | not) and .attachment.type == "queued_command"
         and .attachment.origin.kind == "human" and (.attachment.commandMode // "prompt") == "prompt" then "P\t"
    elif .type == "system" and .subtype == "turn_duration" then ["T", (.durationMs // 0), ((.timestamp | epoch_ms) // "")] | @tsv
    elif .type == "permission-mode" and (.isSidechain | not) then ["M", (.permissionMode // "")] | @tsv
    else empty end)'

# Brings one transcript's totals up to date; prints its state file's path.
# Always run in a subshell, as $(tally_file …): its trap and loop stay there.
# The transcript is read in pieces of at most CHUNK_MAX bytes, and the totals
# are saved after each one: Claude Code cancels a refresh that is still
# running when the next one starts, so a long first read keeps what it has
# done instead of starting over every time.
CHUNK_MAX=4194304
# The $3 (default 16) bytes of file $1 before offset $2, in hex.
tailhex() { [ "$2" -ge "${3:-16}" ] && tail -c +$(( $2 - ${3:-16} + 1 )) "$1" | head -c "${3:-16}" | od -An -tx1 | tr -d ' \n'; }
tally_file() {
  _f=$1
  # Named after its path below the project folder (SL_BASE_S, sed as here):
  # the session's id first, so a transcript Claude Code moves to another
  # project folder (/cd, a worktree) keeps its totals.
  _st=$(printf '%s' "$_f" | sed 's#[^A-Za-z0-9._-]#_#g'); _st="$ST_DIR/${_st#"$SL_BASE_S"}.tsv"
  _snap=""; _chunk=""; _new=""; _t=""
  # Its temp files go when it ends or is stopped. The stop removes them itself:
  # a stop that lands inside $(( )) is an error that ends dash at once,
  # skipping the EXIT trap.
  on_stop() { rm -f "$_snap" "$_chunk" "$_new" "$_t"; exit 1; }
  trap 'rm -f "$_snap" "$_chunk" "$_new" "$_t"' EXIT
  trap on_stop HUP INT TERM
  # A temp file made while a stop could come in before its name is known: a
  # stop in that moment is held until mktemp is done and the name is in _t
  # (mktemp itself ignores it, so it never dies with the file made).
  maketemp() {
    _stop=""; trap '_stop=1' HUP INT TERM
    _t=$(trap '' HUP INT TERM; mktemp "$1" 2>/dev/null); _rc=$?
    trap on_stop HUP INT TERM; [ -n "$_stop" ] && on_stop
    return $_rc
  }
  [ -f "$_st" ] || : > "$_st"
  while :; do
    # One private snapshot of the totals so far: the offset and the totals both
    # come from it, so a refresh running at the same time can't slip in between.
    maketemp "${TMPDIR:-/tmp}/statusline-snap.XXXXXX" || break
    _snap=$_t; _t=""
    cp "$_st" "$_snap" 2>/dev/null || : > "$_snap"
    # A state file from an older layout is counted again from the start.
    [ "$(awk -F'\t' '$1 == "version" { print $2 }' "$_snap")" = "9" ] || : > "$_snap"
    # offset, then tail (the 16 bytes before it, in hex) and row (the uuid of
    # the last row read with one); the - keeps an empty one in its place
    set -- $(awk -F'\t' '$1 == "offset" { o = $2 } $1 == "tail" { t = $2; r = $3 } END { print o + 0, t "-", r "-" }' "$_snap")
    _off=$1; _tail=${2%-}; _row=${3%-}; _moved=""
    _size=$(wc -c < "$_f" | tr -d ' ')
    # Claude Code now and then takes a row out of the transcript (a reply it
    # tried again): it got smaller, or the bytes before the offset are others.
    # The reading goes on after the last row read, where that row is now, the
    # one taken out staying counted; with that row gone too, or no row known,
    # it is all counted again.
    if [ "$_size" -lt "$_off" ] || { [ "$_size" -gt "$_off" ] && [ -n "$_tail" ] && [ "$(tailhex "$_f" "$_off")" != "$_tail" ]; }; then
      _at=""
      # Where that row's line ends, in bytes (awk: BusyBox grep has no -b)
      [ -n "$_row" ] && _at=$(LC_ALL=C awk -v k="\"uuid\":\"$_row\"" 'index($0, k) { printf "%.0f\n", n + length($0) + 1; exit } { n += length($0) + 1 }' "$_f")
      [ -n "$_at" ] && { [ "$(tailhex "$_f" "$_at" 1)" = "0a" ] || _at=""; }
      if [ -n "$_at" ]; then _off=$_at; _moved=1; else : > "$_snap"; _off=0; fi
    fi
    if [ "$_size" -gt "$_off" ]; then
      _len=$(( _size - _off )); [ "$_len" -gt "$CHUNK_MAX" ] && _len=$CHUNK_MAX
      maketemp "${TMPDIR:-/tmp}/statusline-chunk.XXXXXX" || break
      _chunk=$_t; _t=""
      tail -c +$(( _off + 1 )) "$_f" | head -c "$_len" > "$_chunk"
      # A last line still being written (or cut off at the end of the piece)
      # waits for the next round. A single line longer than a whole piece is a
      # piece of its own, read to its end.
      if [ "$(tail -c 1 "$_chunk" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then _used=$_len
      else _used=$(( _len - $(tail -n 1 "$_chunk" | LC_ALL=C wc -c | tr -d ' ') )); fi
      if [ "$_used" -le 0 ] && [ "$_len" -lt $(( _size - _off )) ]; then
        tail -c +$(( _off + 1 )) "$_f" | head -n 1 > "$_chunk"
        _len=$(LC_ALL=C wc -c < "$_chunk" | tr -d ' ')
        if [ "$(tail -c 1 "$_chunk" | od -An -tx1 | tr -d ' \n')" = "0a" ]; then _used=$_len; else _used=0; fi
      fi
      [ "$_used" -gt 0 ] || break
    elif [ -n "$_moved" ]; then _used=0   # nothing new: only the new place is saved
    else break; fi
    # The new totals go to a file of their own, then replace the old ones in one
    # step, so two refreshes at once never write into the same file.
    if maketemp "$_st.XXXXXX"; then _new=$_t; else _new="$_st.$$"; fi; _t=""
    # cap: 15 minutes, the longest stretch without a row that counts as work.
    { [ "$_used" -gt 0 ] && head -c "$_used" "$_chunk"; } | jq -rR "$JQ_EVENTS" 2>/dev/null | awk -F'\t' -v st="$_snap" -v off=$(( _off + _used )) -v tail="$(tailhex "$_f" $(( _off + _used )))" -v cap=900000 '
      # Lists of stretches of time, as start:end in ms, comma separated.
      function add(l, x) { return x == "" ? l : (l == "" ? x : l "," x) }
      # The parts of the stretches in l that fall between a and b.
      function clip(l, a, b,   n, i, x, y, r) {
        r = ""; n = split(l, I, ",")
        for (i = 1; i <= n; i++) {
          split(I[i], J, ":"); x = J[1] + 0; y = J[2] + 0
          if (x < a) x = a
          if (y > b) y = b
          if (y > x) r = add(r, sprintf("%.0f:%.0f", x, y))
        }
        return r
      }
      # The stretches in l that end after t.
      function after(l, t,   n, i, r) {
        r = ""; n = split(l, I, ",")
        for (i = 1; i <= n; i++) { split(I[i], J, ":"); if (J[2] + 0 > t) r = add(r, I[i]) }
        return r
      }
      FILENAME == st {
        if ($1 == "last") { lastid = $2; lk = $3; lin = $4; lrd = $5; lwr = $6; lout = $7 }
        else if ($1 == "turns") turns = $2
        else if ($1 == "tail") row = $3
        else if ($1 == "tools") { tools = $2; terr = $3 }
        else if ($1 == "tdur") { tlast = $2; tsum = $3; tend = $4; pt = $5 }
        else if ($1 == "idle") { zlast = $2 + 0; idle = $3 }
        else if ($1 == "cov") { cs = $2 + 0; cov = $3 }
        else if ($1 == "cand") cand = $2
        else if ($1 == "lastcand") lastcand = $2
        else if ($1 == "mode") mode = $2
        else if ($1 == "bang") { inturn = $2; bang = $3 }
        else if ($1 == "m") { k = $2; order[++nm] = k; req[k] = $3; tin[k] = $4; rd[k] = $5; wr[k] = $6; out[k] = $7 }
        next
      }
      $1 == "Z" {
        # The times this transcript was writing: a stretch with no row for
        # longer than cap (the computer asleep, a wait for a usage limit to
        # reset or for an answer to a permission prompt) is idle after its
        # first cap. cov holds the stretches covered (each row and the cap
        # after it; cs starts the open one), idle the idle ones.
        if (zlast > 0 && $2 - zlast > cap) {
          idle = add(idle, sprintf("%.0f:%.0f", zlast + cap, $2)); cov = add(cov, sprintf("%.0f:%.0f", cs, zlast + cap)); cs = $2
        }
        if (zlast == 0) cs = $2
        if ($2 > zlast) zlast = $2
        next
      }
      $1 == "M" { mode = $2; next }
      $1 == "U" { row = $2; next }
      # A `!` command typed while Claude was idle is a turn once Claude answers
      # it, before any other prompt; bang is its time, inturn whether Claude
      # is at work (from its first response to the end of the turn).
      $1 == "B" { if (!inturn) bang = ($2 != "") ? $2 + 0 : -1; next }
      $1 == "A" {
        if (bang) { turns++; if (bang > 0) pt = bang; bang = 0 }
        inturn = 1
        tools += $8
        # One response spread over several rows: counted once, the last row`s usage
        # (the final output count) replacing what the earlier rows put in.
        if ($2 != "" && $2 == lastid) {
          if (lk != "") { tin[lk] += $4 - lin; rd[lk] += $5 - lrd; wr[lk] += $6 - lwr; out[lk] += $7 - lout }
          lin = $4; lrd = $5; lwr = $6; lout = $7
          next
        }
        lastid = $2; k = $3
        if (k ~ /^</) { lk = ""; next }       # <synthetic>: no model was called
        lk = k; lin = $4; lrd = $5; lwr = $6; lout = $7
        if (!(k in req)) order[++nm] = k
        req[k]++; tin[k] += $4; rd[k] += $5; wr[k] += $6; out[k] += $7
        next
      }
      $1 == "R" { terr += $3; next }
      $1 == "P" { turns++; if ($2 != "") pt = $2 + 0; bang = 0; next }
      # An interrupted turn has no time from Claude Code: it runs from its
      # prompt to the interrupt, and the rule below times it as a turn.
      $1 == "X" {
        inturn = 0
        if ($2 == "" || !(pt > tend && pt < $2 + 0)) next
        $3 = $2; $2 = $3 - pt; $1 = "T"
      }
      $1 == "T" {
        # Active time counts each moment once: each turn counts from where the
        # turn before it ended (tend). A turn that resumes after a background
        # agent reports back is timed from the same prompt as the turn before
        # it, so only its new part is added. The idle parts of what is added
        # go to cand: the summary takes off those no subagent was writing in.
        # idle is kept while turns reach back into the stretch since the last
        # one that started after tend, for the time of the last turn.
        inturn = 0
        if ($3 == "") { tlast = $2; tsum += $2; lastcand = ""; next }
        s = $3 - $2; e = $3
        # A turn after a new prompt (pt) is timed from that prompt. The time
        # Claude Code gives can reach back to an older prompt, over the time
        # away before this one, or leave out a wait for an answer to a question.
        if (pt > tend && pt < e) s = pt
        if (s >= tend) idle = after(idle, tend)
        from = (s > tend) ? s : tend
        if (e > from) { tsum += e - from; cand = add(cand, clip(idle, from, e)) }
        if (e > tend) tend = e
        tlast = e - s; lastcand = clip(idle, s, e)
        next
      }
      END {
        print "version\t9"; print "offset\t" off; print "tail\t" tail "\t" row
        print "mode\t" mode; printf "bang\t%d\t%.0f\n", inturn, bang
        print "last\t" lastid "\t" lk "\t" lin + 0 "\t" lrd + 0 "\t" lwr + 0 "\t" lout + 0
        print "turns\t" turns + 0
        print "tools\t" tools + 0 "\t" terr + 0; printf "tdur\t%.0f\t%.0f\t%.0f\t%.0f\n", tlast, tsum, tend, pt
        printf "idle\t%.0f\t%s\n", zlast, idle; printf "cov\t%.0f\t%s\n", cs, cov
        print "cand\t" cand; print "lastcand\t" lastcand
        for (i = 1; i <= nm; i++) { k = order[i]; print "m\t" k "\t" req[k] "\t" tin[k] "\t" rd[k] "\t" wr[k] "\t" out[k] }
      }' "$_snap" - > "$_new" && mv "$_new" "$_st" || break
    rm -f "$_chunk" "$_snap"
    _chunk=""; _snap=""; _new=""
  done
  rm -f "$_snap" "$_chunk" "$_new"
  printf '%s\n' "$_st"
}

models_line=""; last_turn=""; turns_n=""; tools_part=""; active_part=""
transcript_path=$(printf '%s\n' "$input" | jq -r '.transcript_path // empty')
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && mkdir -p "$ST_DIR" 2>/dev/null; then
  # The project folder, as it appears at the start of a state file's name
  SL_BASE_S=$(printf '%s/' "${transcript_path%/*}" | sed 's#[^A-Za-z0-9._-]#_#g')
  main_st=$(tally_file "$transcript_path")
  # Subagents: the Agent tool's, and one level deeper those of Workflow runs
  # (beside their journal.jsonl, which is no transcript). Most have finished
  # and never grow again: one wc and one awk pick out those whose saved totals
  # are behind, and only those are read (a tally_file each would add some 15 ms
  # per subagent to every refresh).
  # (Both patterns in one go: adding the files one by one, as set -- "$@" x,
  # takes a second for 500 of them. A pattern that matches nothing stays as
  # it is: wc skips it and it is never read.)
  set -- "${transcript_path%.jsonl}"/subagents/*.jsonl "${transcript_path%.jsonl}"/subagents/workflows/*/agent-*.jsonl
  # Per subagent: + (behind) or -, its state file, its transcript
  subs_state=$(wc -c "$@" 2>/dev/null | SL_SUBS=$(printf '%s\n' "$@") SL_NAMES=$(printf '%s\n' "$@" | sed 's#[^A-Za-z0-9._-]#_#g') SL_BASE_S=$SL_BASE_S ST_DIR=$ST_DIR awk '
    BEGIN {
      n = split(ENVIRON["SL_SUBS"], P, "\n"); split(ENVIRON["SL_NAMES"], N, "\n"); b = ENVIRON["SL_BASE_S"]
      for (i = 1; i <= n; i++) { at[P[i]] = i; if (index(N[i], b) == 1) N[i] = substr(N[i], length(b) + 1) }
    }
    { p = $0; sub(/^[ \t]*[0-9]+[ \t]/, "", p); if (p in at) size[at[p]] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        sf = ENVIRON["ST_DIR"] "/" N[i] ".tsv"; v = ""; o = ""
        while ((getline l < sf) > 0) { split(l, F, "\t"); if (F[1] == "version") v = F[2]; else if (F[1] == "offset") o = F[2] }
        close(sf)
        print ((v == "9" && o != "" && o == size[i]) ? "-" : "+") "\t" sf "\t" P[i]
      }
    }')
  while IFS='	' read -r behind sf sub; do
    [ "$behind" = "+" ] && [ -f "$sub" ] && sf=$(tally_file "$sub")
  done <<EOF
$subs_state
EOF
  model_id=$(printf '%s\n' "$input" | jq -r '.model.id // empty')
  cache_misses=$(printf '%s\n' "$input" | jq -r '.prompt_cache.misses // 0')
  # Totals over the main transcript and its subagents. Prints 7 lines: models line
  # (the main model, then the two largest others, the rest folded), tool calls,
  # tool errors, prompts typed, last turn ms, turns ms summed, permission mode.
  # Turn times lose their idle parts (cand) except where a subagent was
  # writing: its covered stretches (cov, and the open one from cs) count.
  # The state files are opened by awk itself (those that exist), the main one first.
  summary=$(SL_MAIN=$main_st SL_FILES=$(printf '%s\n' "$main_st"; printf '%s\n' "$subs_state" | cut -f2) awk -F'\t' -v cur="$model_id" -v misses="$cache_misses" -v E="$(printf '\033')" -v cap=900000 '
    # The length of the stretches in l (start:end, comma separated) that no
    # stretch in busy covers.
    function uncovered(l,   n, i, m, j, k, c, x, y, a, b, q, r, t) {
      t = 0; n = split(l, I, ","); m = split(busy, B, ",")
      for (i = 1; i <= n; i++) {
        split(I[i], J, ":"); c = 1; px[1] = J[1] + 0; py[1] = J[2] + 0
        for (j = 1; j <= m; j++) {
          split(B[j], K, ":"); x = K[1] + 0; y = K[2] + 0; q = 0
          for (k = 1; k <= c; k++) {
            a = px[k]; b = py[k]
            if (y <= a || x >= b) { q++; nx[q] = a; ny[q] = b; continue }
            if (a < x) { q++; nx[q] = a; ny[q] = x }
            if (y < b) { q++; nx[q] = y; ny[q] = b }
          }
          c = q; for (k = 1; k <= c; k++) { px[k] = nx[k]; py[k] = ny[k] }
        }
        for (k = 1; k <= c; k++) t += py[k] - px[k]
      }
      return t
    }
    function pretty(m,  s, n, p, o, long) {
      long = (m ~ /\[1m\]$/); sub(/\[1m\]$/, "", m)
      s = m; sub(/^claude-/, "", s); n = split(s, p, "-")
      # Older IDs put the number first: claude-3-5-sonnet-20241022 is Sonnet 3.5.
      if (n >= 2 && p[1] ~ /^[0-9]+$/ && p[2] !~ /^[0-9]+$/) return toupper(substr(p[2], 1, 1)) substr(p[2], 2) " " p[1] (long ? " 1M" : "")
      if (n >= 3 && p[1] ~ /^[0-9]+$/ && p[2] ~ /^[0-9]$/ && p[3] !~ /^[0-9]+$/) return toupper(substr(p[3], 1, 1)) substr(p[3], 2) " " p[1] "." p[2] (long ? " 1M" : "")
      if (n >= 2 && p[2] ~ /^[0-9]+$/) {
        o = toupper(substr(p[1], 1, 1)) substr(p[1], 2) " " p[2]
        if (n >= 3 && p[3] ~ /^[0-9][0-9]?$/) o = o "." p[3]
      } else o = m
      return o (long ? " 1M" : "")
    }
    function tok(n,  s) {
      if (n >= 1000000) { s = sprintf("%.1f", n / 1000000); sub(/\.0$/, "", s); return s "M" }
      if (n >= 1000) return int(n / 1000 + 0.5) "k"
      return n ""
    }
    BEGIN {
      main = ENVIRON["SL_MAIN"]; n = split(ENVIRON["SL_FILES"], F, "\n")
      for (i = 1; i <= n; i++) if (F[i] != "" && (getline t < F[i]) >= 0) { close(F[i]); ARGV[ARGC++] = F[i] }
    }
    $1 == "m" { k = $2; if (!(k in req)) order[++nm] = k; req[k] += $3; tin[k] += $4; rd[k] += $5; wr[k] += $6; out[k] += $7; next }
    $1 == "tools" { tools += $2; terr += $3; next }
    FILENAME == main && $1 == "turns" { turns = $2; next }
    FILENAME == main && $1 == "tdur" { tlast = $2; tsum = $3; next }
    FILENAME == main && $1 == "cand" { cand = $2; next }
    FILENAME == main && $1 == "lastcand" { lastcand = $2; next }
    FILENAME != main && $1 == "idle" { zl = $2 + 0; next }
    FILENAME != main && $1 == "cov" {
      if ($3 != "") busy = busy (busy == "" ? "" : ",") $3
      if (zl > 0) busy = busy (busy == "" ? "" : ",") sprintf("%.0f:%.0f", $2, zl + cap)
      next
    }
    FILENAME == main && $1 == "mode" { mode = $2; next }
    END {
      bare = cur; sub(/\[1m\]$/, "", bare)
      # The main model first, then the others by tokens, largest first.
      n = 0
      for (i = 1; i <= nm; i++) if (order[i] == bare) rank[++n] = order[i]
      for (i = 1; i <= nm; i++) {
        k = order[i]; if (k == bare) continue
        size[k] = tin[k] + rd[k] + wr[k] + out[k]
        j = ++n
        while (j > 1 && rank[j - 1] != bare && size[rank[j - 1]] < size[k]) { rank[j] = rank[j - 1]; j-- }
        rank[j] = k
      }
      # The models line in four lengths, for a narrow terminal: in full,
      # without the folded rest, without the cache shares, the first alone.
      sep = E "[2m · " E "[0m"; line = ""; short = ""; first = ""
      for (i = 1; i <= n && i <= 3; i++) {
        k = rank[i]; is_cur = (k == bare)
        all = tin[k] + rd[k] + wr[k]; hit = all ? int(rd[k] * 100 / all + 0.5) : 0
        part = E "[" (is_cur ? "1;36" : "34") "m" pretty(k) E "[0m " E "[2m↑" tok(all) " ↓" tok(out[k]) E "[0m"
        cache = " " E "[" (hit >= 60 ? "32" : "33") "m⚡" hit "%" E "[0m"
        if (is_cur && misses + 0 > 0) cache = cache E "[2m (" misses " miss" (misses + 0 == 1 ? "" : "es") ")" E "[0m"
        line = line (line == "" ? "" : sep) part cache
        short = short (short == "" ? "" : sep) part
        if (i == 1) first = part
      }
      nofold = line
      if (n > 3) {
        fi = 0; fo = 0
        for (i = 4; i <= n; i++) { k = rank[i]; fi += tin[k] + rd[k] + wr[k]; fo += out[k] }
        line = line sep E "[2m+" (n - 3) " more ↑" tok(fi) " ↓" tok(fo) E "[0m"
      }
      if (cand != "") tsum -= uncovered(cand)
      if (lastcand != "") tlast -= uncovered(lastcand)
      print line; print tools + 0; print terr + 0; print turns + 0; printf "%.0f\n%.0f\n", tlast, tsum; print mode
      print nofold; print short; print first
    }' < /dev/null)
  { IFS= read -r models_line; read -r t_calls; read -r t_errors; read -r turns_n; read -r t_last_ms; read -r t_sum_ms; read -r t_mode
    IFS= read -r models_nofold; IFS= read -r models_short; IFS= read -r models_first; } <<EOF
$summary
EOF
  hms() { _s=$(( $1 / 1000 )); if [ "$_s" -lt 60 ]; then echo "${_s}s"; elif [ "$_s" -lt 3600 ]; then echo "$(( _s / 60 ))m$(printf '%02d' $(( _s % 60 )))s"; else echo "$(( _s / 3600 ))h$(printf '%02d' $(( _s % 3600 / 60 )))m"; fi; }
  [ "${t_last_ms:-0}" -gt 0 ] && last_turn="last turn $(hms "$t_last_ms")"
  [ "${t_sum_ms:-0}" -gt 0 ] && active_part="${DIM}($(hms "$t_sum_ms") active)${RESET}"
  if [ "${t_calls:-0}" -gt 0 ]; then
    tools_part="${DIM}🔧 ${t_calls}${RESET}"
    [ "${t_errors:-0}" -gt 0 ] && tools_part="${tools_part} ${RED}✗${t_errors}${RESET}"
  fi
fi

# Folder name only: the git repository's, else the session's project folder.
pwd_part=""
if [ -n "$cwd" ]; then
  # The top folder, then the .git folder all its worktrees share: relative in
  # the main worktree, elsewhere for a linked one (git worktree add, claude
  # --worktree), which is named after its repository.
  { IFS= read -r repo_top; IFS= read -r repo_common; } <<EOF
$(git -C "$cwd" rev-parse --show-toplevel --git-common-dir 2>/dev/null)
EOF
  if [ -n "$repo_top" ]; then
    case "$repo_common" in
      "$repo_top"/*) pwd_name=$(basename "$repo_top") ;;
      /*/.git)       pwd_name=$(basename "${repo_common%/.git}") ;;
      /*.git)        pwd_name=$(basename "${repo_common%.git}") ;;   # a bare repository's worktree
      *)             pwd_name=$(basename "$repo_top") ;;
    esac
  else
    project_dir=$(printf '%s\n' "$input" | jq -r '.workspace.project_dir // empty')
    pwd_name=$(basename "${project_dir:-$cwd}")
  fi
  pwd_part="${BLUE}${pwd_name}${RESET}"
fi

# Main model, its effort, and the permission mode (from the transcript; the
# session JSON carries none) and fast mode when on.
effort=$(printf '%s\n' "$input" | jq -r '.effort.level // empty')
model_part="${CYAN}${short_model}${RESET}"
[ -n "$effort" ] && model_part="${model_part} ${DIM}${effort}${RESET}"
[ "$(printf '%s\n' "$input" | jq -r '.fast_mode // false')" = "true" ] && model_part="${model_part} ${YELLOW}fast${RESET}"
case "${t_mode:-}" in
  ''|default)        mode_part="" ;;
  acceptEdits)       mode_part="${DIM}accept edits${RESET}" ;;
  bypassPermissions) mode_part="${RED}bypass${RESET}" ;;
  *)                 mode_part="${DIM}${t_mode}${RESET}" ;;
esac

# Line 1: model effort · mode · folder · ⎇ branch · diff · last turn
out=""
for part in "$model_part" "$mode_part" "$pwd_part" "$git_part" "$git_diff_part" "${last_turn:+${DIM}${last_turn}${RESET}}"; do
  [ -z "$part" ] && continue
  if [ -n "$out" ]; then out="${out}${DIM} · ${RESET}${part}"; else out="$part"; fi
done
[ -z "$out" ] && out="${CYAN}${short_model}${RESET}"

# Line 2: context bar, then the tokens in the context now / the window's size
ctx_size=$(printf '%s\n' "$input" | jq -r '.context_window.context_window_size // empty | numbers | floor' 2>/dev/null)
case "$ctx_size" in ''|*[!0-9]*) ctx_size=0 ;; esac
out="${out}${NL}${DIM}ctx${RESET} ${ctx_part}"
# No reading yet (a new session, or just after /compact): no "0"
if [ "$ctx_tokens" -gt 0 ]; then
  out="${out} ${WHITE}$(tokens_short "$ctx_tokens")${RESET}"
  [ "$ctx_size" -gt 0 ] && out="${out}${DIM}/$(tokens_short "$ctx_size")${RESET}"
fi

# Line 3: 5h rate limit bar (if present)
[ -n "$five_part" ] && out="${out}${NL}${DIM}5h${RESET}  ${five_part}"

# Line 4: 7-day rate limit bar (if present)
[ -n "$week_part" ] && out="${out}${NL}${DIM}7d${RESET}  ${week_part}"

# Line 5: models (or the model's name) · turns · $ · duration
META_SEP="${DIM} · ${RESET}"
meta=""
mappend() {
  if [ -n "$1" ]; then
    if [ -n "$meta" ]; then meta="${meta}${META_SEP}$1"; else meta="$1"; fi
  fi
}
turns_part=""
case "$turns_n" in
  ''|*[!0-9]*) ;;
  1) turns_part="${DIM}1 turn${RESET}" ;;
  *) turns_part="${DIM}${turns_n} turns${RESET}" ;;
esac
usd=$(printf '%s\n' "$input" | jq -r '.cost.total_cost_usd // empty')
usd_part=""
[ -n "$usd" ] && usd_part="${WHITE}\$$(printf '%.2f' "$usd")${RESET}"
[ -n "$dur_part" ] && [ -n "$active_part" ] && dur_part="${dur_part} ${active_part}"
meta_for() { meta=""; mappend "$1"; [ -n "$2" ] && mappend "$tools_part"; mappend "$turns_part"; mappend "$usd_part"; mappend "$dur_part"; }
# Columns a line takes: colour codes left out, one per character, two for ⚡ and 🔧.
width() {
  printf '%s' "$1" | LC_ALL=C awk -v E="$(printf '\033')" '{
    gsub(E "\\[[0-9;]*m", ""); gsub(/\\033\[[0-9;]*m/, "")
    w = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c < "\200" || c > "\277") w++ }
    print w + gsub(/\342\232\241/, "") + gsub(/\360\237\224\247/, "") }'
}
# The longest version that fits the terminal (COLUMNS, from Claude Code; the
# status line is indented by 2): less on the models first, then no tool counts.
meta_for "$models_line" 1
cols=${COLUMNS:-0}; case "$cols" in ''|*[!0-9]*) cols=0 ;; esac
if [ "$cols" -gt 0 ] && [ -n "$models_line" ]; then
  for v in "$models_nofold|1" "$models_short|1" "$models_first|1" "$models_first|"; do
    [ "$(width "$meta")" -le $(( cols - 2 )) ] && break
    meta_for "${v%|*}" "${v##*|}"
  done
fi
[ -n "$meta" ] && out="${out}${NL}${meta}"

# Line 6 (optional): live loop-review round scores.
# ─────────────────────────────────────────────────────────────────────────────
# This is an OPTIONAL integration: the status line only READS a small state
# file that some external tool (e.g. an iterative review workflow) may write.
# If the file is absent or stale (>1h), nothing is shown — so it costs nothing
# when unused. Wire it up by writing this file per review round:
#
#   RF="$HOME/.claude/statusline-state/loop-review/$(printf '%s' \
#        "$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$dir")" \
#        | sed 's#[^A-Za-z0-9]#_#g')"
#   printf 'code|%s\n' "n:8,0;s:9,5" > "$RF"      # then rm -f "$RF" when done
#
# Keyed by the git repo root (falls back to cwd) so scores never leak across
# projects AND survive a review step cd-ing into a subdir mid-run. File format:
#   "kind|sev:score;sev:score;..."  — one segment per round, latest last.
#   sev colors the score by finding severity: c=critical→red, m=medium→yellow,
#   s/n (minor/none) and anything else→green. The arrows are drawn here. It is
#   rendered verbatim, so scores keep whatever number format you write.
# ─────────────────────────────────────────────────────────────────────────────
review_dir="$HOME/.claude/statusline-state/loop-review"
if [ -n "$cwd" ] && [ -d "$review_dir" ]; then
  review_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")
  review_key=$(printf '%s' "$review_root" | sed 's#[^A-Za-z0-9]#_#g')
  review_file="$review_dir/$review_key"
  if [ -f "$review_file" ]; then
    # `stat -f %m` (BSD, macOS), then `stat -c %Y` (GNU, BusyBox, which read
    # `-f` as "file system" and print a report): only a plain number counts.
    rv_mtime=$(stat -f "%m" "$review_file" 2>/dev/null)
    case "$rv_mtime" in ''|*[!0-9]*) rv_mtime=$(stat -c "%Y" "$review_file" 2>/dev/null) ;; esac
    case "$rv_mtime" in ''|*[!0-9]*) rv_mtime=0 ;; esac
    rv_age=$(( $(date +%s) - rv_mtime ))
    if [ "$rv_age" -lt 3600 ]; then
      IFS= read -r rv_content < "$review_file" || rv_content=""
      if [ -n "$rv_content" ]; then
        case "$rv_content" in
          *"|"*) rv_kind=${rv_content%%|*}; rv_traj=${rv_content#*|} ;;
          *)     rv_kind="loop";            rv_traj=$rv_content ;;
        esac
        rv_out=""
        rv_oifs=$IFS; IFS=';'
        for rv_seg in $rv_traj; do
          [ -z "$rv_seg" ] && continue
          rv_sev=${rv_seg%%:*}; rv_score=${rv_seg#*:}
          case "$rv_sev" in
            c) rv_col=$RED ;;
            m) rv_col=$YELLOW ;;
            *) rv_col=$GREEN ;;
          esac
          if [ -n "$rv_out" ]; then
            rv_out="${rv_out}${DIM} → ${RESET}${rv_col}${rv_score}${RESET}"
          else
            rv_out="${rv_col}${rv_score}${RESET}"
          fi
        done
        IFS=$rv_oifs
        [ -n "$rv_out" ] && out="${out}${NL}${DIM}${rv_kind}-review${RESET}  ${rv_out}"
      fi
    fi
  fi
fi

printf '%s' "$out"
