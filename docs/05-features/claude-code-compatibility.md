# Claude Code Compatibility Transforms

## Expected Behavior

Claude Code (CC) talks to ModelProxy through `ANTHROPIC_BASE_URL`. Routed source models are real
`claude-*` IDs, so CC sends every Claude feature to whichever vendor a rule points at. These are the
documented compatibility behaviors ModelProxy applies (verified against CC 2.1.282):

| Behavior | When | What happens |
|---|---|---|
| Local HEAD probe | Any `HEAD` request (CC sends `HEAD /api/hello` at startup) | `200`, empty body, no traffic row, nothing forwarded |
| Local `count_tokens` 404 | Mapped vendor with **Supports Count Tokens** off | Anthropic-shaped `404 not_found_error`; CC falls back to a local estimate. Never 501: CC turns 501 into a one-token generation |
| Session coordination | Request carries `X-Claude-Code-Session-Id` (+ `x-claude-code-agent-id`) | In-flight branch coordination is scoped to that session/agent instead of the TCP channel. Persistent branch reuse stays content-addressed so `/branch` forks and resumes still match |
| Request class in traffic list | `x-claude-code-request-class` (needs `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`, included in the Clients tab export command) or an agent-id header | Row label shows `· subagent`, `· compaction`, …; `auxiliary` rows are dimmed |
| No `x-claude-code-*` to vendors | Mapped routes | Session/agent headers are not forwarded to third parties; passthrough keeps them |
| Strip Claude-only fields (opt-in) | Vendor toggle **Strip Claude-Only Request Fields** | Removes `context_management`, `output_config`, `safeguards`, `speed`, `thread`, tool `strict`/`defer_loading`/`eager_input_streaming`, and the `anthropic-beta` header, per upstream attempt |
| Tool-call shape repair | Vendor toggle **Repair Tool Call Inputs** (default DeepSeek) | Non-object `input` → object (parsed if it is a JSON string, else `{}`), missing input/id inserted, name trimmed / case-matched. Argument content is left for CC to validate. Only a nameless call is removed, and `stop_reason` becomes `end_turn` if no tool call remains |
| Passthrough timeout | Unmapped / passthrough routes | 600 s to the response head (CC's `API_TIMEOUT_MS` default). Streams are never cut by this deadline |
| Branch replay measurement | A portable request reused branch history | Logs `BranchReplay restored thinking blocks=N` when replay restored thinking the client did not send |

## Key Files

| File | Responsibility |
|------|---------------|
| `ModelProxy/Proxy/ProxyForwarder.swift` | HEAD probe, count_tokens 404, scope keys, request class, upstream headers, Claude-only field strip, replay measurement |
| `ModelProxy/Services/ToolCallInputGuard.swift` | Tool-call shape repair and `stop_reason` rule |
| `ModelProxy/Services/PortableContentNormalizer.swift` | SSE re-emission of guarded tool calls, `message_delta` stop reason |
| `ModelProxy/Models/TrafficLog.swift` | `TrafficEntry.RequestClass`, labels, auxiliary dimming |
| `ModelProxy/Models/Vendor.swift`, `ModelProxy/Proxy/RoutingSnapshot.swift` | `stripsClaudeOnlyRequestFields` flag and passthrough timeout |

## Boundary Conditions

- A vendor's own settings decide stripping and header handling on failover and WebSearch bridge turns.
- The strip transform re-serializes the body only when a field was removed, and never runs on passthrough (signed thinking stays byte-identical).
- Upstream error bodies are relayed unmodified; CC's capability-rejection retries match on their wording.
- Stripping `output_config` also removes effort; leave the toggle off for vendors that read it.

## Change History

| Date | Change |
|------|--------|
| 2026-09-25 | Initial version from the CC 2.1.282 coverage audit (`docs/01-discovery/2026-09-25-claude-code-feature-coverage-audit.md`) |
