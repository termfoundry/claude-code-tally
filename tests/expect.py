# expect.py <data dir>: the totals worked out independently of the script
import json, sys, glob, collections, datetime
d = sys.argv[1]; CAP = 900000
files = [d + "/s.jsonl"] + sorted(glob.glob(d + "/s/subagents/*.jsonl")) + sorted(glob.glob(d + "/s/subagents/workflows/*/agent-*.jsonl"))
def ms(t):
    return round(datetime.datetime.strptime(t, "%Y-%m-%dT%H:%M:%S.%fZ").replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)
NOT_PROMPT = ("<command-", "<local-command", "[Request interrupted", "<bash-", "<task-notification")
m = collections.defaultdict(lambda: [0, 0, 0, 0, 0]); tools = errs = turns = 0; mode = ""; events = []; points = []
# A `!` command typed while Claude is idle (no response since the last turn
# ended) is a turn when Claude answers it before any other prompt.
bang = None; at_work = False
for i, f in enumerate(files):
    last = {}
    for line in open(f):
        try: r = json.loads(line)
        except Exception: continue
        msg = r.get("message") or {}
        if isinstance(r, dict) and isinstance(r.get("timestamp"), str): points.append(ms(r["timestamp"]))
        if i == 0 and r.get("type") == "attachment" and not r.get("isSidechain"):
            a = r.get("attachment") or {}
            if a.get("type") == "queued_command" and (a.get("origin") or {}).get("kind") == "human" and a.get("commandMode", "prompt") == "prompt": turns += 1; bang = None
        if r.get("type") == "assistant" and msg.get("usage"):
            if i == 0:
                if bang is not None: turns += 1; events.append(("P", bang)); bang = None
                at_work = True
            tools += sum(1 for b in msg.get("content") or [] if b.get("type") == "tool_use"); last[msg["id"]] = (msg["model"], msg["usage"])
        elif r.get("type") == "user":
            c = msg.get("content")
            if isinstance(c, list): errs += sum(1 for b in c if b.get("type") == "tool_result" and b.get("is_error"))
            if i > 0 or r.get("isSidechain"): continue
            typed = (r.get("origin") or {}).get("kind") == "human"
            if typed and "permissionMode" in r: mode = r["permissionMode"]
            if (r.get("origin") is None or typed) and not r.get("isMeta") and not r.get("isCompactSummary"):
                # A slash command typed (origin human) is a prompt; without an origin only plain text is
                if isinstance(c, str) and (not c.startswith(NOT_PROMPT) or (typed and c.startswith("<command-"))): turns += 1; events.append(("P", ms(r["timestamp"]))); bang = None
                elif isinstance(c, list) and not any(b.get("type") == "tool_result" for b in c) and any(b.get("type") == "text" and not b.get("text", "").startswith("[Request interrupted") for b in c): turns += 1; events.append(("P", ms(r["timestamp"]))); bang = None
                elif isinstance(c, str) and c.startswith("<bash-input>") and not at_work: bang = ms(r["timestamp"])
        elif i == 0 and r.get("type") == "system" and r.get("subtype") == "turn_duration":
            e = ms(r["timestamp"]); events.append(("T", e - r["durationMs"], e)); at_work = False
        elif i == 0 and r.get("type") == "permission-mode": mode = r["permissionMode"]
    for model, u in last.values():
        if model.startswith("<"): continue
        e = m[model]; e[0] += 1; e[1] += u.get("input_tokens", 0); e[2] += u.get("cache_read_input_tokens", 0); e[3] += u.get("cache_creation_input_tokens", 0); e[4] += u.get("output_tokens", 0)
# Covered: each row of any transcript and the 15 minutes after it, merged.
cover = []
for p in sorted(points):
    if cover and p <= cover[-1][1]: cover[-1][1] = max(cover[-1][1], p + CAP)
    else: cover.append([p, p + CAP])
if cover: cover[0][0] = float('-inf')   # before the first row nothing is idle
def covered(a, b): return sum(max(0, min(b, y) - max(a, x)) for x, y in cover)
# A turn after a new prompt runs from that prompt, else from its own start; each
# counts from where the turn before it ended, and only its covered parts.
tsum = 0; done_to = float("-inf"); prompt = None; last_turn = None
for ev in events:
    if ev[0] == "P": prompt = ev[1]; continue
    s, e2 = ev[1], ev[2]
    if prompt is not None and done_to < prompt < e2: s = prompt
    lo = max(s, done_to)
    if e2 > lo: tsum += covered(lo, e2)
    done_to = max(done_to, e2); last_turn = (s, e2)
tlast = covered(*last_turn)
for k in sorted(m): print("m\t%s\t%d\t%d\t%d\t%d\t%d" % ((k,) + tuple(m[k])))
print("tools\t%d\t%d" % (tools, errs)); print("turns\t%d" % turns); print("tdur\t%d\t%d" % (tlast, tsum)); print("mode\t%s" % mode)
