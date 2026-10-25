#!/bin/sh
# run.sh [shell]: runs statusline-command.sh with that shell (default sh) and
# checks it: totals vs an independent count, reads in pieces, cancelled
# refreshes, idle time, git locks, terminal width, model names, edge cases,
# simultaneous refreshes, and the output vs the committed script (REF=HEAD).
# Needs jq, git and python3. Exits 1 if a check fails.
T=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$T"); S=$ROOT/statusline-command.sh
SH=${1:-sh}; E=$(printf '\033'); pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '    ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '    FAIL  %s\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2" | head -4 | sed 's/^/            /'; }
plain() { sed "s/${E}\[[0-9;]*m//g"; }
hms() { _s=$(( $1 / 1000 )); if [ "$_s" -lt 60 ]; then echo "${_s}s"; elif [ "$_s" -lt 3600 ]; then echo "$(( _s / 60 ))m$(printf '%02d' $(( _s % 60 )))s"; else echo "$(( _s / 3600 ))h$(printf '%02d' $(( _s % 3600 / 60 )))m"; fi; }
json() {   # json <dir> <transcript or ""> <extra fields> <model name>
  tp=""; [ -n "$2" ] && tp="\"transcript_path\":\"$2\","
  printf '%s\n' "{\"session_id\":\"k\",$tp\"model\":{\"id\":\"claude-opus-5-5\",\"display_name\":\"${4:-Opus 5.5}\"},\"effort\":{\"level\":\"high\"},\"workspace\":{\"current_dir\":\"$1\"},\"cost\":{\"total_cost_usd\":17.18},\"context_window\":{\"used_percentage\":31,\"total_input_tokens\":310000,\"total_output_tokens\":5,\"context_window_size\":1000000}$3}"
}
for c in jq git python3; do command -v $c >/dev/null 2>&1 || { echo "run.sh: $c is needed" >&2; exit 2; }; done
# All of it in one new folder. Its path is used unquoted, so a space in it would
# split it (and rm -rf the part before the space): no such TMPDIR.
case "${TMPDIR:-/tmp}" in *[!A-Za-z0-9._/-]*) echo "run.sh: TMPDIR must not contain spaces or special characters: $TMPDIR" >&2; exit 2 ;; esac
W=$(mktemp -d "${TMPDIR:-/tmp}/statusline-test.XXXXXX") || exit 2; mkdir -p $W/h $W/repo $W/tmp
trap 'rm -rf "$W"' EXIT; trap 'exit 1' HUP INT TERM
TMPDIR=$W/tmp; export TMPDIR
echo "  [test data: generated, and counted independently]"
python3 "$T/gen.py" $W/data && python3 "$T/expect.py" $W/data | sort > $W/expected.txt || { echo "run.sh: the test data could not be made" >&2; exit 2; }
K=$W/data
( cd $W/repo && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m one && printf 'a\nb\n' > f && git add f && printf 'c\n' >> f && echo u > u ) 2>/dev/null
sed 's/^CHUNK_MAX=.*/CHUNK_MAX=65536/' $S > $W/small.sh       # pieces of 64 KB
sed 's/^CHUNK_MAX=.*/CHUNK_MAX=2048/' $S > $W/tiny.sh         # pieces of 2 KB: slow
files="s.jsonl s/subagents/agent-a1.jsonl s/subagents/agent-a2.jsonl s/subagents/agent-a3.jsonl s/subagents/agent-a4.jsonl
  s/subagents/workflows/wf_t1/agent-w1.jsonl s/subagents/workflows/wf_t1/agent-w2.jsonl s/subagents/workflows/wf_t1/journal.jsonl"
# A refresh run in the background as Claude Code runs it, stopped as Claude Code
# stops it: the script and everything it started. Its own process group: setsid
# where there is one, else job control (macOS).
start_bg() {   # start_bg <script>: reads $W/in.json, HOME=$W/h
  if command -v setsid >/dev/null 2>&1; then HOME=$W/h setsid $SH $1 < $W/in.json > /dev/null 2>>$W/err & pid=$!
  else set -m; HOME=$W/h $SH $1 < $W/in.json > /dev/null 2>>$W/err & pid=$!; set +m; fi
}
stop_bg() {
  kill -TERM -$pid 2>/dev/null || kill -TERM $pid 2>/dev/null; wait $pid 2>/dev/null
  # Its subshells finish their clean-up first: on a slow disk a removal can
  # take seconds.
  i=0; while kill -0 -$pid 2>/dev/null && [ $i -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
}
offset() { awk -F'\t' '$1 == "offset" { print $2 }' $W/h/.claude/statusline-state/transcript/s.jsonl.tsv 2>/dev/null; }
temps_left() { echo $(( $(ls $W/tmp | wc -l) + $(ls $W/h/.claude/statusline-state/transcript/ | grep -cv '\.tsv$') )); }
exp_last=$(awk -F'\t' '$1 == "tdur" { print $2 }' $W/expected.txt); exp_act=$(awk -F'\t' '$1 == "tdur" { print $3 }' $W/expected.txt)
want_times="last turn $(hms $exp_last)|($(hms $exp_act) active)"
stats() {   # stats <label> <home> <output>: the state totals and the times shown vs the independent count
  st=$2/.claude/statusline-state/transcript
  { cat $st/*.tsv | awk -F'\t' '$1=="m"{k=$2; r[k]+=$3; a[k]+=$4; b[k]+=$5; c[k]+=$6; o[k]+=$7} $1=="tools"{t+=$2; e+=$3} END{for(k in r) printf "m\t%s\t%d\t%d\t%d\t%d\t%d\n",k,r[k],a[k],b[k],c[k],o[k]; printf "tools\t%d\t%d\n",t,e}'
    awk -F'\t' '$1=="turns"||$1=="mode"' $st/s.jsonl.tsv; } | sort > $W/got
  grep -v '^tdur' $W/expected.txt > $W/want
  times="$(printf '%s' "$3" | plain | grep -o 'last turn [0-9hms]*' | head -1)|$(printf '%s' "$3" | plain | grep -o '([0-9hms]* active)')"
  if cmp -s $W/got $W/want && [ "$times" = "$want_times" ] && [ ! -s $W/err ]; then ok "$1"
  else bad "$1" "$(diff $W/want $W/got; [ "$times" = "$want_times" ] || echo "times: $times, want $want_times"; cat $W/err)"; fi
}

echo "  [stats: one read and 3 pieces vs an independent count]"
for mode in one pcs; do
  rm -rf $W/d $W/h; mkdir -p $W/d/s/subagents/workflows/wf_t1 $W/h
  if [ $mode = one ]; then for f in $files; do cp "$K/$f" "$W/d/$f"; done; out=$(json $W/d $W/d/s.jsonl | HOME=$W/h $SH $S 2>$W/err)
  else
    for f in $files; do : > "$W/d/$f"; done
    : > $W/err
    for part in 1 2 3; do
      for f in $files; do size=$(wc -c < "$K/$f"); have=$(wc -c < "$W/d/$f")
        if [ $part -lt 3 ]; then want=$(( size * part / 3 + 37 )); else want=$size; fi
        tail -c +$(( have + 1 )) "$K/$f" | head -c $(( want - have )) >> "$W/d/$f"; done
      out=$(json $W/d $W/d/s.jsonl | HOME=$W/h $SH $S 2>>$W/err)
    done
  fi
  stats "stats, $mode" $W/h "$out"
done
left=$(ls $W/h/.claude/statusline-state/transcript/ | grep -v '\.tsv$' | wc -l | tr -d ' '); left2=$(ls $W/tmp | wc -l | tr -d ' ')
[ "$left" = 0 ] && [ "$left2" = 0 ] && ok "no leftover temp files" || bad "leftover temp files: $left in the state, $left2 in TMPDIR"

echo "  [read in small pieces, one line longer than a piece]"
rm -rf $W/h; mkdir -p $W/h; out=$(json $W/d $W/d/s.jsonl | HOME=$W/h $SH $W/small.sh 2>$W/err)
stats "64 KB pieces: same totals" $W/h "$out"

echo "  [after a line longer than a piece, the rest is still read in pieces]"
json $W/d $W/d/s.jsonl > $W/in.json; size=$(wc -c < $W/d/s.jsonl | tr -d ' ')
long_end=$(LC_ALL=C awk '{ n += length($0) + 1; if (length($0) > 200000) { print n; exit } }' $W/d/s.jsonl)
rm -rf $W/h; mkdir -p $W/h; : > $W/err; start_bg $W/small.sh
seen=0; i=0; while [ $i -lt 600 ]; do o=$(offset); [ "${o:-0}" -ge "$long_end" ] && { seen=$o; break; }; sleep 0.05; i=$((i + 1)); done
stop_bg; left=$(temps_left)
[ "$seen" -ge "$long_end" ] && [ "$seen" -lt "$size" ] && [ "$left" = 0 ] && ok "the long line alone, then the next piece: saved at $seen of $size" \
  || bad "after the long line (ends at $long_end): saved at $seen of $size, $left temp files"
rm -f $W/tmp/*

echo "  [a refresh cancelled mid-read, then the next one]"
clean=0; why=""
for run in 1 2 3 4 5 6 7 8; do
  rm -rf $W/h; mkdir -p $W/h; : > $W/err
  start_bg $W/tiny.sh
  i=0; while [ $i -lt 60 ]; do o=$(offset); [ "${o:-0}" -gt 0 ] && break; sleep 1; i=$((i + 1)); done
  [ $run -gt 4 ] && sleep 1
  stop_bg; off=$(offset); left=$(temps_left)
  if [ "${off:-0}" -gt 0 ] && [ "$off" -lt "$size" ] && [ "$left" = 0 ]; then clean=$((clean + 1)); else why="$why run $run: offset ${off:-none}, $left temp files;"; rm -f $W/tmp/*; fi
done
[ $clean = 8 ] && ok "cancelled 8 times mid-read: progress kept, no temp files left" || bad "cancelled refresh: $clean of 8 clean" "$why"
: > $W/err; out=$(json $W/d $W/d/s.jsonl | HOME=$W/h $SH $S 2>$W/err)
stats "the next refresh finishes it: same totals" $W/h "$out"

echo "  [idle time: a sleep inside a turn, a subagent covering part of a wait]"
rm -rf $W/i $W/hi; mkdir -p $W/hi; cp -R $T/fixtures/idle $W/i
out=$(json $W/i $W/i/s.jsonl | HOME=$W/hi $SH $S 2>$W/err | plain)
case "$out" in *'last turn 33m30s'*'2 turns'*'(53m30s active)'*) ok "sleep left out, agent work kept: last turn 33m30s, 53m30s active" ;; *) bad "idle time" "$(printf '%s' "$out" | tail -2)" ;; esac

echo "  [a turn resumed after agents report back]"
rm -rf $W/o $W/ho; mkdir -p $W/o $W/ho; cp $T/fixtures/overlap/s.jsonl $W/o/s.jsonl
out=$(json $W/o $W/o/s.jsonl | HOME=$W/ho $SH $S 2>$W/err | plain)
case "$out" in *'last turn 3m18s'*'(3m47s active)'*) [ -s $W/err ] && bad "resumed turn: errors" "$(cat $W/err)" || ok "resumed turn counted once: 3m47s active" ;; *) bad "resumed turn" "$out" ;; esac

echo "  [turns: a wait for an answer, a slash command, a turn timed from an older prompt, ! commands, a prompt taken mid-turn]"
# 09:00 a prompt; work until a question at 09:10, answered at 11:10, done 11:15:
# Claude Code times it 15 minutes, without the wait. 09:07 a prompt typed and
# taken into that turn (a turn, not its start), 09:08 a hand-back from another
# session (no turn). 12:00 /model (local). 12:30 a ! command Claude answers
# (a turn of 1 minute), 12:40 one it does not. 13:00 /code-review typed in
# plan mode, done 13:05, timed by Claude Code from 09:00.
rm -rf $W/q $W/hq; mkdir -p $W/q $W/hq
A='"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"output_tokens":1},'
cat > $W/q/s.jsonl <<EOF
{"type":"permission-mode","permissionMode":"auto"}
{"type":"user","timestamp":"2026-10-18T09:00:00.000Z","origin":{"kind":"human"},"permissionMode":"auto","message":{"content":"do it"}}
{$A"id":"q1","content":[{"type":"tool_use"}]},"timestamp":"2026-10-18T09:05:00.000Z"}
{"type":"user","timestamp":"2026-10-18T09:05:01.000Z","message":{"content":[{"type":"tool_result"}]}}
{"type":"attachment","timestamp":"2026-10-18T09:07:00.000Z","attachment":{"type":"queued_command","commandMode":"prompt","humanTurn":true,"origin":{"kind":"human"},"prompt":"and add a test"}}
{"type":"attachment","timestamp":"2026-10-18T09:08:00.000Z","attachment":{"type":"queued_command","commandMode":"prompt","origin":{"kind":"peer"},"prompt":"[Subagent hand-back]"}}
{$A"id":"q2","content":[{"type":"tool_use","name":"AskUserQuestion"}]},"timestamp":"2026-10-18T09:10:00.000Z"}
{"type":"user","timestamp":"2026-10-18T11:10:00.000Z","message":{"content":[{"type":"tool_result"}]}}
{$A"id":"q3","content":[{"type":"text","text":"done"}]},"timestamp":"2026-10-18T11:15:00.000Z"}
{"type":"system","subtype":"turn_duration","durationMs":900000,"timestamp":"2026-10-18T11:15:00.000Z"}
{"type":"user","timestamp":"2026-10-18T12:00:00.000Z","message":{"content":"<command-name>/model</command-name>"}}
{"type":"user","timestamp":"2026-10-18T12:30:00.000Z","message":{"content":"<bash-input>./check.sh</bash-input>"}}
{"type":"user","timestamp":"2026-10-18T12:30:01.000Z","message":{"content":"<bash-stdout>failed</bash-stdout><bash-stderr></bash-stderr>"}}
{$A"id":"q6","content":[{"type":"text","text":"it failed because"}]},"timestamp":"2026-10-18T12:31:00.000Z"}
{"type":"system","subtype":"turn_duration","durationMs":60000,"timestamp":"2026-10-18T12:31:00.000Z"}
{"type":"user","timestamp":"2026-10-18T12:40:00.000Z","message":{"content":"<bash-input>ls</bash-input>"}}
{"type":"user","timestamp":"2026-10-18T12:40:01.000Z","message":{"content":"<bash-stdout>a b</bash-stdout><bash-stderr></bash-stderr>"}}
{"type":"user","timestamp":"2026-10-18T13:00:00.000Z","origin":{"kind":"human"},"permissionMode":"plan","message":{"content":"<command-message>code-review</command-message>\n<command-name>/code-review</command-name>"}}
{"type":"user","timestamp":"2026-10-18T13:00:00.100Z","isMeta":true,"message":{"content":"review the code"}}
{$A"id":"q4","content":[{"type":"tool_use"}]},"timestamp":"2026-10-18T13:02:30.000Z"}
{"type":"user","timestamp":"2026-10-18T13:02:31.000Z","message":{"content":[{"type":"tool_result"}]}}
{$A"id":"q5","content":[{"type":"text","text":"done"}]},"timestamp":"2026-10-18T13:05:00.000Z"}
{"type":"system","subtype":"turn_duration","durationMs":14700000,"timestamp":"2026-10-18T13:05:00.000Z"}
EOF
out=$(json $W/q $W/q/s.jsonl | HOME=$W/hq $SH $S 2>$W/err | plain)
case "$out" in *' plan · '*'last turn 5m00s'*'4 turns'*'(36m00s active)'*) [ -s $W/err ] && bad "turns: errors" "$(cat $W/err)" || ok "plan mode, last turn 5m00s, 4 turns, 36m00s active" ;; *) bad "turns" "$out" ;; esac
# 09:00 a turn of 5 minutes; 10:00 a prompt, interrupted at 10:03 (Claude Code times no such turn)
rm -rf $W/x $W/hx; mkdir -p $W/x $W/hx
cat > $W/x/s.jsonl <<EOF
{"type":"user","timestamp":"2026-10-18T09:00:00.000Z","origin":{"kind":"human"},"message":{"content":"do it"}}
{$A"id":"x1","content":[{"type":"text","text":"done"}]},"timestamp":"2026-10-18T09:05:00.000Z"}
{"type":"system","subtype":"turn_duration","durationMs":300000,"timestamp":"2026-10-18T09:05:00.000Z"}
{"type":"user","timestamp":"2026-10-18T10:00:00.000Z","origin":{"kind":"human"},"message":{"content":"and this"}}
{$A"id":"x2","content":[{"type":"tool_use"}]},"timestamp":"2026-10-18T10:01:00.000Z"}
{"type":"user","timestamp":"2026-10-18T10:03:00.000Z","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
EOF
out=$(json $W/x $W/x/s.jsonl | HOME=$W/hx $SH $S 2>$W/err | plain)
case "$out" in *'last turn 3m00s'*'2 turns'*'(8m00s active)'*) [ -s $W/err ] && bad "interrupted turn: errors" "$(cat $W/err)" || ok "an interrupted turn: last turn 3m00s, 8m00s active" ;; *) bad "interrupted turn" "$out" ;; esac

echo "  [git: a refresh leaves the index alone]"
rm -rf $W/lock; mkdir -p $W/lock
( cd $W/lock && git init -q && echo a > f && git add f && git -c user.email=t@t -c user.name=t commit -q -m one && sleep 1 && touch f ) 2>/dev/null
b=$(cksum < $W/lock/.git/index); json $W/lock "" | HOME=$W/h $SH $S >/dev/null 2>&1; a=$(cksum < $W/lock/.git/index)
[ "$a" = "$b" ] && ok "index not touched" || bad "index rewritten by a refresh"
git -C $W/lock config core.fsmonitor "touch $W/fsmonitor-ran; false"
out=$(json $W/lock "" | HOME=$W/h $SH $S 2>&1 | plain); git -C $W/lock config --unset core.fsmonitor
case "$out" in *'⎇ '*) if [ -e $W/fsmonitor-ran ]; then bad "the repo's core.fsmonitor was run"; else ok "the repo's core.fsmonitor not run, git part shown"; fi ;; *) bad "core.fsmonitor set: no git part" "$out" ;; esac
# A linked worktree as claude --worktree makes one, and one of a bare repository: named after the repository
rm -rf $W/wt; mkdir -p $W/wt
( cd $W/wt && git init -q myrepo && git -C myrepo -c user.email=t@t -c user.name=t commit -q --allow-empty -m one && git -C myrepo worktree add -q .claude/worktrees/feat \
  && git clone -q --bare myrepo proj.git && git -C proj.git worktree add -q $W/wt/proj-feature ) >/dev/null 2>&1
a=$(json $W/wt/myrepo/.claude/worktrees/feat "" | HOME=$W/h $SH $S 2>&1 | plain | head -1); b=$(json $W/wt/proj-feature "" | HOME=$W/h $SH $S 2>&1 | plain | head -1)
case "$a|$b" in *' · myrepo · ⎇ feat'*'|'*' · proj · ⎇ '*) ok "worktrees: named after their repository" ;; *) bad "worktrees" "$a / $b" ;; esac

echo "  [the last line: session time from Claude Code, fitted to the terminal]"
cols_of() { LC_ALL=C awk -v E="$E" '{ gsub(E "\\[[0-9;]*m", ""); w = 0; for (i = 1; i <= length($0); i++) { c = substr($0, i, 1); if (c < "\200" || c > "\277") w++ } print w + gsub(/\342\232\241/, "") + gsub(/\360\237\224\247/, "") }'; }
rm -rf $W/h; mkdir -p $W/h
TD=',"cost":{"total_cost_usd":17.18,"total_duration_ms":5025000}'
full=$(json $W/d $W/d/s.jsonl "$TD" | env -u COLUMNS HOME=$W/h $SH $S 2>&1 | tail -n 1)
case "$(printf '%s' "$full" | plain)" in *'⚡'*'+1 more'*'$17.18 · ⏱ 1h23m ('*' active)') ok "no COLUMNS: in full, ⏱ 1h23m from Claude Code" ;; *) bad "last line in full" "$(printf '%s' "$full" | plain)" ;; esac
for c in 160 120 80; do
  l=$(json $W/d $W/d/s.jsonl "$TD" | COLUMNS=$c HOME=$W/h $SH $S 2>&1 | tail -n 1); w=$(printf '%s\n' "$l" | cols_of)
  case "$(printf '%s' "$l" | plain)" in *'Opus 5.5 ↑'*'$17.18 · ⏱ 1h23m'*' active)') [ "$w" -le $(( c - 2 )) ] && ok "COLUMNS=$c: $w columns, cost and time kept" || bad "COLUMNS=$c: $w columns" ;; *) bad "COLUMNS=$c" "$(printf '%s' "$l" | plain)" ;; esac
done

echo "  [model names, old IDs too]"
rm -rf $W/mn; mkdir -p $W/mn
for m in claude-3-5-sonnet-20241022 claude-3-opus-20240229 claude-haiku-4-5-20251001 claude-opus-5-5; do
  printf '{"type":"assistant","timestamp":"2026-10-18T09:00:00.000Z","message":{"id":"x%s","model":"%s","usage":{"input_tokens":5,"output_tokens":5},"content":[]}}\n' "$m" "$m"
done > $W/mn/m.jsonl
l=$(json $W/mn $W/mn/m.jsonl | env -u COLUMNS HOME=$W/h $SH $S 2>&1 | tail -n 1 | plain)
case "$l" in 'Opus 5.5 ↑'*'Sonnet 3.5 ↑'*'Opus 3 ↑'*'+1 more'*) ok "Opus 5.5, Sonnet 3.5, Opus 3" ;; *) bad "model names" "$l" ;; esac

echo "  [edge cases]"
for loc in "LC_ALL=de_DE.UTF-8" "LANG=de_DE.UTF-8" "LC_NUMERIC=de_DE.UTF-8"; do
  out=$(json $W "" | env $loc HOME=$W/h $SH $S 2>$W/err | plain)
  case "$out" in *'$17.18'*'/1M'*|*'/1M'*'$17.18'*) [ -s $W/err ] && bad "$loc: errors" "$(cat $W/err)" || ok "$loc: \$17.18 and 1M" ;; *) bad "$loc" "$out" ;; esac
done
mkdir -p "$W/back\\cslash"
out=$(json "$W/back\\\\cslash" "" | HOME=$W/h $SH $S 2>&1 | plain)
case "$out" in *'back\cslash'*'$17.18'*) ok "backslash in folder name: shown, line complete" ;; *) bad "backslash in folder name" "$out" ;; esac
out=$(json $W "" "" 'Opus \\c 5' | HOME=$W/h $SH $S 2>&1 | plain)
case "$out" in *'Opus \c 5'*'$17.18'*) ok "backslash in model name: shown, line complete" ;; *) bad "backslash in model name" "$out" ;; esac
out=$(echo '{}' | HOME=$W/h $SH $S 2>&1 | plain)
[ "$(printf '%s\n' "$out" | sed -n 2p)" = "ctx —" ] && ok "empty input: no stray 0" || bad "empty input" "$out"
NOW=$(date +%s); LIMITS=",\"rate_limits\":{\"five_hour\":{\"used_percentage\":43,\"resets_at\":$((NOW + 3090))},\"seven_day\":{\"used_percentage\":19,\"resets_at\":$((NOW + 59030))}}"
out=$(json $W "" ",\"rate_limits\":{\"five_hour\":{\"used_percentage\":43,\"resets_at\":$NOW.5},\"seven_day\":{\"used_percentage\":19,\"resets_at\":\"a[\$(touch $W/arith-ran)]\"}}" | HOME=$W/h $SH $S 2>$W/err | plain)
case "$out" in *'5h '*'7d '*'$17.18'*) if [ -e $W/arith-ran ]; then bad "a resets_at expression was run"; elif [ -s $W/err ]; then bad "odd resets_at: errors" "$(cat $W/err)"; else ok "a fraction or an expression as resets_at: nothing run, line complete"; fi ;; *) bad "odd resets_at" "$out" ;; esac
out=$(json $W "" ",\"rate_limits\":{\"five_hour\":{\"used_percentage\":92,\"resets_at\":$((NOW - 600))},\"seven_day\":{\"used_percentage\":19,\"resets_at\":$((NOW - 1))}}" | HOME=$W/h $SH $S 2>&1 | plain)
case "$out" in *'5h '*' 0%'*'7d '*' 0%'*) case "$out" in *'('*) bad "past the reset: a pace still shown" "$out" ;; *) ok "past the reset: 0%, no pace" ;; esac ;; *) bad "past the reset" "$out" ;; esac
for hhmm in 0900 0700; do
  sed "s/^ACT_START_HHMM=1000/ACT_START_HHMM=$hhmm/" $S > $W/a1.sh; sed "s/^ACT_START_HHMM=1000/ACT_START_HHMM=${hhmm#0}/" $S > $W/a2.sh
  in=$(json $W "" "$LIMITS"); a=$(echo "$in" | HOME=$W/h $SH $W/a1.sh 2>&1); b=$(echo "$in" | HOME=$W/h $SH $W/a2.sh 2>&1)
  case "$(printf '%s' "$a" | plain)" in *'7d '*) [ "$a" = "$b" ] && ok "ACT_START_HHMM=$hhmm: shown, the same pace as ${hhmm#0}" || bad "ACT_START_HHMM=$hhmm: a different pace from ${hhmm#0}" ;; *) bad "ACT_START_HHMM=$hhmm" "$a" ;; esac
done
# stat as GNU and BusyBox have it: -f is "file system" and prints a report
mkdir -p $W/gnu $W/rv; cat > $W/gnu/stat <<'EOF'
#!/bin/sh
case $1 in
  -f) printf '  File: "%s"\n    ID: 0        Namelen: 255\n' "$3"; exit 1 ;;
  -c) python3 -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_mtime))' "$3" ;;
esac
EOF
chmod +x $W/gnu/stat
RV=$W/h/.claude/statusline-state/loop-review; mkdir -p $RV; RF=$RV/$(printf '%s' "$W/rv" | sed 's#[^A-Za-z0-9]#_#g')
printf 'code|c:6,5;n:9,5\n' > $RF
out=$(json $W/rv "" | PATH=$W/gnu:$PATH HOME=$W/h $SH $S 2>&1 | plain)
case "$out" in *'ctx '*'code-review  6,5 → 9,5') ok "review scores with GNU stat: shown, line complete" ;; *) bad "review scores with GNU stat" "$out" ;; esac
touch -t 202001010000 $RF; out=$(json $W/rv "" | PATH=$W/gnu:$PATH HOME=$W/h $SH $S 2>&1 | plain)
case "$out" in *code-review*) bad "stale review scores shown" "$out" ;; *'ctx '*'$17.18'*) ok "stale review scores with GNU stat: hidden, line complete" ;; *) bad "stale review scores with GNU stat" "$out" ;; esac
rm -rf $RV
# jq.exe on Windows: every line ends in CR LF
mkdir -p $W/win; cat > $W/win/jq <<EOF
#!/bin/sh
"$(command -v jq)" "\$@" | awk '{ printf "%s\r\n", \$0 }'
EOF
chmod +x $W/win/jq
for try in 1 2; do   # the countdowns follow the clock: a minute can turn between the runs
  NOW=$(date +%s); in=$(json $W/repo $W/q/s.jsonl ",\"rate_limits\":{\"five_hour\":{\"used_percentage\":43,\"resets_at\":$((NOW + 3090))},\"seven_day\":{\"used_percentage\":19,\"resets_at\":$((NOW + 59030))}}")
  rm -rf $W/h; mkdir -p $W/h; a=$(echo "$in" | HOME=$W/h $SH $S 2>&1)
  rm -rf $W/h; mkdir -p $W/h; b=$(echo "$in" | OS=Windows_NT PATH=$W/win:$PATH HOME=$W/h $SH $S 2>&1)
  [ "$a" = "$b" ] && break
done
rm -rf $W/h; mkdir -p $W/h; c=$(echo "$in" | env -u OS PATH=$W/win:$PATH HOME=$W/h $SH $S 2>&1)
[ "$a" = "$b" ] && [ "$a" != "$c" ] && ok "jq with CR LF line ends on Windows: the same output" || bad "jq with CR LF line ends on Windows" "$(printf '%s\n' "$b" | plain)"

echo "  [install.sh]"
IH=$W/inst; ID=$IH/.claude/statusline-command.sh; mkdir -p $IH/.claude
inst() { HOME=$IH $SH $ROOT/install.sh > $W/inst.out 2>&1; }
inst && cmp -s $S $ID && ok "a new install: copied" || bad "a new install" "$(cat $W/inst.out)"
echo old > $ID; before=$(ls -i $ID | awk '{ print $1 }')
inst && cmp -s $S $ID && [ "$(cat $IH/.claude/statusline-command.sh.bak-*)" = old ] && [ "$(ls -i $ID | awk '{ print $1 }')" != "$before" ] \
  && ok "over a different script: backup kept, the new one renamed into place" || bad "over a different script" "$(cat $W/inst.out)"
rm -f $ID; ln -s $S $ID
inst && [ -L $ID ] && grep -q '"statusLine"' $W/inst.out && ok "a link to this script: left as it is, settings entry printed" || bad "a link to this script" "$(cat $W/inst.out)"
rm -f $ID; echo mine > $IH/mine.sh; ln -s $IH/mine.sh $ID
! inst && [ -L $ID ] && [ "$(cat $IH/mine.sh)" = mine ] && ok "a link to another file: refused, that file untouched" || bad "a link to another file" "$(cat $W/inst.out)"
[ -z "$(ls $IH/.claude | grep '\.new\.')" ] && ok "install.sh: no temp files left" || bad "install.sh: temp files left" "$(ls $IH/.claude)"
rm -f $ID; ( cd $(dirname $ROOT) && CDPATH=$(dirname $ROOT) HOME=$IH $SH $(basename $ROOT)/install.sh > $W/inst.out 2>&1 ) && cmp -s $S $ID \
  && ok "CDPATH exported, run from another folder: copied" || bad "CDPATH exported" "$(cat $W/inst.out)"

echo "  [a row taken out of the transcript; a transcript moved to another project folder]"
# Prompt n at 10:0n, its reply (1000 tokens in, 10 out) half a minute later; each row with its uuid
rows() { for n in "$@"; do
  printf '{"type":"user","uuid":"u-%s","timestamp":"2026-10-18T10:0%s:00.000Z","origin":{"kind":"human"},"message":{"content":"task %s"}}\n' $n $n $n
  printf '{"type":"assistant","uuid":"a-%s","timestamp":"2026-10-18T10:0%s:30.000Z","message":{"id":"r%s","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":10},"content":[{"type":"text","text":"done"}]}}\n' $n $n $n
  printf '{"type":"cost-state","timestamp":"2026-10-18T10:0%s:31.000Z"}\n' $n; done; }
models() { json $W/r $W/r/s.jsonl | HOME=$1 $SH $S 2>>$W/err | plain | tail -1 | sed 's/ ⚡.*· \([0-9]* turns\).*/ \1/'; }
rm -rf $W/r $W/hr $W/hr2; mkdir -p $W/r $W/hr $W/hr2; : > $W/err
rows 1 2 3 4 > $W/r/s.jsonl; models $W/hr >/dev/null
# Reply 2 taken out (a reply Claude Code tried again), then two more turns: it stays counted, nothing is read twice
grep -v '"a-2"' $W/r/s.jsonl > $W/r/t && mv $W/r/t $W/r/s.jsonl; rows 5 6 >> $W/r/s.jsonl
a=$(models $W/hr); b=$(models $W/hr2)
[ "$a" = "Opus 5.5 ↑6k ↓60 6 turns" ] && [ "$b" = "Opus 5.5 ↑5k ↓50 6 turns" ] && [ ! -s $W/err ] && ok "a reply taken out: the reading goes on after the last row read" || bad "a reply taken out" "$a (want ↑6k ↓60 6 turns) / fresh: $b$(cat $W/err)"
# The last row read taken out as well: all counted again, as a fresh count
grep -v '"a-6"' $W/r/s.jsonl > $W/r/t && mv $W/r/t $W/r/s.jsonl; rows 7 >> $W/r/s.jsonl
a=$(models $W/hr); rm -rf $W/hr2; mkdir -p $W/hr2; b=$(models $W/hr2)
[ "$a" = "$b" ] && [ "$a" = "Opus 5.5 ↑5k ↓50 7 turns" ] && ok "the last row read taken out: counted again" || bad "the last row read taken out" "$a / fresh: $b"
# Moved to another project folder: its totals kept (a mark put in them shows), not read again
rm -rf $W/mv $W/hm; mkdir -p $W/mv/proj-a $W/mv/proj-b $W/hm; rows 1 2 > $W/mv/proj-a/k.jsonl
json $W/mv $W/mv/proj-a/k.jsonl | HOME=$W/hm $SH $S >/dev/null 2>&1
MS=$W/hm/.claude/statusline-state/transcript/k.jsonl.tsv; sed 's/^turns	.*/turns	99/' $MS > $W/t && mv $W/t $MS; mv $W/mv/proj-a/k.jsonl $W/mv/proj-b/k.jsonl
out=$(json $W/mv $W/mv/proj-b/k.jsonl | HOME=$W/hm $SH $S 2>&1 | plain)
case "$out" in *'99 turns'*) [ "$(ls $W/hm/.claude/statusline-state/transcript | wc -l | tr -d ' ')" = 1 ] && ok "a moved transcript: its totals kept, one state file" || bad "a moved transcript: a second state file" "$(ls $W/hm/.claude/statusline-state/transcript)" ;; *) bad "a moved transcript: read again" "$out" ;; esac

echo "  [3 refreshes at once vs one]"
same=0; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  rm -rf $W/h1 $W/h2; mkdir -p $W/h1 $W/h2
  json $W/d $W/d/s.jsonl | HOME=$W/h1 $SH $S >/dev/null 2>&1
  ( json $W/d $W/d/s.jsonl | HOME=$W/h2 $SH $S >/dev/null 2>&1 & json $W/d $W/d/s.jsonl | HOME=$W/h2 $SH $S >/dev/null 2>&1 & json $W/d $W/d/s.jsonl | HOME=$W/h2 $SH $S >/dev/null 2>&1 & wait )
  for f in $W/h1/.claude/statusline-state/transcript/*.tsv; do cmp -s "$f" "$W/h2/.claude/statusline-state/transcript/$(basename "$f")" || continue 2; done
  [ "$(ls $W/h2/.claude/statusline-state/transcript | grep -cv '\.tsv$')" = 0 ] && [ "$(ls $W/tmp | wc -l | tr -d ' ')" = 0 ] && same=$((same + 1))
done
[ $same = 12 ] && ok "identical totals, no temp files left (12 of 12 runs)" || bad "only $same of 12 runs identical and clean"

# The output against a committed version of the script (REF, default HEAD):
# what a change to the script changes on screen.
REF=${REF:-HEAD}
if git -C "$ROOT" show "$REF:statusline-command.sh" > $W/old.sh 2>/dev/null; then
  echo "  [the same output as $REF, on normal input]"
  for case in plain limits repo; do
    for try in 1 2; do   # the countdowns follow the clock: a minute can turn between the two runs
      NOW=$(date +%s); LIMITS=",\"rate_limits\":{\"five_hour\":{\"used_percentage\":43,\"resets_at\":$((NOW + 3090))},\"seven_day\":{\"used_percentage\":19,\"resets_at\":$((NOW + 59030))}}"   # again: the clock moved
      case $case in plain) in=$(json $W ""); ;; limits) in=$(json $W "" "$LIMITS"); ;; repo) in=$(json $W/repo "" "$LIMITS"); ;; esac
      rm -rf $W/h; mkdir -p $W/h; o=$(echo "$in" | HOME=$W/h $SH $W/old.sh 2>&1); n=$(echo "$in" | HOME=$W/h $SH $S 2>&1)
      [ "$o" = "$n" ] && break
    done
    [ "$o" = "$n" ] && ok "same output: $case" || bad "different output: $case" "$(printf '%s\n' "$o" | plain > $W/o.txt; printf '%s\n' "$n" | plain > $W/n.txt; diff $W/o.txt $W/n.txt)"
  done
fi
echo "  => $pass passed, $fail failed"
[ $fail = 0 ]
