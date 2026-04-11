---
type: plan
status: active
tags: [proxy, minimax, tool-sanitizer, vendor-compatibility]
refs: []
---

# Vendor Tool Sanitizer Implementation Plan

**Goal:** Prevent MiniMax 400 errors caused by Claude Code sending tool definitions with empty name/parameters fields by sanitizing the `tools` array before forwarding to mapped vendors.

**Architecture:** Extend the existing `stripServerSideTools` into a general-purpose `sanitizeToolsForVendor` that: (1) removes server-side tool types (existing), (2) removes tools with empty/missing `name`, (3) removes tools with missing `input_schema`. Apply this sanitizer in the same code path where `stripServerSideTools` is currently called.

**Tech Stack:** Swift, NIO, JSONSerialization

**Design doc:** none

**Design analysis:** none

**Crystal file:** none

**Threat model:** not applicable

---

## Evidence

MiniMax error logs from 2026-04-08 through 2026-04-11 show two failure patterns:

1. **`function name or parameters is empty (2013)`** — Claude Code sends tool definitions where `name` is empty string or `input_schema` is absent. MiniMax rejects these. Affects both `claude-haiku-4-5-20251001` and `claude-sonnet-4-6` mapped requests.

2. **`unsupported content type 'advisor_tool_result' (2013)`** — Already fixed by `vendorSafeBlockTypes` in `TranscriptProjector.makeVendorReadyBlocks`. Tests exist in `TranscriptProjectorTests.swift:263-351`. Only appeared on 4/10, likely before the fix was deployed.

This plan addresses only issue #1. Issue #2 is already resolved.

---

<!-- section: task-1 keywords: ProxyForwarder, sanitizeTools, stripServerSideTools -->
### Task 1: Replace `stripServerSideTools` with `sanitizeToolsForVendor`

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:1071-1093`

**Steps:**

1. Rename `stripServerSideTools(from:)` to `sanitizeToolsForVendor(in:)`. Keep the method `static` on `ProxyForwarder`.

2. Expand the filter logic to reject tools that:
   - Have a `type` in `serverSideToolTypes` (existing behavior)
   - Have an empty or missing `name` field
   - Have a `type` that is not in a vendor-safe set (only `custom` and absent/nil type are standard Anthropic tool types; anything else like `computer_20241022`, `text_editor_20241022`, `bash_20241022` are Anthropic computer-use tools that MiniMax won't understand)

3. Actually — simpler and more robust approach: keep only tools that have a non-empty `name` AND a non-nil `input_schema`. This is the Anthropic Messages API contract for custom tools. Server-side tools (`web_search_*`, `computer_*`, `text_editor_*`, `bash_*`) use `type` instead of `name`+`input_schema`, so they naturally get filtered out. This replaces both the existing `serverSideToolTypes` check and handles future Anthropic-internal tool types.

4. Add a diagnostic log line when tools are removed, listing the removed tool types/names for debugging.

5. Update the call site at line 326 to use the new name.

**Implementation:**

Replace `ProxyForwarder.swift:1071-1093` with:

```swift
/// Remove tool definitions that mapped vendors cannot handle.
/// Keeps only tools with a non-empty `name` and a present `input_schema` —
/// the Anthropic Messages API contract for custom (user-defined) tools.
/// Server-side tools (web_search, computer_use, etc.) use `type` instead
/// of `name` + `input_schema`, so they are naturally excluded.
static func sanitizeToolsForVendor(in bodyData: Data) -> Data {
    guard var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
          let tools = json["tools"] as? [[String: Any]] else {
        return bodyData
    }
    let filtered = tools.filter { tool in
        guard let name = tool["name"] as? String, !name.isEmpty else { return false }
        guard tool["input_schema"] != nil else { return false }
        return true
    }
    let removedCount = tools.count - filtered.count
    guard removedCount > 0 else { return bodyData }
    let removedNames = tools.filter { tool in
        let name = tool["name"] as? String ?? ""
        let hasSchema = tool["input_schema"] != nil
        return name.isEmpty || !hasSchema
    }.map { ($0["type"] as? String) ?? ($0["name"] as? String) ?? "unknown" }
    AppLog.proxy.info("[Proxy] sanitizeToolsForVendor: removed \(removedCount) tools: \(removedNames.joined(separator: ", "))")
    if filtered.isEmpty {
        json.removeValue(forKey: "tools")
        json.removeValue(forKey: "tool_choice")
    } else {
        json["tools"] = filtered
    }
    return (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? bodyData
}
```

Update call site at line 325-327:

```swift
// 3b. Strip tools that the vendor cannot handle when no bridge is configured.
var forwardBodyData = preparedRequest.bodyData
if webSearchProvider == nil, !webSearchForwardAsIs, !target.isPassthrough {
    forwardBodyData = Self.sanitizeToolsForVendor(in: forwardBodyData)
}
```

**Verify:**
- `grep -n "sanitizeToolsForVendor" ModelProxy/Proxy/ProxyForwarder.swift` shows both definition and call site
- `grep -n "stripServerSideTools" ModelProxy/Proxy/ProxyForwarder.swift` returns no results (fully replaced)
<!-- /section -->

<!-- section: task-2 keywords: WebSearchBridgeTests, sanitizeTools, test -->
### Task 2: Update and expand tests

**Files:**
- Modify: `ModelProxyTests/WebSearchBridgeTests.swift:353-360`
- Modify: `ModelProxyTests/ProxyForwarderTests.swift` (add new test cases)

**Steps:**

1. In `WebSearchBridgeTests.swift`, rename the existing test and update to call `sanitizeToolsForVendor`:

```swift
@Test func sanitizeToolsForVendorRemovesWebSearchAndKeepsOthers() throws {
    let body = try requestBody(stream: false)
    let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
    let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "bash")
}
```

2. In `ProxyForwarderTests.swift`, first add `import Foundation` at the top (needed for `JSONSerialization` and `Data`), then add test cases for the new sanitization:

```swift
@Test func sanitizeToolsRemovesToolsWithEmptyName() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "test",
        "messages": [["role": "user", "content": "hi"]],
        "tools": [
            ["name": "", "input_schema": ["type": "object"]],
            ["name": "bash", "input_schema": ["type": "object", "properties": [:]]],
        ]
    ])
    let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
    let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "bash")
}

@Test func sanitizeToolsRemovesToolsWithMissingInputSchema() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "test",
        "messages": [["role": "user", "content": "hi"]],
        "tools": [
            ["name": "advisor", "type": "custom"],
            ["name": "bash", "input_schema": ["type": "object"]],
        ]
    ])
    let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
    let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "bash")
}

@Test func sanitizeToolsRemovesServerSideToolsByType() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "test",
        "messages": [["role": "user", "content": "hi"]],
        "tools": [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
            ["type": "computer_20241022", "name": "computer", "display_width_px": 1024],
            ["name": "Read", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]],
        ]
    ])
    let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
    let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    #expect(tools[0]["name"] as? String == "Read")
}

@Test func sanitizeToolsRemovesToolChoiceWhenAllToolsFiltered() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "test",
        "messages": [["role": "user", "content": "hi"]],
        "tools": [
            ["type": "web_search_20250305", "name": "web_search", "max_uses": 4],
        ],
        "tool_choice": ["type": "auto"]
    ])
    let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
    let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    #expect(json["tools"] == nil)
    #expect(json["tool_choice"] == nil)
}

@Test func sanitizeToolsPassesThroughValidToolsUnchanged() throws {
    let body = try JSONSerialization.data(withJSONObject: [
        "model": "test",
        "messages": [["role": "user", "content": "hi"]],
        "tools": [
            ["name": "bash", "input_schema": ["type": "object"]],
            ["name": "Read", "input_schema": ["type": "object", "properties": ["path": ["type": "string"]]]],
        ]
    ])
    let sanitized = ProxyForwarder.sanitizeToolsForVendor(in: body)
    let json = try #require(try JSONSerialization.jsonObject(with: sanitized) as? [String: Any])
    let tools = try #require(json["tools"] as? [[String: Any]])
    #expect(tools.count == 2)
}
```

3. Note: `computer_20241022` tool has both `type` AND `name` set, but has no `input_schema` — so the filter catches it. The `web_search_20250305` tool also has no `input_schema`. Both naturally excluded by the `name` + `input_schema` requirement.

**Verify:**
- `grep -c "sanitizeTools" ModelProxyTests/WebSearchBridgeTests.swift` returns 2 (test name + call)
- `grep -c "sanitizeTools" ModelProxyTests/ProxyForwarderTests.swift` returns at least 10
<!-- /section -->

<!-- section: task-3 keywords: xcodebuild, test, verification -->
### Task 3: Full verification

**Verify:**
Run: `cd /Users/norvyn/Code/Projects/ModelProxy && xcodebuild test -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' -quiet 2>&1 | tail -20`
Expected: All tests pass with zero failures
<!-- /section -->

## Decisions

None.

---
## Verification
- **Verdict:** Approved
- **Date:** 2026-04-11
- **Notes:** Revised per plan-verifier S2 (added `import Foundation` to test file) and S1 (added diagnostic logging to implementation)
