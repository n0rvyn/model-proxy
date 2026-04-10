# MiniMax WebSearch, Replay Miss, and Recent Requests Observability Research

**Date:** 2026-04-02  
**Status:** Verified

## Scope

This note records only findings that were verified from code, runtime logs, or direct API calls.

Topics:
- MiniMax compatibility with Anthropic WebSearch
- Why branch replay still shows `reused=false`
- Why `claude-opus-4-6 pass 200 —` appears between MiniMax requests in Recent Requests

## Verified Sources

### Code

- [ModelProxy/Services/TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift)
- [ModelProxy/Services/SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift)
- [ModelProxy/Services/BranchRequestCoordinator.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/BranchRequestCoordinator.swift)
- [ModelProxy/Services/ToolUseIDNormalizer.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/ToolUseIDNormalizer.swift)
- [ModelProxy/Proxy/ProxyForwarder.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift)
- [ModelProxy/Proxy/ResponseRelay.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ResponseRelay.swift)
- [ModelProxy/Models/TrafficLog.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models/TrafficLog.swift)
- [ModelProxy/Views/StatusPopover.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift)

### Logs

- `/Users/norvyn/Library/Containers/com.90percent.ModelProxy/Data/Library/Application Support/ModelProxy/logs/modelproxy-2026-04-01.log`
- `/Users/norvyn/Library/Containers/com.90percent.ModelProxy/Data/Library/Application Support/ModelProxy/logs/modelproxy-2026-04-02.log`
- `/Users/norvyn/Library/Containers/com.90percent.ModelProxy/Data/Library/Application Support/ModelProxy/lineages.json`

### Direct API verification

- MiniMax Anthropic-compatible endpoint from user-approved `~/.adam/.env`
- No secrets are recorded in this document

## Findings

### 1. MiniMax does not support Anthropic server-side WebSearch semantics

#### Verified fact

The proxy currently does not rewrite top-level `tools`, `tool_choice`, or `web_search` definitions. It only rewrites `messages` for `.portableOnly` replay targets.

Evidence:
- `[TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift#L20)` only projects `messages`
- repo search for `WebSearch|web_search|tool_choice|input_schema|search_query|search_result` in Swift sources returned no implementation hits for a compatibility layer

#### Verified fact

MiniMax accepts ordinary Anthropic-compatible function tools, but rejects Anthropic official WebSearch tool payloads.

Direct API verification results:
- Plain `/v1/messages` request: success
- Normal function tool with `input_schema`: success
- Anthropic official WebSearch tool:
  ```json
  {"type":"web_search_20250305","name":"web_search","max_uses":3}
  ```
  Result: `invalid params, function name or parameters is empty (2013)`

#### Verified fact

If `web_search_20250305` is artificially given a function-style `input_schema`, MiniMax accepts it, but treats it as a normal function tool. It returns `tool_use(name="web_search", input=...)`; it does not execute server-side search and does not return search results.

#### Verified fact

This matches runtime failures already seen in app logs.

Evidence from logs:
- 2026-04-01: upstream returned `invalid params, function name or parameters is empty (2013)`
- 2026-04-02: upstream returned `invalid params`

#### Conclusion

The current WebSearch failure is not caused by the recent thinking/replay commits. The first failure point is vendor incompatibility: MiniMax does not accept Anthropic `web_search_20250305` as a server tool.

### 2. Replay still misses because portable hashes include replay-unstable fields

#### Verified fact

Observed MiniMax traffic still logs:
- `reused=false`
- `reusedPortable=0`

This pattern repeats across the active Claude Code conversation on 2026-04-02.

#### Verified fact

The replay matcher is prefix-based:
- `[TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift#L104)` matches by `vendorKey` plus portable hash prefix
- `[SessionLineageBroker.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/SessionLineageBroker.swift#L104)` exposes all branches for a `clientName`
- `[BranchRequestCoordinator.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/BranchRequestCoordinator.swift#L109)` and `#L117` also compare portable hash sequences

#### Verified fact

Portable normalization is currently too narrow.

Current behavior:
- strips thinking / redacted thinking / signatures
- normalizes tool IDs
- does not remove `cache_control`
- does not canonicalize tool-use payload volatility such as empty-vs-expanded `input`

Evidence:
- `[TranscriptProjector.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/TranscriptProjector.swift#L187)` to `#L210`
- `[ToolUseIDNormalizer.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Services/ToolUseIDNormalizer.swift#L77)` to `#L120`

#### Verified fact

Decoded `lineages.json` entries show replay divergence near the tail, not across the whole conversation.

Two verified examples from consecutive portable transcripts:

- Same `tool_result`, different payload:
  - older transcript includes `cache_control: {type:"ephemeral"}`
  - newer transcript omits `cache_control`

- Same `tool_use(name="Write")`, different payload:
  - older transcript stores `input: {}`
  - newer transcript stores full `input.content`

Both differences change the per-message hash even though the user-visible conversation meaning is the same for replay purposes.

#### Conclusion

Replay is currently missing because portable hashes are still sensitive to fields that should not participate in replay identity.

### 3. The interleaved `claude-opus-4-6` rows are `count_tokens` probes, not invalid model turns

#### Verified fact

The rows that look like:
- `claude-opus-4-6`
- `pass`
- `200`
- `0.3s`
- `—`

map to log lines of this form:

```text
POST /v1/messages/count_tokens?beta=true model=claude-opus-4-6 passthrough → https://api.anthropic.com
```

They are not `/v1/messages` requests.

#### Verified fact

The adjacent MiniMax rows are normal generation requests:

```text
POST /v1/messages?beta=true model=claude-sonnet-4-6 mapped → MiniMax → https://api.minimaxi.com/anthropic
```

#### Verified fact

The Opus `count_tokens` probes are lightweight, one-message requests:
- `msgs=1`
- `assistant=0`
- `ProjectionDiag delta=0`
- `thinking.config=none`

They are not assistant-generation turns.

#### Verified fact

Recent Requests has no endpoint or request-kind field. It only records:
- `model`
- `routeType`
- `httpStatus`
- `duration`
- `outputTokens`

Evidence:
- `[TrafficLog.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Models/TrafficLog.swift#L7)` to `#L33`

#### Verified fact

TPS is blank because the UI only shows it when `outputTokens > 0`.

Evidence:
- `[StatusPopover.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Views/StatusPopover.swift#L407)` to `#L410`
- `[ProxyForwarder.swift](/Users/norvyn/Code/Projects/ModelProxy/ModelProxy/Proxy/ProxyForwarder.swift#L230)` to `#L272`
- `count_tokens` responses do not provide generated output tokens

#### Conclusion

The interleaved Opus rows are real requests, but they are auxiliary token-count requests. The current UI makes them look like full model turns because it does not distinguish request kind.

## Commit Range Reviewed

Git history verified from `v2.0.0` to `HEAD`.

Commits directly relevant to these findings:
- `39707aa feat(services): add ToolUseIDNormalizer for vendor ID sanitization`
- `90e747f feat(proxy): integrate ToolUseID normalization across proxy layer`
- `3ad5a38 fix(proxy): enable gzip/deflate decompression, block Brotli in upstream requests`
- `6d7f38f feat(proxy): wire source model tracking and output token capture`
- `39f8526 feat(proxy): add layered thinking block handling`
- `4d88968 feat(transcript): add vendor-ready message construction`
- `4e02953 refactor(proxy): remove stripUnsignedThinkingBlocks from outbound path`
- `0fd27f6 test: update tests for request-only thinking block handling`

## First-Principles Target State

If implementation complexity is ignored and the priority is product quality:

- WebSearch should become a proxy-native, vendor-agnostic capability for mapped vendors
- Replay should use both session-scoped isolation and stronger portable canonicalization
- Recent Requests should keep auxiliary traffic visible, but clearly mark request kind and lower the visual weight of non-generation requests

## Non-Conclusions

These items were not proven:

- that the recent commits already injected invalid Opus assistant turns into the main conversation
- that a single replay bug alone explains the WebSearch failure
- that hiding `count_tokens` traffic would be better than labeling it
