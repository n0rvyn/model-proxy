---
category: debugging
keywords: [tool_use, ToolCallInputGuard, ToolUseIDNormalizer, passthrough, repairsAnthropicToolCalls, TCC, sandbox, os_log, live-probe, routing]
date: 2026-06-11
source_project: ModelProxy
---
# Diagnosing "did the proxy mangle the tool call?"

## Context

A Claude Code session (routed through ModelProxy via `ANTHROPIC_BASE_URL=http://localhost:9090`)
showed a Bash tool call that looked broken, and the question was: ModelProxy's bug, or Claude Code's?
The diagnosis flow below answered it without ever reading a request/response body (the proxy stores none).

## Diagnosis flow

1. **Confirm the model actually goes through the proxy.** Check `env | grep ANTHROPIC_BASE_URL`.
   If it points at `localhost:9090`, traffic is proxied.
2. **Determine the route by probing the live proxy** (don't guess, don't read config — it's TCC-locked):
   ```
   curl -sS localhost:9090/v1/messages \
     -H 'x-api-key: probe' -H 'anthropic-version: 2023-06-01' \
     -d '{"model":"<m>","max_tokens":8,"messages":[{"role":"user","content":"x"}]}'
   ```
   An Anthropic-format error (`"type":"error"` with `request_id: req_011C...`) ⇒ that model is
   **passthrough to Anthropic**. A different vendor/error shape ⇒ it's **mapped** to another vendor.
3. **Walk the transform gating table** for that route (below).
4. **Conclude.** If every tool-touching transform is gated off (or is a faithful codec) for that
   route, the proxy cannot be the cause — the content came from the upstream model as-is.

## Tool-call transform gating table

| Transform | File | Runs when | Can it corrupt `tool_use`? |
|---|---|---|---|
| `sanitizeToolsForVendor` (req: drop bad tool defs) | `ProxyForwarder.swift` | mapped vendors only (`if !target.isPassthrough`) | Skipped on passthrough |
| `ToolUseIDNormalizer` (req: rewrite tool_use_id / tool_result_id) | `ToolUseIDNormalizer.swift` | always on Anthropic-signed routes | Only rewrites **invalid** IDs; deterministic + cached, so a tool_use and its matching tool_result map to the **same** new ID (pairing preserved). No-op for native `toolu_...` |
| `ToolCallInputGuard` (resp: repair tool_use input) | `ToolCallInputGuard.swift`, gated by `Vendor.repairsAnthropicToolCalls` | only vendors with `repairsAnthropicToolCalls=true` — **default DeepSeek only** | Off on passthrough; when on, round-trips input through `JSONSerialization` (escapes preserved) |
| portable-normalize (resp: project portable messages) | `PortableContentNormalizer.swift` | only when `branchContext != nil` | Round-trips through `JSONSerialization`; partial_json deltas accumulated then parsed once (no mid-escape split) |

**Conclusion for a claude-* passthrough request:** none of these can corrupt tool-call content.
The proxy does no hand-written string surgery on tool content anywhere — every path is a faithful
JSON codec or is gated off. A malformed command on passthrough came from the real upstream model
(or is a copy/paste rendering artifact), not from ModelProxy.

## Lesson: runtime files are TCC-locked, not perm-locked

The app is sandboxed (`com.90percent.ModelProxy`). Logs/config/lineages live in
`~/Library/Containers/com.90percent.ModelProxy/Data/Library/Application Support/ModelProxy/`.
Claude's shell gets `Operation not permitted` on `head`/`cp`/`ls` **even though perms are
`-rw-r--r-- norvyn`** — it's macOS TCC (needs Full Disk Access), not Unix permissions.
`lsof -p <pid>` still reveals the open log path. To read the file: the app's own log panel,
a user-run `sudo cp ... /tmp/`, or grant the terminal Full Disk Access. os_log is also empty —
subsystem `com.modelproxy.app` persists nothing.

## Prevention

- Don't retry file reads against the sandbox container — recognize `Operation not permitted` as TCC and pivot to a self-service route (live probe, source reading) immediately.
- For any "is the proxy changing X?" question, confirm the route first; most transforms are gated off on passthrough.
