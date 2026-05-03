---
type: plan
status: active
tags: [proxy, deepseek, tool-call-guard, count-tokens]
refs:
  - docs/11-crystals/2026-03-06-proxy-routing-crystal.md
  - docs/11-crystals/2026-03-26-proxy-encoding-crystal.md
---

# DeepSeek Count Tokens and Tool Guard Implementation Plan

**Goal:** Prevent DeepSeek-routed Claude Code sessions from failing on unsupported Anthropic `count_tokens` requests and malformed returned tool-call inputs while keeping the fix reusable for other vendors.

**Architecture:** Add vendor-level capability switches for Anthropic `count_tokens` support and response tool-call input guarding. `count_tokens` for vendors that do not support it bypasses the mapped vendor and uses the client default upstream with the original auth headers, preserving the Anthropic auxiliary API contract instead of sending it to a vendor endpoint that parses it as generation. Tool-call input repair is a generic Anthropic response transformer enabled per vendor; DeepSeek is auto-inferred to disable `count_tokens` routing and enable tool-call repair for legacy configs unless the user has explicitly saved different values.

**Tech Stack:** Swift, SwiftUI, Swift Testing, NIO, AsyncHTTPClient, JSONSerialization

**Design doc:** none

**Design analysis:** none

**Crystal file:** docs/11-crystals/2026-03-06-proxy-routing-crystal.md; docs/11-crystals/2026-03-26-proxy-encoding-crystal.md

**Threat model:** included

**Pre-flight risks:**
- Existing `Vendor` and `RoutingSnapshot.RouteTarget` already carry `supportsThinkingBlocks`; new vendor switches must follow the same Codable defaulting and snapshot propagation pattern.
- `ResponseRelay` currently streams upstream chunks immediately for SSE and for non-normalized JSON; tool-call repair must not corrupt response framing or compression assumptions from `docs/11-crystals/2026-03-26-proxy-encoding-crystal.md`.
- `count_tokens` is currently classified in `ProxyForwarder.requestKind(for:)` but follows the same mapped routing path as `/v1/messages`; DeepSeek logs show this path returns `missing field max_tokens`.
- Existing UI in `VendorEditSheet` uses native `Toggle` and `Picker`; new controls must reuse those controls and not introduce custom dropdown or custom form styling.

---

## User Requirements

- Add a vendor switch for Anthropic `count_tokens` support.
- Add DeepSeek-enabled tool-call input repair, built as reusable vendor-gated logic so another vendor can opt in later.
- Do not introduce global behavior that changes other vendors unless their vendor switch is enabled.
- Preserve existing thinking-block support and existing fallback model picker work.
- Include unit tests for supported and unsupported paths.

## Threat Model

### Attack surface

- Upstream model responses can contain attacker-influenced `tool_use.input` payloads. Attack class: malformed structured input, schema mismatch, and unintended tool execution.
- Vendor configuration is user-controlled and persisted in plaintext config. Attack class: misconfiguration causing requests to bypass intended vendors.
- `count_tokens` bypass forwards original request auth to the client default upstream. Attack class: credential sent to an unintended host if a client default upstream is misconfigured by the user.

### Failure modes

- If `supportsAnthropicCountTokens` is false and the default upstream is unavailable or rejects auth, ModelProxy surfaces that upstream status to Claude Code instead of silently estimating tokens.
- If tool-call guard repair cannot make an input match the request tool schema, ModelProxy removes the invalid `tool_use` block from the client-visible response and logs the vendor, request ID, tool name, and reason without logging argument values.
- If whole-response JSON parsing fails, ModelProxy leaves the response unchanged and logs the parse failure because it cannot locate trusted `tool_use` blocks.
- If a located `tool_use.input` string cannot be parsed into a JSON object, that single tool call is invalid and must not be sent to Claude Code as executable input.

### Resource lifecycle

- No new files, sockets, or child processes are created by the runtime path.
- Response buffering for non-streaming guard-enabled responses is scoped to one relay call and released after `relay` returns.
- SSE tool-use buffering is scoped per content block and cleared on `content_block_stop` or stream finish.

### Input validation requirements

- Validate `tool_use.input` against the active request `tools[].input_schema` before returning it to Claude Code when the vendor guard is enabled.
- Only perform deterministic repairs: parse JSON string inputs into objects, normalize missing object input to `{}` only when the schema has no required fields, and remove extra keys only when `additionalProperties == false`.
- Required-field absence, wrong scalar type, unknown tool name, and unparseable JSON string are invalid and must not be passed to Claude Code as executable tool calls.

## Architecture Notes

- Chose a generic engine named around Anthropic tool-call input guarding, not DeepSeek. DeepSeek receives inferred legacy defaults from its base URL, while future vendors can reuse the same engine by toggling the same setting.
- Chose `count_tokens` bypass to client default upstream over local estimation. DeepSeek documentation describes usage from generation responses and offline tokenizer use, but not an Anthropic `/v1/messages/count_tokens` endpoint; local estimation would silently change behavior and produce inaccurate context decisions.
- Chose native SwiftUI `Toggle` rows in `VendorEditSheet` to match the existing vendor capability UI.

<!-- section: task-1 keywords: Vendor, RoutingSnapshot, capabilities -->
### Task 1: Add Vendor Capability Fields

**Files:**
- Modify: `ModelProxy/Models/Vendor.swift`
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift`
- Test: `ModelProxyTests/ModelProxyTests.swift`

**Steps:**
1. Extend `VendorDefaults` with:
   - `supportsAnthropicCountTokens = true`
   - `repairsAnthropicToolCalls = false`
   - `static func isDeepSeekBaseURL(_ baseURL: String) -> Bool`
   - `static func supportsAnthropicCountTokens(forBaseURL baseURL: String) -> Bool`
   - `static func repairsAnthropicToolCalls(forBaseURL baseURL: String) -> Bool`
2. Define DeepSeek-inferred legacy defaults by base URL:
   - DeepSeek base URLs containing `api.deepseek.com` default to `supportsAnthropicCountTokens = false`.
   - DeepSeek base URLs containing `api.deepseek.com` default to `repairsAnthropicToolCalls = true`.
   - Non-DeepSeek vendors keep generic defaults `true` and `false`.
3. Add `supportsAnthropicCountTokens: Bool` and `repairsAnthropicToolCalls: Bool` to `Vendor`, its initializer, `CodingKeys`, decoder defaults, and encoder behavior through synthesized `encode`.
4. In `Vendor.init(from:)`, use `decodeIfPresent` semantics so absent fields infer by base URL, while explicit user-saved booleans override inference.
5. Add matching immutable fields to `RoutingSnapshot.RouteTarget` and propagate them for primary mapped targets, backup targets, route-all fallback targets, and passthrough targets.
6. Keep passthrough targets as `supportsAnthropicCountTokens = true` and `repairsAnthropicToolCalls = false`.
7. Add tests that legacy DeepSeek JSON without the new fields decodes to `false/true`, legacy non-DeepSeek JSON decodes to `true/false`, explicit values round-trip and override inference, mapped targets copy both fields, backup targets copy both fields, and fallback route-all targets copy both fields.

**Verify:**
Run: `rg -n "supportsAnthropicCountTokens|repairsAnthropicToolCalls" ModelProxy ModelProxyTests`
Expected: fields appear in `Vendor`, `RoutingSnapshot`, UI bindings, and tests.
<!-- /section -->

<!-- section: task-2 keywords: VendorEditSheet, SwiftUI, Toggle -->
### Task 2: Expose Vendor Switches in Add/Edit Vendor

**Files:**
- Modify: `ModelProxy/Views/VendorEditSheet.swift`

**Steps:**
1. Add `@State` fields initialized from `VendorDefaults`:
   - `supportsAnthropicCountTokens`
   - `repairsAnthropicToolCalls`
2. In the existing `Vendor Details` section, add native SwiftUI toggles:
   - `Toggle("Supports Count Tokens", isOn: $supportsAnthropicCountTokens)`
   - `Toggle("Repair Tool Call Inputs", isOn: $repairsAnthropicToolCalls)`
3. Populate both state fields in `onAppear` when editing an existing vendor.
4. Save both fields in the edit path and pass both fields into the new `Vendor(...)` initializer in the add path.
5. Do not add custom picker/dropdown styles or nested cards.

**User interaction:** In Add Vendor and Edit Vendor, the user sees two normal toggle rows next to the existing thinking-block capability row.

**Verify:**
Run: `rg -n "Supports Count Tokens|Repair Tool Call Inputs|supportsAnthropicCountTokens|repairsAnthropicToolCalls" ModelProxy/Views/VendorEditSheet.swift`
Expected: both labels and both state bindings are present.
<!-- /section -->

<!-- section: task-3 keywords: ProxyForwarder, count_tokens, RoutingSnapshot -->
### Task 3: Bypass Unsupported Vendor Count Tokens

**Files:**
- Modify: `ModelProxy/Proxy/RoutingSnapshot.swift`
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift`
- Test: `ModelProxyTests/ModelProxyTests.swift`
- Test: `ModelProxyTests/ProxyForwarderTests.swift`

**Crystal ref:** [D-001], [D-005] from `docs/11-crystals/2026-03-06-proxy-routing-crystal.md`

**Steps:**
1. Add a `RoutingSnapshot.passthroughTarget(originalAPIKey:)` method that constructs the same passthrough target used by unmapped passthrough routing.
2. In `ProxyForwarder.forward`, after route resolution and before lineage projection, if `requestKind == .countTokens`, `target.isPassthrough == false`, and `target.supportsAnthropicCountTokens == false`, replace the effective target with `router.passthroughTarget(originalAPIKey:)`.
3. Log one info line with request ID, original vendor name, and default upstream when bypassing.
4. Ensure the bypass path does not sanitize tools, replace the model field, or apply vendor transcript projection intended for the mapped vendor.
5. Keep traffic log route type as passthrough for the bypassed request so the UI does not report it as a DeepSeek generation.
6. Add focused tests for the target-selection helper and the count-token bypass decision helper. If extracting a helper is needed for testability, make it a small pure `static` function on `ProxyForwarder`.

**Verify:**
Run: `rg -n "countTokens|supportsAnthropicCountTokens|passthroughTarget" ModelProxy/Proxy ModelProxyTests`
Expected: count-token bypass exists in the forwarder and has tests.
<!-- /section -->

<!-- section: task-4 keywords: ToolCallInputGuard, JSONSchema, tool_use -->
### Task 4: Build Generic Anthropic Tool-Call Input Guard

**Files:**
- Create: `ModelProxy/Services/ToolCallInputGuard.swift`
- Test: `ModelProxyTests/ToolCallInputGuardTests.swift`

**Steps:**
1. Create `ToolCallInputGuard` as a pure Swift service with no network or UI dependencies.
2. Add a `ToolCatalog` builder that reads `tools` from the outbound request body after `sanitizeToolsForVendor(in:)` and maps `tools[].name` to `input_schema`.
3. Add a `repairToolUseBlock(_:)` method that accepts a single Anthropic `tool_use` block and returns:
   - `.unchanged`
   - `.repaired(block, reason)`
   - `.dropped(reason)`
4. Implement deterministic repairs:
   - If `input` is a JSON object string, parse it into an object.
   - If `input` is missing and schema type is object with no required fields, set `input` to `{}`.
   - If schema type is object and `additionalProperties == false`, remove keys not present in `properties`.
5. Implement invalid cases:
   - Unknown tool name.
   - `input` is missing while required fields exist.
   - `input` is neither object nor parseable object string.
   - Required field missing after repair.
   - Known scalar field has a type that conflicts with `string`, `integer`, `number`, `boolean`, `array`, or `object`.
6. When dropping a block, return a safe text block creator helper such as `ToolCallInputGuard.invalidToolTextBlock(toolName:reason:)` so ResponseRelay can keep the assistant response structurally valid without executing the invalid tool.
7. Add unit tests for parse-string repair, empty-object repair, additionalProperties cleanup, unknown tool drop, required-field drop, and scalar type drop.

**Verify:**
Run: `rg -n "ToolCallInputGuard|ToolCatalog|repairToolUseBlock" ModelProxy ModelProxyTests`
Expected: guard service and tests are present.
<!-- /section -->

<!-- section: task-5 keywords: ResponseRelay, SSE, tool_use -->
### Task 5: Apply Tool Guard to JSON and SSE Responses

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift`
- Modify: `ModelProxy/Proxy/ResponseRelay.swift`
- Modify: `ModelProxy/Services/PortableContentNormalizer.swift`
- Test: `ModelProxyTests/ResponseRelayTests.swift`
- Test: `ModelProxyTests/ToolCallInputGuardTests.swift`

**Crystal ref:** [D-001], [D-002], [D-003] from `docs/11-crystals/2026-03-26-proxy-encoding-crystal.md`

**Steps:**
1. In `ProxyForwarder`, after `forwardBodyData` is finalized, build the request `ToolCatalog` from that exact forwarded body.
2. After `executeWithFailover` returns, build `ToolCallInputGuard` only when `usedTarget.repairsAnthropicToolCalls == true`; pass `nil` otherwise. Do not decide guard enablement from only the primary target, because failover can switch vendors.
3. Add an optional guard parameter to `ResponseRelay.relay`.
4. For non-streaming JSON responses, buffer the body when guard is enabled, transform `content[].type == "tool_use"` blocks, then write the transformed body to the client. Preserve existing portable normalization order by applying tool repair before branch portable reduction.
5. For SSE responses, run guard-enabled SSE transformation whenever `toolCallGuard != nil`, independent of `branchContext`, `portableNormalizer`, or replay state. If both portable normalization and tool guarding are active, compose them in one event pipeline rather than making tool guarding depend on replay.
6. For SSE `tool_use` blocks, buffer the block until `content_block_stop`, repair or drop it, and then emit valid Anthropic SSE events. Text and non-tool blocks continue to stream normally.
7. Ensure dropped invalid tool blocks are replaced with a text content block and no invalid `tool_use` reaches the client.
8. Log per request ID only counts and reason labels, not tool argument values.
9. Keep behavior unchanged when guard is nil.
10. Add tests covering:
   - Guard disabled: invalid tool block is relayed unchanged.
   - Guard enabled non-streaming: JSON-string input becomes object.
   - Guard enabled non-streaming: invalid required input is removed/replaced with text.
   - Guard enabled SSE: buffered `input_json_delta` is repaired before client-visible output.
   - Guard enabled SSE with `branchContext == nil`: invalid streamed tool input does not pass through.
   - Failover: guard enablement follows `usedTarget.repairsAnthropicToolCalls`, not the primary target.
   - Whole-response parse failure remains unchanged, while unparseable `tool_use.input` string is dropped.

**Verify:**
Run: `rg -n "repairsAnthropicToolCalls|ToolCallInputGuard|toolCallGuard" ModelProxy/Proxy ModelProxy/Services ModelProxyTests`
Expected: response relay accepts and uses the guard; tests cover disabled and enabled behavior.
<!-- /section -->

<!-- section: task-6 keywords: tests, xcodebuild, ModelProxyTests -->
### Task 6: Focused Tests and Build Validation

**Files:**
- Modify: `ModelProxyTests/ModelProxyTests.swift`
- Modify: `ModelProxyTests/ProxyForwarderTests.swift`
- Modify: `ModelProxyTests/ResponseRelayTests.swift`
- Create: `ModelProxyTests/ToolCallInputGuardTests.swift`

**Steps:**
1. Add Swift Testing unit tests for all new business logic. Use `@Test` and `#expect`; do not introduce XCTest.
2. Keep tests focused on pure logic where possible to avoid real network calls.
3. Run the ModelProxy macOS test suite once after implementation.
4. Run `git diff --check` to catch whitespace damage.

**Verify:**
Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -only-testing:ModelProxyTests test`
Expected: `** TEST SUCCEEDED **`
<!-- /section -->

## Decisions

None.

## Plan Self-Check

[self-check-surface] The easiest rule to violate is "do complete work, not half work" because fixing only non-streaming responses would leave Claude Code streaming tool calls able to hit the same `Invalid tool parameters` path.

[self-check-hidden] The step most likely to look done but fail at runtime is SSE repair because unit tests must verify actual client-visible SSE event order, not just final accumulated blocks.

[self-check-reinventing] The schema repair logic is hand-written because Swift Foundation has no built-in JSON Schema validator. The plan keeps it intentionally small and deterministic instead of claiming full JSON Schema compliance.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-05-03
