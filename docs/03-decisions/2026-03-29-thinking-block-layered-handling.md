# ADR: Thinking Block Handling for Third-Party Vendors

**Date:** 2026-03-29
**Status:** Accepted (revised)
**Issue:** #4 — MiniMax 400: portable transformation strips thinking blocks required by multi-turn tool calls

## Context

ModelProxy's portable transformation strips ALL thinking blocks from both request and response directions. This causes Anthropic-compatible third-party vendors (MiniMax, Qwen) to fail on multi-turn tool call conversations because they require complete conversation history including thinking blocks.

However, Anthropic's API requires thinking blocks to have valid cryptographic signatures. The proxy must not allow unsigned thinking blocks (from third-party vendors) to reach Anthropic.

These two requirements are in direct conflict:
- Third-party vendors need thinking blocks preserved in requests
- Anthropic rejects thinking blocks without valid signatures

## Research Findings (Verified via WebFetch)

### Anthropic API Thinking Block Rules

Source: https://platform.claude.com/docs/en/docs/build-with-claude/extended-thinking (fetched 2026-03-29)

| Rule | Exact quote from docs |
|------|----------------------|
| Tool use requires thinking | "During tool use, you must pass thinking blocks back to the API...if this is not passed in, **an error is raised**" |
| Prior turns can omit thinking | "While you can omit thinking blocks from **prior** assistant role turns" |
| Signature enables server decryption | "The server decrypts the signature to reconstruct the original thinking for prompt construction" |
| Must not modify | "pass them unchanged...can't rearrange or modify the sequence of these blocks" |
| Thinking blocks always carry signature | Every thinking block example in docs includes a `signature` field |

**Critical implication**: Anthropic bodies containing signed thinking blocks must NEVER be re-serialized through `JSONSerialization`. JSON re-serialization (even with `.sortedKeys`) can alter byte representation and corrupt signature values.

### MiniMax Anthropic API Compatibility

Source: https://platform.minimaxi.com — Anthropic API Compatibility (user-provided full doc text, page is SPA, cannot WebFetch)

| Aspect | Exact quote |
|--------|------------|
| Multi-turn tool call | "必须将完整的模型返回（即 assistant 消息）添加到对话历史，以保持思维链的连续性" |
| Complete content required | "response.content 是一个列表，包含多种类型的内容块，必须完整回传" |
| `thinking` support | Parameter table: "完全支持" |

## Failed Approach: Layered Handling (Both Directions)

**What we tried:** Change portable transformation to keep thinking content (strip only `signature` field) in both request AND response directions. Add `stripUnsignedThinkingBlocks()` guard at Anthropic boundary to strip unsigned thinking before it reaches Anthropic.

**Why it failed (two regressions):**

1. **Response-side thinking preservation leaked unsigned thinking to the client.** Client stored third-party thinking blocks (without signatures). When client sent requests to Anthropic (passthrough), unsigned thinking was present. The `stripUnsignedThinkingBlocks` guard was supposed to catch these, but...

2. **`stripUnsignedThinkingBlocks` re-serialized JSON bodies with `encodeJSONObject(.sortedKeys)`.** When the body contained VALID Anthropic-signed thinking blocks alongside unsigned ones, the re-serialization corrupted the signed blocks. Anthropic returned: `"Invalid 'signature' in 'thinking' block"`.

**Key lesson:** Any function that parses → modifies → re-serializes a JSON body will corrupt Anthropic thinking signatures. The passthrough path must NEVER modify the body.

## Decision: Request-Side Only Fix

Instead of modifying both directions, separate the two concepts in `TranscriptProjector.prepareRequest()`:

- **`portableMessages`** (thinking-stripped) — used for hash computation and branch matching
- **`vendorReadyMessages`** (thinking-preserved, signature-stripped) — used for building the request body

| Direction | Route Type | Handling |
|-----------|-----------|----------|
| Response → client | Third-party (.portableOnly) | **Unchanged**: strip ALL thinking (prevents cross-vendor contamination) |
| Request → third-party | .portableOnly | **Changed**: body uses `vendorReadyMessages` (keeps thinking, strips signature) |
| Request → Anthropic | .transparent | **Unchanged**: `prepareRequest()` returns early, body untouched |
| Response → client | Anthropic (.transparent) | **Unchanged**: pass through |

### How MiniMax Gets Thinking Back

The branch system stores `fullMessagesData` (with thinking from vendor responses). On subsequent same-vendor requests:

```
Turn 1: [{user}] → MiniMax → response [thinking, tool_use]
         ↓ Response: thinking stripped → client gets [tool_use]
         ↓ Branch stores fullMessages WITH thinking

Turn 2: Client sends [{user}, {assistant: [tool_use]}, {user: [tool_result]}]
         ↓ portableMessages hashes match branch prefix
         ↓ fullMessages = branchFullMessages (WITH thinking) + vendorReadySuffix
         ↓ MiniMax receives [{user}, {assistant: [thinking, tool_use]}, {user: [tool_result]}]
```

### Why Anthropic Is Safe

1. Response normalization strips ALL third-party thinking → client never stores them
2. Client's request to Anthropic has no unsigned thinking → nothing to strip
3. Anthropic passthrough never re-serializes the body → signatures intact

### Changes (Final)

1. `TranscriptProjector` — add `makeVendorReadyMessages()` / `makeVendorReadyBlocks()` (keeps thinking, strips signature + redacted_thinking)
2. `TranscriptProjector.prepareRequest()` — use `vendorReadyMessages` for body construction, `portableMessages` for hash computation
3. No changes to `PortableContentNormalizer`, `ProxyForwarder`, or response handling

### Limitation

If branch matching fails (cold start from outside the proxy, branch evicted), MiniMax won't get thinking blocks. This is acceptable because:
- New conversations always start with a clean first request (no assistant messages)
- The branch is committed after the first response
- Subsequent requests match the branch and get thinking from `fullMessagesData`

## Alternatives Tried and Rejected

### A. Layered handling (both directions) — TRIED, FAILED

See "Failed Approach" section above. JSON re-serialization corrupts Anthropic signatures.

### B. Change replay policy to `.transparent`

Disables branch tracking entirely. Unsigned thinking leaks to Anthropic in cross-vendor scenarios.

### C. Vendor-level `preserveThinkingBlocks` flag

Requires user configuration. Doesn't solve cross-vendor contamination.

**2026-05-03 update:** Accepted as an additional vendor capability guard, not as the standalone fix. The response-to-client rule remains unchanged, so third-party thinking still does not leak to clients. The new capability only controls whether request projection sends `thinking` blocks to a portable third-party vendor.

### D. Replace stripped thinking with empty markers

Hacky. Vendors may not accept empty thinking blocks.

### E. `stripUnsignedThinkingBlocks` at Anthropic boundary

Requires JSON re-serialization → corrupts valid Anthropic signatures. **Proven to fail.**

## Implementation

See `docs/06-plans/2026-03-29-thinking-block-request-only-fix-plan.md`

## Addendum: DeepSeek Anthropic API Thinking Capability (2026-05-03)

DeepSeek's Anthropic-compatible API at `https://api.deepseek.com/anthropic` documents top-level `thinking` support and `content` array `type="thinking"` support. It documents `redacted_thinking` as unsupported.

Observed error from ModelProxy logs on 2026-05-03 10:10:18 +0800:

```
The `content[].thinking` in the thinking mode must be passed back to the API.
```

The evidence shows DeepSeek needs the request-side branch replay behavior from this ADR when tool results continue a thinking-mode assistant turn. The regression risk is that other Anthropic-compatible vendors reject `thinking`. ModelProxy now records this as a vendor capability:

- `supportsThinkingBlocks == true`: request projection can include vendor-ready `thinking` blocks with `signature` stripped.
- `supportsThinkingBlocks == false`: request projection strips `thinking`, `redacted_thinking`, and reasoning-like blocks from both the current suffix and restored branch history.
- Legacy vendors and newly created vendors default this capability to `false`; users explicitly enable it for DeepSeek and other vendors that document support.

The branch reuse scope also changed. Persistent replay scope is no longer derived from the TCP channel when the client body has no explicit session field. TCP channel identity is kept only as coordination scope for in-flight request blocking. This keeps Claude Code connection changes from losing stored vendor-local thinking history while preserving coordination isolation for simultaneous requests.
