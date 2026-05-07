---
type: plan
status: active
tags: [websearch, proxy, traffic-log, sse]
refs:
  - docs/01-discovery/2026-04-02-minimax-websearch-replay-observability-research.md
  - docs/03-decisions/2026-04-11-litellm-integration.md
  - docs/11-crystals/2026-03-06-proxy-routing-crystal.md
  - docs/11-crystals/2026-03-26-proxy-encoding-crystal.md
---

# WebSearch Bridge Observability Implementation Plan

**Goal:** Make App-internal WebSearchBridge forwarding report the correct executed search count to the client and show as a distinct Web Search item in the Menu Bar Recent Requests list.

**Architecture:** Keep WebSearchBridge as the only compatibility layer for mapped vendors that cannot consume Anthropic server-side WebSearch directly. Track successful provider search invocations inside the bridge, synthesize client-facing Anthropic-compatible WebSearch usage and content blocks, and keep branch/replay assistant history based on the vendor final answer rather than synthetic client-only search blocks. Mark only the App-internal bridge path, including branch replay rows, in `TrafficEntry.RequestKind`, so passthrough official WebSearch remains unchanged.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, AsyncHTTPClient, SwiftNIO, Anthropic Messages API WebSearch response shape.

**Design doc:** none

**Design analysis:** none

**Crystal file:** docs/11-crystals/2026-03-06-proxy-routing-crystal.md; docs/11-crystals/2026-03-26-proxy-encoding-crystal.md

**Threat model:** included

**Pre-flight risks:**
- `TrafficEntry.RequestKind` callers exist in `ModelProxy/Proxy/ProxyForwarder.swift`, `ModelProxy/Views/StatusPopover.swift`, `ModelProxyTests/WebSearchBridgeTests.swift`, and preview/test code; adding a case requires updating `endpointLabel`, `isAuxiliary`, `shouldDisplayTPS`, display labels, and every construction site.
- `WebSearchBridgeResult` is produced only by `ModelProxy/Services/WebSearchBridge.swift` and consumed in `ModelProxy/Proxy/ProxyForwarder.swift`; adding `webSearchRequestCount` is low blast radius but must be wired into both TrafficLog and tests.
- `WebSearchBridge.shouldHandle` currently matches only `web_search_20250305`; Anthropic docs currently list `web_search_20260209` as the latest tool version while keeping `web_search_20250305` available. The bridge must recognize both versions.
- Branch replay paths append `requestKind` unchanged after replaying `bridgeResult.clientResponse`; replay metadata needs a cache-side way to preserve WebSearchBridge request kind and search count.
- `TrafficRowView` is private, so row text is not directly testable unless display/accessibility label helpers move to `TrafficEntry` or `TrafficEntry.RequestKind`.
- `Array.mapAsync` uses an `@Sendable` closure; mutating an outer `searchObservations` array inside that closure violates Swift 6 concurrency. Return observations from the loop or use an explicit sequential loop.
- The bridge has two tool representations by design: mapped-vendor function `tool_use`/`tool_result` during the internal loop, and client-facing Anthropic `server_tool_use`/`web_search_tool_result` after synthesis. Do not send the client-facing server-tool blocks back to mapped vendors.
- `TranscriptProjector` strips `server_tool_use` from vendor-ready requests but portable branch history can retain non-standard blocks; the bridge must commit a branch assistant turn derived from the vendor final answer, not the client-facing synthetic WebSearch blocks.

---

## Threat Model

### Attack surface

- Upstream model `tool_use.input.query` controls the search query passed to `WebSearchBridgeProviding.search`; validate non-empty text through the existing `toolCall(from:)` path before calling the provider.
- Search provider titles, URLs, and snippets are external strings embedded into JSON response bodies and SSE events; encode with `JSONSerialization`/`TranscriptProjector.encodeJSONObject`, never string-concatenate JSON.
- Client request `tools[*].max_uses` controls loop count for `web_search_20250305`; keep the existing bounded loop from `PreparedRequest.maxUses` and preserve the current `maxUsesExceeded` error behavior. `web_search_20260209` requests without `max_uses` use the same current default.

### Failure modes

- If provider search throws, the bridge returns the existing 502 path and writes a WebSearchBridge traffic row with status 502 and zero completed searches.
- If final client-response synthesis fails, the request fails through the existing WebSearch bridge catch path instead of returning malformed JSON/SSE.
- If TrafficLog rendering does not recognize a future request kind, it falls back to existing labels through exhaustive Swift `switch` handling at compile time.

### Resource lifecycle

- No new sockets or files are introduced. Existing provider calls reuse the injected `HTTPClient`; lifecycle remains owned by `ProxyServer`.
- New arrays of search observations are request-scoped local values and are released when `WebSearchBridge.execute` returns or throws.
- SSE chunks remain in the existing `ReplayableBranchResponse.bodyChunks` lifecycle and are replayed by `ResponseRelay.replay`.

### Input validation requirements

- `toolCall(from:)` continues to reject missing/blank query input and clamps `max_results` to `1...8`.
- Client-facing `web_search_result.url` and `title` values are encoded as JSON strings; no shell, SQL, regex, or template execution is introduced.
- Do not add API keys, provider credentials, raw request bodies, snippets, or full search result content to `TrafficEntry`; Recent Requests remains metadata-only.

<!-- section: task-1 keywords: WebSearchBridge, web_search_requests, SSE -->
### Task 1: Synthesize Anthropic WebSearch Count and Client Blocks

**Files:**
- Modify: `ModelProxy/Services/WebSearchBridge.swift:12-16`
- Modify: `ModelProxy/Services/WebSearchBridge.swift:43-60`
- Modify: `ModelProxy/Services/WebSearchBridge.swift:94-168`
- Modify: `ModelProxy/Services/WebSearchBridge.swift:202-327`
- Modify: `ModelProxy/Services/WebSearchBridge.swift:378-404`

**Data flow:** mapped-vendor `tool_use(name: "web_search")` -> app provider search -> mapped-vendor `tool_result` loop -> final vendor answer -> client-facing Anthropic WebSearch usage/content blocks.

**Design ref:** Anthropic WebSearch docs: latest tool type is `web_search_20260209`, previous available type is `web_search_20250305`; response content uses `server_tool_use` and `web_search_tool_result`; usage uses `usage.server_tool_use.web_search_requests`; streaming includes those blocks in the SSE stream.

**Steps:**
1. Extend `WebSearchBridgeResult` with:
   ```swift
   let webSearchRequestCount: Int
   ```
2. Add a private request-scoped observation type inside `WebSearchBridge`:
   ```swift
   private struct SearchObservation: Sendable {
       let toolCall: ToolCall
       let results: [WebSearchResult]
   }
   ```
3. Replace the single `bridgedToolType` string check with a set:
   ```swift
   private static let bridgedToolTypes: Set<String> = [
       "web_search_20250305",
       "web_search_20260209"
   ]
   ```
   Update `shouldHandle` and `prepareRequest` to use `bridgedToolTypes.contains(type.lowercased())`.
4. In `execute`, add `var searchObservations: [SearchObservation] = []`. Do not mutate that array inside the current `mapAsync` `@Sendable` closure. Use one of these Swift-6-safe forms:
   ```swift
   var resultBlocks: [[String: Any]] = []
   for toolCall in outcome.toolCalls {
       let results = try await provider.search(
           query: toolCall.query,
           maxResults: toolCall.maxResults,
           httpClient: httpClient
       )
       searchObservations.append(SearchObservation(toolCall: toolCall, results: results))
       resultBlocks.append([
           "type": "tool_result",
           "tool_use_id": toolCall.id,
           "content": formatSearchResults(results, query: toolCall.query)
       ])
   }
   ```
   Or return `(block, observation)` tuples from `mapAsync` and append observations after the await completes.
5. Build two final bodies when the vendor stops calling tools:
   - `branchBodyData`: the normalized final vendor answer with usage totals only; use this for `assistantTurn`.
   - `clientBodyData`: the client-facing body with synthetic `server_tool_use`/`web_search_tool_result` blocks inserted before the final answer content and `usage.server_tool_use.web_search_requests` set to `searchObservations.count`.
6. Replace `bodyDataByReplacingUsage` with a helper that accepts `webSearchRequestCount: Int?`. When the count is non-nil, encode:
   ```swift
   "usage": [
       "input_tokens": inputTokens,
       "output_tokens": outputTokens,
       "server_tool_use": [
           "web_search_requests": webSearchRequestCount
       ]
   ]
   ```
   When nil, keep the current token-only usage shape for branch history.
7. Add a helper that converts observations into client blocks:
   ```swift
   [
       "type": "server_tool_use",
       "id": observation.toolCall.id,
       "name": "web_search",
       "input": ["query": observation.toolCall.query]
   ]
   [
       "type": "web_search_tool_result",
       "tool_use_id": observation.toolCall.id,
       "content": observation.results.map {
           [
               "type": "web_search_result",
               "title": $0.title,
               "url": $0.url
           ]
       }
   ]
   ```
   Do not include provider snippets in the client response; the mapped vendor already consumed snippets during the internal loop, and Recent Requests must remain content-free.
8. Update `synthesizeSSE` to accept `webSearchRequestCount`. Add `server_tool_use` and `web_search_tool_result` cases:
   - `server_tool_use`: emit `content_block_start`, `content_block_delta` with `input_json_delta`, and `content_block_stop`.
   - `web_search_tool_result`: emit `content_block_start` carrying the full result block, then `content_block_stop`.
9. Put `server_tool_use.web_search_requests` in the `message_delta.usage` object in streaming responses. Keep `input_tokens` in `message_start.message.usage` and `output_tokens` in `message_delta.usage`.

**Quality markers:**
- One provider search invocation increments the count by one, regardless of result count.
- Multiple `tool_use` blocks in one model turn increment by the number of successful provider calls.
- Empty result arrays still count as one completed search when the provider returns successfully.
- Synthetic WebSearch blocks are client-facing only; branch assistant history remains the final vendor answer without synthetic server-tool blocks.
- Both `web_search_20250305` and `web_search_20260209` trigger the bridge for mapped vendors.
- The implementation compiles under Swift 6 without mutating a captured variable inside an `@Sendable` closure.

**Verify:**
Run: `rg -n "webSearchRequestCount|SearchObservation|bridgedToolTypes|web_search_20260209|server_tool_use|web_search_tool_result|web_search_requests" ModelProxy/Services/WebSearchBridge.swift`

Expected: matches show both supported tool types, the result field, observation tracking, client block synthesis, usage synthesis, and SSE handling.
<!-- /section -->

<!-- section: task-2 keywords: TrafficLog, RequestKind, StatusPopover -->
### Task 2: Add a WebSearchBridge Request Kind and Row Label

**Files:**
- Modify: `ModelProxy/Models/TrafficLog.swift:14-44`
- Modify: `ModelProxy/Models/TrafficLog.swift:47-76`
- Modify: `ModelProxy/Views/StatusPopover.swift:350-390`
- Modify: `ModelProxy/Views/StatusPopover.swift:401-414`
- Modify: `ModelProxy/Views/StatusPopover.swift:435-440`

**User interaction:** Opening the Menu Bar popover shows bridged App-internal WebSearch requests as rows labeled `Web Search` while ordinary generation, count_tokens, auxiliary, blocked, and passthrough official WebSearch requests keep their current display.

**Steps:**
1. Add a new request kind:
   ```swift
   case webSearchBridge(searchCount: Int)
   ```
2. Update `endpointLabel`:
   ```swift
   case .webSearchBridge:
       return "web_search"
   ```
3. Update `isAuxiliary` so `.webSearchBridge` is not treated as auxiliary; it is a user-visible generation-side capability, not a background probe.
4. Update `shouldDisplayTPS` so only `.generation` displays tokens-per-second. WebSearchBridge rows should show `-` in the existing t/s column unless a separate count label is added later by user request.
5. Move row display semantics to testable model helpers on `TrafficEntry`:
   ```swift
   var displayModelLabel: String {
       switch requestKind {
       case .webSearchBridge(let searchCount):
           return searchCount == 1
               ? "Web Search - \(model)"
               : "Web Search (\(searchCount)) - \(model)"
       default:
           return model
       }
   }
   ```
6. Add a testable accessibility helper:
   ```swift
   var accessibilitySummary: String { ... }
   ```
   It must include `Web Search`, the source model, route label, HTTP status, duration, and search count for `.webSearchBridge`.
7. Use `entry.displayModelLabel` in the first `Text` column and `entry.accessibilitySummary` in `.accessibilityLabel(...)`.
8. Add one preview entry with `.webSearchBridge(searchCount: 1)` so visual review covers the new row.

**Quality markers:**
- The row label changes only for `.webSearchBridge`; this is set only by the App-internal bridge path in Task 3.
- `TrafficEntry` continues to store no request body, query text, provider snippets, or credentials.
- The first text column still uses `lineLimit(1)` and `.truncationMode(.middle)`, so long source model names do not overflow.

**Verify:**
Run: `rg -n "webSearchBridge|displayModelLabel|accessibilitySummary|Web Search" ModelProxy/Models/TrafficLog.swift ModelProxy/Views/StatusPopover.swift`

Expected: matches show the new request kind, testable label helpers, accessibility branch, and preview entry.
<!-- /section -->

<!-- section: task-3 keywords: ReplayableBranchResponse, WebSearchBridge, TrafficMetadata -->
### Task 3: Preserve WebSearchBridge Traffic Metadata Across Replay

**Files:**
- Modify: `ModelProxy/Models/TrafficLog.swift:14-76`
- Modify: `ModelProxy/Services/BranchRequestCoordinator.swift:9-13`
- Modify: `ModelProxy/Services/WebSearchBridge.swift:123-142`
- Read: `ModelProxy/Proxy/ResponseRelay.swift:258-290`
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:158-176`
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:221-253`

**Crystal ref:** docs/11-crystals/2026-03-06-proxy-routing-crystal.md [D-004], [D-005], [D-006]; docs/11-crystals/2026-03-26-proxy-encoding-crystal.md [D-003]

**Steps:**
1. Add replay-safe metadata to `ReplayableBranchResponse`:
   ```swift
   let trafficRequestKind: TrafficEntry.RequestKind?
   ```
   Add a default `nil` value to its initializer so existing construction sites remain source-compatible.
2. When `WebSearchBridge.execute` constructs `ReplayableBranchResponse`, set:
   ```swift
   trafficRequestKind: .webSearchBridge(searchCount: searchObservations.count)
   ```
   Do this for both JSON and synthesized SSE replayable responses.
3. Inspect `ResponseRelay.replay`; it currently writes `cachedResponse.statusCode`, `cachedResponse.headers`, and `cachedResponse.bodyChunks` directly and does not create a new `ReplayableBranchResponse`. No code change is needed there unless execution finds a new copy path.
4. Update branch replay traffic entries in `ProxyForwarder.forward`:
   - replay path near the cached response branch
   - leader-failed replay path
   Use:
   ```swift
   requestKind: cachedResponse.trafficRequestKind ?? requestKind
   ```
   and:
   ```swift
   requestKind: replay.trafficRequestKind ?? requestKind
   ```
5. Keep normal branch coordination behavior unchanged. Metadata changes only how Recent Requests labels replayed cached responses.

**Quality markers:**
- First bridge request and replayed bridge followers all show as Web Search rows.
- Non-bridge replayed generation requests keep their original request kind.
- No response body content, query text, snippets, or credentials are stored in replay metadata.

**Verify:**
Run: `rg -n "trafficRequestKind|cachedResponse\\.trafficRequestKind|replay\\.trafficRequestKind|webSearchBridge" ModelProxy/Services/BranchRequestCoordinator.swift ModelProxy/Services/WebSearchBridge.swift ModelProxy/Proxy/ProxyForwarder.swift ModelProxy/Proxy/ResponseRelay.swift`

Expected: matches show metadata on `ReplayableBranchResponse`, WebSearchBridge sets it, and ProxyForwarder replay paths consume it.
<!-- /section -->

<!-- section: task-4 keywords: ProxyForwarder, TrafficEntry, WebSearchBridgeResult -->
### Task 4: Wire Bridge Counts into ProxyForwarder Direct Traffic Entries

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:274-362`
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:364-382`

**Crystal ref:** docs/11-crystals/2026-03-06-proxy-routing-crystal.md [D-004], [D-005], [D-006]; docs/11-crystals/2026-03-26-proxy-encoding-crystal.md [D-003]

**Steps:**
1. In the WebSearchBridge success branch, keep route resolution, failover, token stats, response replay, and branch coordination unchanged.
2. Change the direct success `TrafficEntry` construction to:
   ```swift
   requestKind: .webSearchBridge(searchCount: bridgeResult.webSearchRequestCount)
   ```
3. Change the direct bridge failure `TrafficEntry` construction to:
   ```swift
   requestKind: .webSearchBridge(searchCount: 0)
   ```
4. Keep `WebSearchBridge.shouldHandle` restricted to mapped, non-passthrough generation requests with supported Anthropic WebSearch tool types. This preserves passthrough official WebSearch behavior.
5. Do not add separate traffic rows for each provider search call. Recent Requests records the client request, with count metadata, not every internal provider call.

**Quality markers:**
- App-internal bridge success rows show as `Web Search` in Recent Requests.
- App-internal bridge failures show as `Web Search` with HTTP 502.
- Replayed bridge rows are handled by Task 3 and must also show as `Web Search`.
- Passthrough official WebSearch and normal generation requests remain `.generation`.
- Token statistics continue to use `bridgeResult.inputTokens` and `bridgeResult.outputTokens`.

**Verify:**
Run: `rg -n "requestKind: \\.webSearchBridge|webSearchRequestCount|bridge=web_search" ModelProxy/Proxy/ProxyForwarder.swift`

Expected: matches show bridge success and failure traffic entries use `.webSearchBridge`, and existing bridge logging remains.
<!-- /section -->

<!-- section: task-5 keywords: WebSearchBridgeTests, TrafficLog, SwiftTesting -->
### Task 5: Cover Count, Client Blocks, SSE, Replay Metadata, and Traffic Labels with Tests

**Files:**
- Modify: `ModelProxyTests/WebSearchBridgeTests.swift:64-122`
- Modify: `ModelProxyTests/WebSearchBridgeTests.swift:190-229`
- Modify: `ModelProxyTests/WebSearchBridgeTests.swift:302-351`
- Modify: `ModelProxyTests/ModelProxyTests.swift`
- Modify: `ModelProxyTests/BranchRequestCoordinatorTests.swift`

**Steps:**
1. Add or update a `WebSearchBridge.shouldHandle` test for both supported tool versions:
   ```swift
   #expect(WebSearchBridge.shouldHandle(bodyData: try requestBody(stream: true, toolType: "web_search_20250305"), target: mappedTarget, requestKind: .generation) == true)
   #expect(WebSearchBridge.shouldHandle(bodyData: try requestBody(stream: true, toolType: "web_search_20260209"), target: mappedTarget, requestKind: .generation) == true)
   ```
2. Update `executeLoopsThroughSearchAndReturnsFinalAssistantResponse`:
   - Assert `result.webSearchRequestCount == 1`.
   - Assert `result.clientResponse.trafficRequestKind == .webSearchBridge(searchCount: 1)`.
   - Assert the client response `usage.server_tool_use.web_search_requests == 1`.
   - Assert client content contains `server_tool_use`, `web_search_tool_result`, and the final text.
   - Assert `result.assistantTurn` portable/full content used for branch commit does not contain `server_tool_use` or `web_search_tool_result`.
3. Update `executeHandlesMultipleToolCallsInSingleTurn`:
   - Assert `result.webSearchRequestCount == 2`.
   - Assert `result.clientResponse.trafficRequestKind == .webSearchBridge(searchCount: 2)`.
   - Assert final client usage reports `web_search_requests == 2`.
   - Assert there are two `web_search_tool_result` blocks.
4. Update `synthesizeSSEProducesValidEventStream`:
   - Include `server_tool_use` and `web_search_tool_result` blocks in the input body.
   - Call the updated signature with `webSearchRequestCount: 1`.
   - Assert the stream contains `server_tool_use`, `web_search_tool_result`, and `"web_search_requests":1`.
5. Add this Swift Testing unit in `ModelProxyTests.swift`:
   ```swift
   @Test func webSearchBridgeRequestKindUsesDedicatedDisplaySemantics() {
       let kind = TrafficEntry.RequestKind.webSearchBridge(searchCount: 2)
       #expect(kind.endpointLabel == "web_search")
       #expect(kind.isAuxiliary == false)
       #expect(kind.shouldDisplayTPS == false)
       let entry = TrafficEntry(
           model: "claude-sonnet-4-6",
           routeType: .mapped(targetModel: "MiniMax-M2.7"),
           requestKind: kind,
           httpStatus: 200,
           duration: 1.2
       )
       #expect(entry.displayModelLabel == "Web Search (2) - claude-sonnet-4-6")
       #expect(entry.accessibilitySummary == "Web Search, claude-sonnet-4-6, 2 searches, MiniMax-M2.7, HTTP 200, 1s, - t/s")
   }
   ```
6. Add a replay-focused unit to `BranchRequestCoordinatorTests.swift` because that file already exercises coordinator replay and constructs `ReplayableBranchResponse` values:
   ```swift
   @Test func replayResponsePreservesTrafficRequestKind() async throws {
       let coordinator = BranchRequestCoordinator()
       let context = makeContext(hashes: ["m1"])
       let firstDecision = await coordinator.acquire(context: context)
       let leaderLease = switch firstDecision {
       case .acquired(let lease): lease
       default: Issue.record("Expected leader lease acquisition"); throw TestAbort()
       }

       let followerTask = Task {
           await coordinator.acquire(context: context)
       }
       await Task.yield()

       let replay = ReplayableBranchResponse(
           statusCode: 200,
           headers: [("content-type", "application/json")],
           bodyChunks: [Data("{}".utf8)],
           trafficRequestKind: .webSearchBridge(searchCount: 1)
       )
       await coordinator.complete(lease: leaderLease, replay: replay)

       let followerDecision = await followerTask.value
       switch followerDecision {
       case .replay(let cachedResponse, _):
           #expect(cachedResponse.trafficRequestKind == .webSearchBridge(searchCount: 1))
       default:
           Issue.record("Expected replay decision"); throw TestAbort()
       }
   }
   ```
7. Add a default initializer assertion in the same file by updating an existing `ReplayableBranchResponse` construction that omits `trafficRequestKind`:
   ```swift
   #expect(replay.trafficRequestKind == nil)
   ```

**Quality markers:**
- Tests prove the client-visible count is based on provider calls, not search result count.
- Tests prove branch history does not retain synthetic server-tool blocks.
- Tests prove multiple searches in one model turn report the correct count.
- Tests prove Recent Requests semantics and exact display/accessibility labels identify only the App-internal bridge kind.
- Tests prove cached/replayed bridge responses carry the WebSearchBridge request kind.
- Tests prove both `web_search_20250305` and `web_search_20260209` are supported.

**Verify:**
Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -only-testing:ModelProxyTests/WebSearchBridgeTests`

Expected: `TEST SUCCEEDED` and no Swift Testing failures in `WebSearchBridgeTests`.

Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -only-testing:ModelProxyTests/ModelProxyTests`

Expected: `TEST SUCCEEDED` and no Swift Testing failures in `ModelProxyTests`.

Run: `xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -only-testing:ModelProxyTests/BranchRequestCoordinatorTests`

Expected: `TEST SUCCEEDED` and no Swift Testing failures in `BranchRequestCoordinatorTests`.
<!-- /section -->

## Decisions

None.

## M&M Self-Check

[自检-表面] 本次任务最容易违反哪条规则？
答：做完整不做一半 — 这个改动同时影响客户端响应、SSE、branch replay metadata、Recent Requests 展示和测试；只改 WebSearchBridge 会让 Menu Bar 或 replay 行继续显示成普通 generation。

[自检-隐蔽] 本次任务中，哪个"看起来已完成"的步骤最可能实际未生效？
答：Recent Requests 的 `Web Search` 展示 — 如果只新增 `RequestKind.webSearchBridge`，但 replay cached response 没带 `trafficRequestKind`，重复请求仍会走 cached replay 并显示为普通 `messages` 行。

[自检-造轮子] 本次方案中是否有手写逻辑在解决平台 API 已覆盖的问题？
答：Anthropic WebSearch 响应合成和 TrafficEntry display/accessibility 文本 — 已查官方 WebSearch 响应字段和当前 SwiftUI/TrafficLog 代码；平台 API 不负责把第三方普通 tool call 转换成 Anthropic server tool 响应，也不负责业务行文案生成。

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-05-07
