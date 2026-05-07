---
category: architecture
keywords: [WebSearchBridge, ReplayableBranchResponse, TrafficEntry, web_search_20260209, Swift6, Sendable]
date: 2026-05-07
source_project: ModelProxy
---
# Preserve proxy metadata across replay

## Context

ModelProxy's App-internal WebSearchBridge converts Anthropic WebSearch tool calls into vendor-compatible function tool calls, then synthesizes Anthropic-shaped responses for the client.

The client-visible behavior depends on more than the immediate bridge response. Branch replay and Menu Bar traffic display also consume the response metadata.

## Lesson

When synthesizing proxy-native behavior, store user-visible request metadata on the replayable response object, not only in the direct request path.

For WebSearchBridge this means:

- Count successful provider search invocations, not result items.
- Return `usage.server_tool_use.web_search_requests` to match Anthropic WebSearch shape.
- Support both `web_search_20250305` and current `web_search_20260209`.
- Preserve `.webSearchBridge(searchCount:)` through `ReplayableBranchResponse`, so cached replay rows still show as Web Search.
- Move private SwiftUI row display logic into testable `TrafficEntry` helpers when exact Menu Bar text matters.
- Avoid mutating captured vars inside `@Sendable` async helpers under Swift 6; use a sequential loop or return observations from the closure.

## Prevention

For future proxy-native capabilities:

1. Trace all consumers: direct response, replay cache, traffic log, token stats, and UI rows.
2. Add metadata to the replayable response when cached requests must preserve display semantics.
3. Test exact display/accessibility strings outside private SwiftUI views.
4. Verify current upstream tool versions from official docs before hardcoding tool type strings.

Reference: Anthropic WebSearch docs, `usage.server_tool_use.web_search_requests`.
