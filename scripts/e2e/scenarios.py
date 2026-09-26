#!/usr/bin/env python3
"""E2E scenarios for ModelProxy with real Claude Code and a real third-party vendor (DeepSeek).

Run through scenarios.sh, which exports the harness settings. Each scenario prints PASS/FAIL with the
evidence it checked; the exit code is non-zero when any scenario fails.
"""
import argparse
import http.client
import json
import os
import subprocess
import sys
import threading
import time
import uuid

E2E_DIR = os.environ["E2E_DIR"]
E2E_ROOT = os.environ["E2E_ROOT"]
PORT = int(os.environ["E2E_PORT"])
PASSTHROUGH_PORT = int(os.environ["E2E_PASSTHROUGH_PORT"])
LOG_FILE = os.environ["E2E_LOG_FILE"]
WORK = os.path.join(E2E_ROOT, "work")
RUNS = os.path.join(E2E_ROOT, "runs")

sys.path.insert(0, E2E_DIR)
from summarize_stream import summarize  # noqa: E402


# ---------- helpers ----------

def request(method, path, body=None, headers=None, port=PORT, timeout=180):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    all_headers = {"x-api-key": "e2e-dummy", "anthropic-version": "2023-06-01", "content-type": "application/json"}
    all_headers.update(headers or {})
    data = json.dumps(body).encode() if isinstance(body, (dict, list)) else body
    started = time.monotonic()
    conn.request(method, path, body=data, headers=all_headers)
    resp = conn.getresponse()
    raw = resp.read()
    return resp.status, raw, time.monotonic() - started


def log_mark():
    try:
        with open(LOG_FILE, encoding="utf-8", errors="replace") as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def log_since(mark):
    try:
        with open(LOG_FILE, encoding="utf-8", errors="replace") as f:
            return f.readlines()[mark:]
    except FileNotFoundError:
        return []


def reset_workspace():
    os.makedirs(WORK, exist_ok=True)
    files = {
        "notes.txt": "alpha\nbeta\ngamma\n",
        "calc.py": "def add(a, b):\n    return a + b\n",
        "package.json": '{"name":"demo","version":"1.2.3"}\n',
    }
    for name, text in files.items():
        with open(os.path.join(WORK, name), "w") as f:
            f.write(text)


def run_cc(name, prompt, model, tools, extra=None, timeout=600):
    os.makedirs(RUNS, exist_ok=True)
    out = os.path.join(RUNS, f"{name}.jsonl")
    args = [os.path.join(E2E_DIR, "cc.sh"), "-p", *(extra or []), prompt, "--model", model,
            "--allowedTools", tools, "--output-format", "stream-json", "--verbose"]
    with open(out, "w") as f:
        subprocess.run(args, stdout=f, stderr=subprocess.STDOUT, timeout=timeout, check=False)
    return summarize(out)


def cc_succeeded(summary):
    result = summary["result"] or {}
    return result.get("subtype") == "success" and not result.get("is_error") and not result.get("api_error_status")


# ---------- scenarios ----------

def head_probe():
    status, body, elapsed = request("HEAD", "/api/hello")
    return status == 200, f"HEAD /api/hello -> {status} in {elapsed * 1000:.0f} ms"


def count_tokens_forwarded():
    status, body, _ = request("POST", "/v1/messages/count_tokens",
                              {"model": "claude-sonnet-5", "messages": [{"role": "user", "content": "hello"}]})
    ok = status == 200 and "input_tokens" in json.loads(body or b"{}")
    return ok, f"default vendor (count tokens decoded default) -> {status} {body[:80]!r}"


def count_tokens_local_404():
    status, body, elapsed = request("POST", "/v1/messages/count_tokens",
                                    {"model": "claude-sonnet-4-6", "messages": [{"role": "user", "content": "hello"}]})
    error_type = json.loads(body or b"{}").get("error", {}).get("type")
    ok = status == 404 and error_type == "not_found_error" and elapsed < 1
    return ok, f"vendor with count tokens off -> {status} {error_type} in {elapsed * 1000:.0f} ms (never 501)"


def malformed_body_fast():
    status, body, elapsed = request("POST", "/v1/messages", b'{"model":"claude-sonnet-5","messages":"oops')
    # The App Store 2.5 build hung here (0 bytes after 15 s): sendError awaited unflushed writes.
    return status == 400 and elapsed < 2, f"malformed JSON -> {status} in {elapsed * 1000:.0f} ms"


def _concurrent(bodies, headers):
    results = [None] * len(bodies)

    def worker(i):
        results[i] = request("POST", "/v1/messages", bodies[i], headers)

    threads = []
    for i in range(len(bodies)):
        t = threading.Thread(target=worker, args=(i,))
        t.start()
        threads.append(t)
        time.sleep(0.3)
    for t in threads:
        t.join()
    return [json.loads(r[1]) for r in results]


def concurrent_same_session_isolated():
    session = f"e2e-{uuid.uuid4()}"
    tag = uuid.uuid4().hex[:6]

    def body(word):
        return {"model": "claude-sonnet-5", "max_tokens": 400,
                "system": f"You must answer with exactly one word: {word}. Nothing else.",
                "messages": [{"role": "user", "content": f"What is your word? ({tag})"}]}

    apple, banana = _concurrent([body("APPLE"), body("BANANA")], {"x-claude-code-session-id": session})
    # Same session and messages, different system prompt: each must get its own upstream response.
    ok = apple.get("id") and banana.get("id") and apple["id"] != banana["id"]
    texts = [[b.get("text") for b in r.get("content", []) if b.get("type") == "text"] for r in (apple, banana)]
    return bool(ok), f"ids {apple.get('id', '?')[:8]} / {banana.get('id', '?')[:8]}, answers {texts}"


def identical_retry_joined():
    session = f"e2e-{uuid.uuid4()}"
    body = {"model": "claude-sonnet-5", "max_tokens": 400, "system": "Answer with one word: OK.",
            "messages": [{"role": "user", "content": f"Ready? ({uuid.uuid4().hex[:6]})"}]}
    first, second = _concurrent([body, body], {"x-claude-code-session-id": session})
    ok = first.get("id") and first.get("id") == second.get("id")
    return bool(ok), f"identical concurrent requests share one upstream call: {first.get('id', '?')[:8]} / {second.get('id', '?')[:8]}"


def passthrough_relays_anthropic():
    status, body, _ = request("POST", "/v1/messages",
                              {"model": "claude-opus-4-8", "max_tokens": 8, "messages": [{"role": "user", "content": "x"}]},
                              port=PASSTHROUGH_PORT, timeout=60)
    request_id = json.loads(body or b"{}").get("request_id", "")
    ok = status == 401 and request_id.startswith("req_")
    return ok, f"unmapped model on passthrough client -> Anthropic {status} request_id={request_id[:14]}"


def cc_text():
    s = run_cc("cc_text", "Reply with exactly: PONG", "claude-sonnet-5", "")
    ok = cc_succeeded(s) and "PONG" in (s["result"] or {}).get("result", "")
    return ok, f"result={(s['result'] or {}).get('result', '')[:40]!r}"


def cc_tools():
    reset_workspace()
    mark = log_mark()
    s = run_cc("cc_tools",
               "Read notes.txt and calc.py. Add a function mul(a, b) that returns a*b to calc.py using the Edit tool. "
               "Then run: python3 -c 'import calc; print(calc.mul(6,7), calc.add(2,3))' with Bash and report the exact output.",
               "claude-sonnet-5", "Read,Edit,Glob,Grep,Bash(python3:*)")
    reused = sum("reused=true" in line for line in log_since(mark))
    ok = cc_succeeded(s) and not s["tool_errors"] and {"Read", "Edit", "Bash"} <= set(s["tool_calls"])
    ok = ok and "42 5" in (s["result"] or {}).get("result", "")
    return ok, f"tools={s['tool_calls']} errors={len(s['tool_errors'])} branch reuses={reused}"


def cc_strip_vendor():
    mark = log_mark()
    s = run_cc("cc_strip_vendor", "Use Grep to find which file contains the word beta, then Read package.json. "
               "Answer in one line: <file> <version>.", "claude-sonnet-4-6", "Read,Grep,Glob")
    stripped = [line.split("vendor=DeepSeek Strip: ")[-1].strip() for line in log_since(mark) if "Stripped Claude-only fields" in line]
    ok = cc_succeeded(s) and not s["tool_errors"] and bool(stripped)
    return ok, f"stripped fields: {stripped[:1]} result={(s['result'] or {}).get('result', '')[:40]!r}"


def cc_no_thinking_vendor():
    s = run_cc("cc_no_thinking_vendor", "Read notes.txt, then run: python3 -c 'print(2+3)' with Bash and report the output.",
               "claude-opus-4-7", "Read,Bash(python3:*)")
    return cc_succeeded(s) and not s["tool_errors"], f"tools={s['tool_calls']} (DeepSeek's own call ids need no thinking passback)"


def cc_subagents():
    mark = log_mark()
    s = run_cc("cc_subagents", "You must use the Agent tool to spawn two general-purpose subagents in parallel: one reads "
               "notes.txt and returns its line count, the other reads package.json and returns the name field. "
               "Then report both answers in one line.", "claude-sonnet-5", "Agent,Task,Read,Glob,Grep")
    agent_scopes = {line.split("|agent|")[1].split("|")[0] for line in log_since(mark) if "|agent|" in line}
    ok = cc_succeeded(s) and (s["result"] or {}).get("subagents_spawned", 0) >= 2 and len(agent_scopes) >= 2
    labels = [line for line in log_since(mark) if "coordination=" in line]
    return ok, f"subagents={(s['result'] or {}).get('subagents_spawned')} agent scopes={len(agent_scopes)} scoped requests={len(labels)}"


def cc_continue():
    reset_workspace()
    run_cc("cc_continue_seed", "Read calc.py, then add a function mul(a, b) with Edit, then run "
           "python3 -c 'import calc; print(calc.mul(6,7))' with Bash and report the output.",
           "claude-sonnet-5", "Read,Edit,Bash(python3:*)")
    mark = log_mark()
    s = run_cc("cc_continue", "Now add sub(a, b) with Edit, run python3 -c 'import calc; print(calc.sub(9,4))' with Bash "
               "and report the output.", "claude-sonnet-5", "Read,Edit,Bash(python3:*)", extra=["--continue"])
    lines = log_since(mark)
    restored = [line.split("blocks=")[1].split()[0] for line in lines if "BranchReplay restored thinking" in line]
    reuse = ["hit" if "reused=true" in line else "miss" for line in lines if "ProjectionDiag: branch" in line]
    # Known: the 2nd request after --continue misses (issue #9); reported, not asserted.
    return cc_succeeded(s) and not s["tool_errors"], f"restored thinking blocks={restored} branch reuse per request={reuse}"


def websearch():
    mark = log_mark()
    out = os.path.join(RUNS, "websearch.jsonl")
    os.makedirs(RUNS, exist_ok=True)
    args = [os.path.join(E2E_DIR, "cc.sh"), "-p", "Use the WebSearch tool once to find the latest SwiftNIO release "
            "version, then answer in one line.", "--model", "claude-sonnet-5", "--allowedTools", "WebSearch",
            "--output-format", "stream-json", "--verbose"]
    with open(out, "w") as f:
        proc = subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT)
        # Watchdog: a bridge that answers non-2xx makes Claude Code retry, and every retry reruns the searches.
        deadline = time.monotonic() + 240
        failures = 0
        while proc.poll() is None:
            failures = sum("WebSearch bridge failed" in line for line in log_since(mark))
            if failures >= 2 or time.monotonic() > deadline:
                proc.kill()
                break
            time.sleep(1)
        proc.wait()
    lines = log_since(mark)
    bridged = sum("bridge=web_search" in line for line in lines)
    failures = sum("WebSearch bridge failed" in line for line in lines)
    s = summarize(out)
    ok = cc_succeeded(s) and failures == 0 and 1 <= bridged <= 3
    return ok, f"bridge requests={bridged} bridge failures={failures} result={(s['result'] or {}).get('result', '')[:60]!r}"


SCENARIOS = [
    head_probe, count_tokens_forwarded, count_tokens_local_404, malformed_body_fast,
    concurrent_same_session_isolated, identical_retry_joined, passthrough_relays_anthropic,
    cc_text, cc_tools, cc_strip_vendor, cc_no_thinking_vendor, cc_subagents, cc_continue,
]
OPT_IN = [websearch]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default="")
    parser.add_argument("--websearch", action="store_true", help="also run the Google-backed WebSearch scenario (uses search quota)")
    parser.add_argument("--list", action="store_true")
    args = parser.parse_args()

    selected = SCENARIOS + (OPT_IN if args.websearch else [])
    if args.only:
        names = set(args.only.split(","))
        selected = [s for s in SCENARIOS + OPT_IN if s.__name__ in names]
    if args.list:
        for s in SCENARIOS + OPT_IN:
            print(s.__name__ + (" (opt-in)" if s in OPT_IN else ""))
        return 0

    failed = 0
    for scenario in selected:
        started = time.monotonic()
        try:
            ok, detail = scenario()
        except Exception as error:  # a crashed scenario is a failure, not an abort
            ok, detail = False, f"{type(error).__name__}: {error}"
        failed += 0 if ok else 1
        print(f"{'PASS' if ok else 'FAIL'}  {scenario.__name__:<34} {time.monotonic() - started:5.1f}s  {detail}", flush=True)
    print(f"\n{len(selected) - failed}/{len(selected)} passed; transcripts in {RUNS}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
