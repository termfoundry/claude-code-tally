# gen.py <dir>: a synthetic session, the same every time: a 2 MB main transcript,
# four subagents and a Workflow run's two, with every kind of user row, repeated
# rows per response, waits, resumed turns and a line longer than a small read piece
import json, random, sys, os, datetime
out = sys.argv[1]; R = random.Random(7)
clock = [datetime.datetime(2026, 10, 17, 9, 0, 0, tzinfo=datetime.timezone.utc)]
def ts():
    clock[0] += datetime.timedelta(seconds=R.randint(1, 40))
    return clock[0].strftime('%Y-%m-%dT%H:%M:%S.') + '%03dZ' % R.randint(0, 999)
def away(lo, hi):   # the computer asleep, a usage-limit wait, a night away
    clock[0] += datetime.timedelta(minutes=R.randint(lo, hi))
def ms(t):
    return round(datetime.datetime.strptime(t, '%Y-%m-%dT%H:%M:%S.%fZ').replace(tzinfo=datetime.timezone.utc).timestamp() * 1000)
HUMAN = {"kind": "human"}
os.makedirs(out + "/s/subagents", exist_ok=True)
A4 = open(out + "/s/subagents/agent-a4.jsonl", "w")
def agent_run(minutes, covered):
    # A subagent writing while the main session waits: all the way through,
    # or stopping early, the rest of the wait being idle.
    end = clock[0] + datetime.timedelta(minutes=minutes)
    stop = end if covered else clock[0] + datetime.timedelta(minutes=R.randint(1, minutes // 2))
    t = clock[0]
    while True:
        t += datetime.timedelta(seconds=R.randint(20, 600))
        if t >= stop: break
        A4.write(json.dumps({"type": "user", "isSidechain": True, "timestamp": t.strftime('%Y-%m-%dT%H:%M:%S.') + '%03dZ' % R.randint(0, 999), "message": {"content": "working"}}) + "\n")
    clock[0] = end
def session(model, side, n_turns, f):
    w = lambda o: f.write(json.dumps(o) + "\n"); mid = 0; before = None
    for turn in range(n_turns):
        left_out = 0   # ms of waits for an answer, which Claude Code leaves out of a turn's time
        if not side:
            if R.random() < 0.05: away(30, 900)
            if R.random() < 0.03:   # a `!` command Claude does not answer: the next row is the prompt
                w({"type": "user", "timestamp": ts(), "message": {"content": "<bash-input>pwd</bash-input>"}}); w({"type": "user", "timestamp": ts(), "message": {"content": "<bash-stdout>/x</bash-stdout><bash-stderr></bash-stderr>"}})
            k = R.random(); prompt = ts(); u = lambda **o: w(dict({"type": "user", "timestamp": prompt}, **o))
            if k < 0.40: u(origin=HUMAN, promptSource="typed", permissionMode=R.choice(["auto", "plan", "default", "acceptEdits"]), message={"role": "user", "content": "please do task %d" % turn})
            elif k < 0.48: u(origin=HUMAN, message={"content": [{"type": "text", "text": "pasted task %d" % turn}]})
            elif k < 0.53: u(origin=HUMAN, promptSource="queued", message={"content": "queued task %d" % turn})
            elif k < 0.60: u(message={"content": "an older transcript, no origin %d" % turn})
            elif k < 0.63: u(message={"content": "<command-name>/model</command-name>"})   # a local command: no origin
            elif k < 0.66: u(origin=HUMAN, promptSource="typed", message={"content": "<command-message>code-review</command-message>\n<command-name>/code-review</command-name>"}); w({"type": "user", "isMeta": True, "timestamp": ts(), "message": {"content": "the command's prompt"}})
            elif k < 0.70: u(isMeta=True, message={"content": "meta note"})
            elif k < 0.73: u(message={"content": [{"type": "text", "text": "[Request interrupted by user]"}]})
            elif k < 0.79: u(origin={"kind": "task-notification"}, promptSource="system", message={"content": "<task-notification>\n<task-id>t%d</task-id>" % turn})
            elif k < 0.83: u(origin={"kind": "peer"}, isMeta=True, message={"content": "Another Claude session sent a message"})
            elif k < 0.86: u(message={"content": "<task-notification>\n<task-id>old%d</task-id>" % turn})
            elif k < 0.92: u(message={"content": "<bash-input>ls</bash-input>"}); w({"type": "user", "timestamp": ts(), "message": {"content": "<bash-stdout>a b</bash-stdout><bash-stderr></bash-stderr>"}})
            else: u(isCompactSummary=True, message={"content": "This session is being continued from a previous conversation"})
            if R.random() < 0.3: w({"type": "permission-mode", "permissionMode": R.choice(["auto", "plan", "default", "acceptEdits"])})
            if turn == 50: w({"type": "attachment", "timestamp": ts(), "content": "x" * 300000})   # one line longer than a small piece
        else:
            w({"type": "user", "isSidechain": True, "timestamp": ts(), "message": {"content": "agent step %d" % turn}})
        for step in range(R.randint(1, 6)):
            if not side and R.random() < 0.03: away(5, 600)   # inside a turn: short waits count, long ones don't
            if not side and R.random() < 0.02: agent_run(R.randint(16, 90), R.random() < 0.6)
            if not side and R.random() < 0.03:   # a prompt typed meanwhile, taken into this turn; or a hand-back from another session
                w({"type": "attachment", "timestamp": ts(), "attachment": {"type": "queued_command", "commandMode": "prompt", "humanTurn": True, "origin": R.choice([HUMAN, HUMAN, {"kind": "peer"}]), "prompt": "and this too"}})
            if not side and R.random() < 0.02:   # a question waiting for an answer
                t0 = clock[0]; away(5, 200); left_out += round((clock[0] - t0).total_seconds() * 1000)
            mid += 1; ident = "msg_%s_%d_%d" % (model, int(side), mid)
            uu0 = {"input_tokens": R.randint(0, 50), "cache_read_input_tokens": R.randint(1000, 400000), "cache_creation_input_tokens": R.randint(0, 9000)}
            outn = R.randint(5, 3000); rows = R.randint(1, 4)
            for r in range(rows):
                uu = dict(uu0, output_tokens=(outn if r == rows - 1 else R.randint(1, outn)))
                blocks = [{"type": "tool_use", "name": "Bash"}] if R.random() < 0.6 else [{"type": "text", "text": "ok"}]
                w({"type": "assistant", "isSidechain": side, "timestamp": ts(), "message": {"id": ident, "model": model, "usage": uu, "content": blocks}})
                if blocks[0]["type"] == "tool_use":
                    w({"type": "user", "isSidechain": side, "timestamp": ts(), "message": {"content": [{"type": "tool_result", "is_error": R.random() < 0.08}]}})
            if R.random() < 0.05:
                w({"type": "assistant", "isSidechain": side, "timestamp": ts(), "message": {"id": "syn_%d_%d" % (int(side), mid), "model": "<synthetic>", "usage": {"input_tokens": 0, "output_tokens": 0}, "content": [{"type": "text", "text": "err"}]}})
        if not side:
            # Timed from the prompt, as Claude Code does, waits included but not
            # waits for an answer; now and then from the prompt before; a turn
            # resumed after an agent reports back is timed from the same prompt
            # again, and rounding can move its start by a millisecond.
            start = before if before and R.random() < 0.05 else prompt; before = prompt
            end = ts(); w({"type": "system", "subtype": "turn_duration", "durationMs": ms(end) - ms(start) - left_out, "timestamp": end})
            while R.random() < 0.3:
                if R.random() < 0.2: agent_run(R.randint(20, 120), R.random() < 0.6)   # an agent working long while the main session waits
                w({"type": "user", "isMeta": True, "timestamp": ts(), "message": {"content": "agent reported back"}})
                end = ts(); w({"type": "system", "subtype": "turn_duration", "durationMs": ms(end) - ms(start) - left_out + R.choice([-1, 0, 1]), "timestamp": end})
        if R.random() < 0.02: f.write("not json at all\n")
with open(out + "/s.jsonl", "w") as f: session("claude-opus-5-5", False, 400, f)
A4.close()
for name, model, n in (("a1", "claude-sonnet-5", 120), ("a2", "claude-haiku-4-5-20251001", 80), ("a3", "claude-fable-5-1", 40)):
    with open(out + "/s/subagents/agent-%s.jsonl" % name, "w") as f: session(model, True, n, f)
wf = out + "/s/subagents/workflows/wf_t1"; os.makedirs(wf, exist_ok=True)
for name, model, n in (("w1", "claude-opus-5-5", 60), ("w2", "claude-sonnet-5", 30)):
    with open(wf + "/agent-%s.jsonl" % name, "w") as f: session(model, True, n, f)
with open(wf + "/journal.jsonl", "w") as f:   # the run's journal, no transcript: never counted
    f.write(json.dumps({"type": "assistant", "timestamp": "2026-10-17T09:00:00.000Z", "message": {"id": "j", "model": "claude-opus-5-5", "usage": {"input_tokens": 999, "output_tokens": 999}, "content": [{"type": "tool_use"}]}}) + "\n")
