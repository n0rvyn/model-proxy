# Claude Code Feature Coverage Audit (CC ≤ 2.1.282)

**Date:** 2026-09-25
**Status:** Research. No code changes yet; each item below needs a decision.
**Question:** What has Claude Code (CC) changed since ModelProxy's workarounds were written? Which ModelProxy transforms can now be retired, and which new CC behaviours are not covered yet?

## Sources

- CC `CHANGELOG.md` up to **2.1.282** (npm, 2026-09-24): https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md
- CC docs:
  - `llm-gateway-protocol`: the gateway contract. The most important page here.
  - `llm-gateway-connect`
  - `env-vars`
  - `model-config`
  - `errors`
  - `feature-availability`

  All under https://code.claude.com/docs/en/.
- ModelProxy source at `0cedda6`.

Version numbers below (for example "CL 2.1.152") point to CHANGELOG entries. "Docs" means the current docs pages. Anything marked *(inferred)* has not been checked against a live CC session.

## 0. Overview

ModelProxy's core value is still unique. CC can rename models:
- `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL`
- `modelOverrides`
- `CLAUDE_CODE_SUBAGENT_MODEL`

But it has **no way to send different models to different base URLs**. That model→vendor routing is still the proxy's job.

ModelProxy's design choice, where the source model is a real `claude-*` ID that the proxy rewrites, has one important consequence. **CC treats every routed request as a real Claude model** and sends all Claude features: adaptive thinking, `output_config.effort`, `context_management`, beta tool fields, and `anthropic-beta` headers. That drives most of the "new gaps" below.

| # | ModelProxy feature | Verdict | Why |
|---|---|---|---|
| 1 | Model routing / key swap / `model` byte-replace | **Keep** | CC has no per-model base URL |
| 2 | `ToolUseIDNormalizer` (Anthropic routes) | **Keep** | CC's own cleanup only runs when *directly* connected to Anthropic |
| 3 | `sanitizeToolsForVendor` + `vendorSafeBlockTypes` | **Keep** | Schema-less tools and Anthropic-only blocks still reach vendors |
| 4 | `WebSearchBridge` | **Keep** | CC WebSearch is still server-tool only, with no gateway fallback |
| 5 | `ToolCallInputGuard` | **Keep, narrow the drop policy** | Vendor string-input bugs are still open upstream; dropping calls is now worse than letting CC validate them |
| 6 | `count_tokens` bypass to default upstream | **Simplify: answer 404 locally** | `count_tokens` is optional now; CC falls back to a local estimate |
| 7 | Thinking strip + branch/lineage replay | **Candidate for removal, experiment first** | CC now strips stale signatures on model switch and retries on signature rejection |
| 8 | Session scoping from body fields | **Replace with headers** | CC never sends those body fields; it sends `X-Claude-Code-Session-Id` |
| N1 | Beta body fields / headers to vendors | **New gap** | CC does not retry these |
| N2 | Model presets | **Stale** | Missing the Claude 5 family and the Fable tier |
| N3 | `HEAD /api/hello`, `GET /v1/models` | **Minor gap** | Currently answered with 400 "missing model field" |
| N4 | Gateway hint headers | **New opportunity** | Traffic log could show main / subagent / compaction / auxiliary |
| N5 | 120 s request deadline | **Verify** | May cut long streams; CC's own default is 600 s |

---

## 1. Keep: model routing

- CC now has `modelOverrides` (CL 2.1.73), `ANTHROPIC_DEFAULT_*_MODEL` including FABLE, `ANTHROPIC_CUSTOM_MODEL_OPTION`, `modelPicker`, and `CLAUDE_CODE_SUBAGENT_MODEL`. Since CL 2.1.251 that last one is only a *default*; `_FORCE` restores the old override behaviour.
- All of these rename the model ID. None changes the endpoint. Docs `env-vars` and `settings-reference` have no per-model URL.
- If a user renames tiers in CC with `ANTHROPIC_DEFAULT_OPUS_MODEL=deepseek-v4`, CC treats the ID as unknown. Unknown IDs get a 200K context window and a 32K max output. The source-ID-is-a-Claude-ID approach avoids that, so the README should keep recommending it.

## 2. Keep: `ToolUseIDNormalizer`

- CL 2.1.246 fixed "resumed sessions failing every turn with a 400 when the saved history contains tool blocks the Anthropic API does not accept (typically written by a third-party API proxy)".
- But Docs `errors` → "Unsupported tool content removed" says: *"Claude Code removes it only when the session connects directly to the Anthropic API, and loads the saved history as it is when the session runs through a proxy."*
- ModelProxy users always run through a proxy (`ANTHROPIC_BASE_URL=localhost`), so CC's fix never applies to them. Vendor IDs such as `functions.Bash:0` would still 400 on Anthropic without the normalizer.
- Caveat (Docs `llm-gateway-protocol`): the preserved-thinking check rejects with `bound to a different conversation` when earlier `messages` differ from the request that produced the thinking. The normalizer only rewrites *invalid* IDs, and CC removes thinking and retries on that error, so this is acceptable. Keep the normalizer a no-op for valid IDs.

## 3. Keep: tool / block sanitizing for mapped vendors

Tool definitions without a `name` or `input_schema` still reach vendors:

| What CC sends | Status in CC | Source |
|---|---|---|
| `tool_search_tool_20250101` with no `input_schema` | Only when `ENABLE_TOOL_SEARCH=true`; still open | #95087 |
| `advisor_20260301` | CC stopped sending it behind `ANTHROPIC_BASE_URL` (CL 2.1.276) and retries without it on a 400 (CL 2.1.280) | CL |
| `web_search_*` server tools | Handled by the bridge when it is off | — |

`vendorSafeBlockTypes` filters out `server_tool_use`, `web_search_tool_result`, `tool_reference`, `advisor_*` and similar block types in history. CC does not clean these up behind a proxy (see §2). Keep both; they are cheap.

## 4. Keep: `WebSearchBridge`

- CC WebSearch still uses the hosted `web_search_20250305` server tool. Docs `tools-reference`: *"To search with a different provider, add an MCP server."* For an `ANTHROPIC_BASE_URL` gateway, availability "matches the underlying provider". There is no fallback and no gateway gate.
- #85087 (open) shows vendors still reject the tag. The bridge is still the only thing that makes WebSearch work on mapped models.
- Minor: `clientSearchBlocks` synthesizes `server_tool_use` / `web_search_tool_result` blocks with no `encrypted_content`.
  - CL 2.1.282 made CC tolerate "web-search results the API can't decrypt … from a turn answered through a third-party gateway".
  - CC's WebSearch tool stores results as plain text in the main transcript (Docs), so the synthesized blocks only live in the WebSearch side request.
  - Low risk; no change needed.
- The bridge already handles `web_search_20260209`. Re-check the tool version strings each release.

## 5. Keep `ToolCallInputGuard`, but narrow what it drops

**Still needed.** #92316 (open, 2026-09-05) shows `messages.N.content.M.tool_use.input: Input should be a valid dictionary (2013)`. A vendor emitted a string `input`, CC stored it, and every later turn to that vendor fails. The deterministic repairs are still valuable:
- `input_string_parsed`
- `name_case_normalized`
- `empty_input_inserted`

Consider enabling them for **all** portable vendors, not only DeepSeek.

**Worth changing: the drop paths.** These drop reasons now do more harm than good:
- `unknown_tool`
- `missing_required_field`
- `field_type_mismatch`
- `additional_properties_removed` (silently changes the arguments)

Reasons:
- CC validates tool input against the schema itself and returns an error `tool_result`, so the model retries with the error in context.
- CL 2.1.251: on a retry after a malformed tool call, CC drops the broken output from the retry context.
- The guard replaces a dropped call with a text block but **never adjusts `stop_reason`**. `grep stop_reason` finds nothing in `PortableContentNormalizer` or `ToolCallInputGuard`. A response can therefore end with `stop_reason: "tool_use"` and no `tool_use` block, which ends the turn with no retry for the model. *(Inferred CC behaviour; worth one test.)*

**Proposal:** keep the repairs. On a failure that can't be repaired, pass the block through unchanged and let CC produce the validation error. As a fallback, at least rewrite `stop_reason` to `end_turn` when every `tool_use` block was dropped.

## 6. Simplify: `count_tokens` bypass

**Today:** `count_tokens` for a vendor with `supportsAnthropicCountTokens == false` is re-routed to the client's default upstream (api.anthropic.com) with the user's original key.

**What changed in CC:**
- Docs `llm-gateway-protocol`: *"Token-counting endpoints are the only optional ones: when they're absent, Claude Code falls back to a character-based estimate of context usage."*
- CL 2.1.261: `/context` uses a local estimate "when the token-counting API is unavailable, instead of extra small-model requests".

**Problems with the bypass:**
1. The full prompt of a vendor-routed conversation is sent to Anthropic. That is a surprising data flow for a user who routed the model *away* from Anthropic.
2. A user with no Anthropic key gets a 401, which CC then treats as unavailable anyway.

**Proposal:** for those vendors, return an Anthropic-shaped `404 not_found_error` locally and let CC estimate.
- This removes `effectiveTarget(for:resolvedTarget:passthroughTarget:)` and its bypass logging.
- Keep the vendor toggle.
- *(Verify on a live CC build that a 404 selects the estimate path without a visible error.)*

## 7. Candidate for removal: thinking strip + branch/lineage replay

This is the largest block of code:
- `SessionLineageBroker`
- the branch half of `TranscriptProjector`
- `BranchRequestCoordinator`
- `BranchReplayRecorder`
- `BranchMergeReducer`
- `LineageStore`
- `ConversationFingerprint`
- portable mode of `PortableContentNormalizer`
- `lineages.json`

Together: about 1.3k production lines plus about 2.3k test lines.

**Why it exists** (ADR `03-decisions/2026-03-29-thinking-block-layered-handling.md`):
- Vendor thinking must never reach Anthropic unsigned. So the proxy strips thinking from vendor responses before CC sees them.
- Vendors like DeepSeek and MiniMax still need their thinking back on tool-result turns. So the proxy stores the vendor transcript and splices it back in.

**What changed in CC:**
- CL 2.1.152: "Fixed sessions getting stuck after a model or login switch left stale thinking-block signatures in history; now stripped proactively with a retry safety-net."
- Docs `llm-gateway-protocol` → automatic retry: when the upstream rejects a thinking signature, CC "removes earlier thinking blocks from the request, retries, and keeps them out of every later request".
- CL 2.1.259: a single rejection no longer repeats every turn.
- CL 2.1.282: `redacted_thinking` data errors also drop thinking and retry.

**Possible simpler design:** relay vendor thinking to CC untouched, on the same path as passthrough.
- CC stores it and sends it back to the same vendor, which is what DeepSeek and MiniMax want.
- If the session later switches to real Claude, CC strips it proactively. If it doesn't, Anthropic rejects the block and CC's retry removes it.
- Subagents are separate conversations, so a DeepSeek subagent's thinking never enters the Opus main transcript.

**Unknowns to test before deleting anything:**
1. Vendor thinking blocks with **no** `signature` field. Anthropic's error is then about a missing field, not an invalid signature. Does CC's retry match that wording?
2. A DeepSeek/MiniMax session, then `/model opus`, then several turns, then `/model` back.
3. A main session on Opus with a subagent on DeepSeek.
4. The minimum CC version this relies on (≥ 2.1.152, ideally ≥ 2.1.259). The app cannot enforce it.

**Proposal:**
- Add a hidden per-vendor or debug toggle, "Relay vendor thinking to client (requires CC ≥ 2.1.259)".
- Run the four scenarios.
- If they pass, delete the replay machinery in a separate PR and write an ADR superseding the 2026-03-29 one.
- Until then, keep it.

## 8. Replace: session scoping should use CC's headers

- `ProxyForwarder.explicitSessionScopeKey` looks for `session_id`, `conversation_id` and `thread_id` in the body or `metadata`, and for `container.id`. **CC sends none of these.**
  - Its `metadata` holds only `user_id`, a string that embeds device, account and session IDs.
  - So for CC, `sessionScopeKey` is always `nil`, and branch reuse falls back to the heuristic that matches branches across *all* sessions by hash prefix.
- CC headers:

| Header | Since | Contents |
|---|---|---|
| `X-Claude-Code-Session-Id` | CL 2.1.86 | Sent on every request "so proxies can aggregate requests by session without parsing the body" |
| `x-claude-code-agent-id`, `x-claude-code-parent-agent-id` | CL 2.1.139 | Sent on subagent requests; IDs are fresh per spawn |

- **Proposal:**
  - If §7's replay machinery stays, derive the scope from these headers.
  - Either way, record `session id` / `agent id` on `TrafficEntry` so the traffic log can group by session or subagent. These are only IDs, not bodies, so they don't conflict with the no-body-logging rule.

## N1. New gap: Claude-only request fields sent to mapped vendors

Docs `llm-gateway-protocol`: on `ANTHROPIC_BASE_URL`, CC "sends it the beta headers and request body fields it sends to api.anthropic.com". Because ModelProxy's source IDs are real Claude IDs, CC sends everything, and **CC only retries some of these**:

| Field / header | CC retries on vendor 400? |
|---|---|
| `thinking: {type:"adaptive"}` | Yes, disables thinking for the conversation |
| advisor tool | Yes (CL 2.1.280) |
| mid-conversation `role:"system"` | Yes, as a user message |
| `context_management` | **No** |
| `output_config` (effort, structured output) | **No** |
| tool `strict` / `defer_loading` / `eager_input_streaming` | **No** |
| `anthropic-beta` header values | **No** |

The client-side switch, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`, also turns these features off for passthrough Claude requests in the same session. That is the wrong trade-off for mixed routing.

**Proposal:** a per-vendor "Strip Claude-only request features" compatibility transform on mapped routes only.
- What it removes:
  - `context_management`
  - `output_config`, unless the vendor documents it
  - the three tool fields
  - the `anthropic-beta` header
- Where it runs: it goes next to `sanitizeToolsForVendor`, which already re-serializes the body for mapped routes, so signature bytes are not a concern there.
- Before adding it: probe each vendor's actual 400 wording. Many vendors silently ignore unknown fields.
- Documentation: `CLAUDE.md` allows "documented routing compatibility transforms". Record it in `05-features/`.

## N2. Stale model presets

- `KnownAnthropicModels.current` lists only `claude-opus-4-7`, `claude-sonnet-4-6` and `claude-haiku-4-5`.
- Current IDs are `claude-opus-5-5`, `claude-sonnet-5`, `claude-fable-5-1` and `claude-haiku-4-5-20251001`. CC's `opus` alias resolves to Opus 5.5 since CL 2.1.280, and there is a new **Fable** tier (`ANTHROPIC_DEFAULT_FABLE_MODEL`).
- Prefix rules like `claude-opus-` still match, but the picker is out of date.
- The Opus 4.7, Sonnet 4.6 and 4.x IDs should move to `legacy`.

## N3. Startup probes answered with 400

- **`HEAD /api/hello`:** CC's connection-warming probe (Docs). ModelProxy runs it through `router.resolve` and answers `400 Bad request: missingModelField`. CC ignores the failure, but it can add noise.
  - Proposal: answer `200` locally for `HEAD` requests with no body.
- **`GET /v1/models`:** only sent when the user opts in with `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1`. CC keeps only IDs containing `claude`.
  - Optional: synthesize a list from the enabled routing-rule source models. Every source model is a `claude-*` ID, so the rules would appear in CC's `/model` picker.

## N4. Gateway hint headers

CL 2.1.273 added these headers. On a custom base URL they are sent only with `CLAUDE_CODE_GATEWAY_HINT_HEADERS=1`:

| Header | Values |
|---|---|
| `x-claude-code-request-class` | `main` / `subagent` / `workflow` / `compaction` / `auxiliary` |
| `x-claude-code-agent-type` | — |
| `x-claude-code-compaction` | — |
| `x-claude-code-context-compacted` | — |

**Proposal:**
- Add the variable to the copyable export command in `ClientsTabView`.
- Show the request class in the traffic log. This could replace the current "auxiliary" dimming heuristic.
- If §7's replay stays, drop cached branches when `x-claude-code-context-compacted` arrives.

## N5. Verify: 120 s overall deadline

- `executeUpstream` calls `httpClient.execute(request, timeout: .seconds(readTimeoutSeconds))`. The default is 120 s, and the passthrough target hard-codes 120.
- If AsyncHTTPClient applies that deadline to the whole response body (*to verify*), then long Opus streams over 2 minutes are cut off.
- CC's own `API_TIMEOUT_MS` default is 600 s. Since CL 2.1.281, CC treats a cleanly closed but incomplete stream as truncated and retries it, which would make this show up as retries rather than silent truncation.
- Proposal: confirm with a long streaming request. If it truncates, use an idle or read timeout for streaming instead of a total deadline.

## Already compliant with the gateway contract (no action)

- SSE chunks are forwarded immediately, including `ping` events. CC's watchdog counts bytes, with a 300 s idle limit.
- Upstream error bodies are relayed unmodified. CC's capability-rejection retries depend on the error wording.
- Passthrough bodies are byte-identical. The `model` field is replaced in place, so `system` block order and `cache_control` are preserved.
- `anthropic-version` / `anthropic-beta` are forwarded verbatim on passthrough.

## Suggested order

1. N2 (presets) and N3 (`HEAD`): trivial, no risk.
2. §6 (`count_tokens` → local 404): small; removes a surprising data flow.
3. §5 (guard drop policy / `stop_reason`): small, with test coverage already in place.
4. §8 + N4 (session/agent headers, request class): observability, low risk.
5. N1 (strip Claude-only fields): per-vendor probe first.
6. §7 (retire branch replay): experiment behind a toggle, then a separate cleanup PR with an ADR.
