#!/usr/bin/env python3
"""Summarizes a `claude -p --output-format stream-json --verbose` transcript.

Usage: summarize_stream.py run.jsonl [--json]
Prints tool calls, failed tool results, the final result and subagent counts.
"""
import json
import sys


def summarize(path):
    summary = {"tool_calls": [], "tool_errors": [], "result": None}
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        kind = event.get("type")
        if kind == "assistant":
            for block in event["message"].get("content", []):
                if block.get("type") == "tool_use":
                    summary["tool_calls"].append(block["name"])
        elif kind == "user":
            content = event["message"].get("content")
            if isinstance(content, list):
                for block in content:
                    if block.get("type") == "tool_result" and block.get("is_error"):
                        summary["tool_errors"].append(str(block.get("content"))[:300])
        elif kind == "result":
            summary["result"] = {
                key: event.get(key)
                for key in ("subtype", "is_error", "num_turns", "api_error_status", "terminal_reason", "result", "session_id")
            }
            summary["result"]["subagents_spawned"] = (event.get("subagent_stats") or {}).get("spawned", 0)
    return summary


if __name__ == "__main__":
    s = summarize(sys.argv[1])
    if "--json" in sys.argv:
        print(json.dumps(s))
    else:
        print("tool calls: ", s["tool_calls"])
        print("tool errors:", s["tool_errors"])
        print("result:     ", json.dumps(s["result"], ensure_ascii=False)[:600])
