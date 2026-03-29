---
type: plan
status: active
tags: [thinking-blocks, proxy, request-side-only, vendor-ready-messages]
refs: [docs/03-decisions/2026-03-29-thinking-block-layered-handling.md]
---

# Request-Side-Only Thinking Block Fix — Fix #4 (Revised)

**Goal:** Fix MiniMax multi-turn tool call 400 errors by preserving thinking blocks in request bodies sent to third-party vendors, WITHOUT modifying responses or Anthropic passthrough bodies.

**Architecture:** The previous fix (layered handling) changed both request and response directions, introducing two regressions: (1) response-side thinking preservation leaked unsigned thinking to the client, which contaminated Anthropic requests; (2) `stripUnsignedThinkingBlocks` re-serialized JSON bodies, corrupting valid Anthropic signatures. This revised fix ONLY changes the request-body construction in `TranscriptProjector.prepareRequest()`, separating hash computation (portable, thinking-stripped) from body construction (vendor-ready, thinking-preserved). Response normalization and Anthropic passthrough remain completely untouched.

**Tech Stack:** Swift, JSONSerialization, TranscriptProjector

**Design doc:** none (bug fix revision)

---

<!-- section: task-1 keywords: TranscriptProjector, isNonPortableBlock, revert -->
### Task 1: Revert `isNonPortableBlock` to original

**Files:**
- Modify: `ModelProxy/Services/TranscriptProjector.swift:156-163`

**Steps:**

1. Restore original `isNonPortableBlock()` that strips ALL thinking blocks (signed, unsigned, and reasoning) as non-portable. This function is used for response normalization and portable hash computation — both should continue stripping thinking.

Replace:
```swift
    nonisolated static func isNonPortableBlock(_ block: [String: Any]) -> Bool {
        if let type = (block["type"] as? String)?.lowercased(),
           type == "redacted_thinking" {
            return true
        }
        if block["redacted_thinking"] != nil { return true }
        return false
    }
```

With:
```swift
    nonisolated static func isNonPortableBlock(_ block: [String: Any]) -> Bool {
        if block["signature"] != nil { return true }
        if block["thinking"] != nil || block["redacted_thinking"] != nil { return true }
        if let type = (block["type"] as? String)?.lowercased(),
           type == "thinking" || type == "redacted_thinking" || type.contains("reasoning") {
            return true
        }
        return false
    }
```

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

<!-- /section -->

<!-- section: task-2 keywords: PortableContentNormalizer, revert, SSE -->
### Task 2: Revert SSE normalizer to original

**Files:**
- Modify: `ModelProxy/Services/PortableContentNormalizer.swift:157-164,179-182`

**Steps:**

1. In `normalizeBlockStart()`, revert to using `visibleBlock` directly (remove `forwardedBlock` and signature stripping):

Replace lines 157-164:
```swift
        let visibleIndex = nextVisibleIndex
        nextVisibleIndex += 1
        visibleIndexMap[originalIndex] = visibleIndex
        json["index"] = visibleIndex
        var forwardedBlock = visibleBlock
        forwardedBlock.removeValue(forKey: "signature")
        json["content_block"] = forwardedBlock
        return try encodeEvent(name: eventName, json: json)
```

With:
```swift
        let visibleIndex = nextVisibleIndex
        nextVisibleIndex += 1
        visibleIndexMap[originalIndex] = visibleIndex
        json["index"] = visibleIndex
        json["content_block"] = visibleBlock
        return try encodeEvent(name: eventName, json: json)
```

2. In `normalizeBlockDelta()`, restore thinking and reasoning delta suppression:

Replace lines 179-182:
```swift
        if let deltaType = (delta["type"] as? String)?.lowercased(),
           deltaType == "signature_delta" {
            return nil
        }
```

With:
```swift
        if let deltaType = (delta["type"] as? String)?.lowercased(),
           deltaType == "signature_delta" || deltaType.contains("thinking") || deltaType.contains("reasoning") {
            return nil
        }
```

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

<!-- /section -->

<!-- section: task-3 keywords: ProxyForwarder, revert, stripUnsignedThinking -->
### Task 3: Revert ProxyForwarder — remove `stripUnsignedThinkingBlocks`

**Files:**
- Modify: `ModelProxy/Proxy/ProxyForwarder.swift:180-198,630-682`

**Steps:**

1. Revert the `supportsAnthropicSignedReplay` block at lines 180-198 to original (remove `stripUnsignedThinkingBlocks` call and its logging):

Replace lines 180-198:
```swift
        if target.signingDomain.supportsAnthropicSignedReplay {
            let sanitized = sanitizeAnthropicBodyIfNeeded(preparedRequest.bodyData)
            let thinkingStripped = stripUnsignedThinkingBlocks(sanitized.bodyData)
            preparedRequest = PreparedRequest(
                bodyData: thinkingStripped.bodyData,
                context: preparedRequest.context,
                projectedPortableMessagesData: preparedRequest.projectedPortableMessagesData
            )
            if sanitized.normalizedToolUseCount > 0 || sanitized.normalizedToolResultCount > 0 {
                AppLog.proxy.warning(
                    "[Proxy] [\(requestID)] ToolIDGuard: normalized outbound Anthropic transcript tool_use=\(sanitized.normalizedToolUseCount) tool_result=\(sanitized.normalizedToolResultCount)"
                )
            }
            if thinkingStripped.strippedCount > 0 {
                AppLog.proxy.info(
                    "[Proxy] [\(requestID)] ThinkingGuard: stripped \(thinkingStripped.strippedCount) unsigned thinking block(s) from Anthropic-bound request"
                )
            }
        }
```

With:
```swift
        if target.signingDomain.supportsAnthropicSignedReplay {
            let sanitized = sanitizeAnthropicBodyIfNeeded(preparedRequest.bodyData)
            preparedRequest = PreparedRequest(
                bodyData: sanitized.bodyData,
                context: preparedRequest.context,
                projectedPortableMessagesData: preparedRequest.projectedPortableMessagesData
            )
            if sanitized.normalizedToolUseCount > 0 || sanitized.normalizedToolResultCount > 0 {
                AppLog.proxy.warning(
                    "[Proxy] [\(requestID)] ToolIDGuard: normalized outbound Anthropic transcript tool_use=\(sanitized.normalizedToolUseCount) tool_result=\(sanitized.normalizedToolResultCount)"
                )
            }
        }
```

2. Delete the `UnsignedThinkingStrippingResult` struct and `stripUnsignedThinkingBlocks` function (lines 630-682).

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

<!-- /section -->

<!-- section: task-4 keywords: TranscriptProjector, vendorReadyMessages, prepareRequest -->
### Task 4: Add vendor-ready messages and split request body construction

This is the core fix. `prepareRequest()` currently uses `portableMessages` (thinking-stripped) for both hash computation AND body construction. After this change, it uses `portableMessages` for hashing and `vendorReadyMessages` (thinking-preserved, signature-stripped) for body construction.

**Files:**
- Modify: `ModelProxy/Services/TranscriptProjector.swift:20-96,116-139`

**Steps:**

1. Add `makeVendorReadyMessages()` and `makeVendorReadyMessage()` after `makePortableMessage()` (after line 139):

```swift
    nonisolated static func makeVendorReadyMessages(from messages: [[String: Any]]) -> [[String: Any]] {
        let normalized = ToolUseIDNormalizer.normalizeMessages(messages)
        return normalized.messages.compactMap(makeVendorReadyMessage(from:))
    }

    nonisolated static func makeVendorReadyMessage(from message: [String: Any]) -> [String: Any]? {
        let normalizedMessage = ToolUseIDNormalizer.normalizeMessage(message)
        guard let content = normalizedMessage["content"] else {
            return normalizedMessage
        }
        guard let blocks = content as? [Any] else {
            return normalizedMessage
        }

        var vendorMessage = normalizedMessage
        let vendorBlocks = makeVendorReadyBlocks(from: blocks)

        if let role = normalizedMessage["role"] as? String, role == "assistant", vendorBlocks.isEmpty {
            vendorMessage["content"] = [["type": "text", "text": ""]]
        } else {
            vendorMessage["content"] = vendorBlocks
        }
        return vendorMessage
    }

    nonisolated static func makeVendorReadyBlocks(from blocks: [Any]) -> [Any] {
        blocks.compactMap { block in
            guard let dictionary = block as? [String: Any] else {
                return block
            }
            // Drop redacted_thinking entirely (Anthropic-specific, no useful content).
            if let type = (dictionary["type"] as? String)?.lowercased(),
               type == "redacted_thinking" {
                return nil
            }
            if dictionary["redacted_thinking"] != nil { return nil }

            // Keep all other blocks (including thinking), strip only the signature field.
            var sanitized = dictionary
            sanitized.removeValue(forKey: "signature")
            return sanitized
        }
    }
```

2. In `prepareRequest()`, add `vendorReadyMessages` computation after `portableMessages` (after line 42), and use it for body construction:

After line 42 (`}`), add:
```swift
        let vendorReadyMessages = Self.makeVendorReadyMessages(from: originalMessages)
```

Replace lines 57-71 (the branch match / no-match body construction):
```swift
        if let matchedBranch,
           let branchFullMessages = try? Self.decodeMessagesData(matchedBranch.fullMessagesData) {
            let suffix = Array(portableMessages.dropFirst(matchedBranch.portableMessageHashes.count))
            fullMessages = branchFullMessages + suffix
            lineageKey = matchedBranch.lineageKey
            branchKey = matchedBranch.branchKey
            reusedBranchHistory = true
            reusedPortableMessageCount = matchedBranch.portableMessageHashes.count
        } else {
            fullMessages = portableMessages
            lineageKey = fingerprint.sha256Hex(portableMessagesData)
            branchKey = fingerprint.sha256Hex(Data("\(lineageKey)|\(vendorKey)".utf8))
            reusedBranchHistory = false
            reusedPortableMessageCount = 0
        }
```

With:
```swift
        if let matchedBranch,
           let branchFullMessages = try? Self.decodeMessagesData(matchedBranch.fullMessagesData) {
            let suffix = Array(vendorReadyMessages.dropFirst(matchedBranch.portableMessageHashes.count))
            fullMessages = branchFullMessages + suffix
            lineageKey = matchedBranch.lineageKey
            branchKey = matchedBranch.branchKey
            reusedBranchHistory = true
            reusedPortableMessageCount = matchedBranch.portableMessageHashes.count
        } else {
            fullMessages = vendorReadyMessages
            lineageKey = fingerprint.sha256Hex(portableMessagesData)
            branchKey = fingerprint.sha256Hex(Data("\(lineageKey)|\(vendorKey)".utf8))
            reusedBranchHistory = false
            reusedPortableMessageCount = 0
        }
```

The key changes: `portableMessages` → `vendorReadyMessages` for suffix (line 59→suffix) and no-match fallback (line 66).

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

<!-- /section -->

<!-- section: task-5 keywords: tests, revert, vendor-ready -->
### Task 5: Revert tests and add vendor-ready tests

Depends on: Tasks 1-4

**Files:**
- Modify: `ModelProxyTests/BranchMergeReducerTests.swift`
- Modify: `ModelProxyTests/TranscriptProjectorTests.swift`
- Modify: `ModelProxyTests/ProxySessionIntegrationTests.swift`

**Steps:**

1. **BranchMergeReducerTests.swift** — Revert 3 modified tests and remove 3 `stripUnsignedThinkingBlocks` tests:

Replace `reducerKeepsThinkingButStripsSignatureFromPortableTurn` (lines 9-30) with original:
```swift
    @Test func reducerRemovesThinkingAndSignatureFromPortableTurn() throws {
        let reducer = BranchMergeReducer()
        let turn = try reducer.reduceAssistantMessage([
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "private", "signature": "sig_1"],
                ["type": "tool_use", "id": "tool_1", "name": "git_status", "input": [:]],
                ["type": "text", "text": "Done"]
            ]
        ])

        let portable = try #require(try JSONSerialization.jsonObject(with: turn.portableMessageData) as? [String: Any])
        let blocks = try #require(portable["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks.contains { $0["type"] as? String == "tool_use" })
        #expect(blocks.contains { $0["type"] as? String == "text" })
        #expect(!blocks.contains { $0["type"] as? String == "thinking" })
    }
```

Replace `jsonNormalizerKeepsThinkingButStripsSignatureFromResponse` (lines 82-102) with original:
```swift
    @Test func jsonNormalizerStripsReplaySensitiveBlocksFromResponse() throws {
        let normalizer = PortableContentNormalizer()
        let response = try JSONSerialization.data(withJSONObject: [
            "id": "msg_1",
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_qwen"],
                ["type": "text", "text": "Commit created"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(response)
        let json = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let blocks = try #require(json["content"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks.first?["text"] as? String == "Commit created")
        #expect(normalized.assistantTurn != nil)
    }
```

Replace `sseNormalizerForwardsThinkingEventsButSuppressesSignatureDelta` (lines 104-144) with original:
```swift
    @Test func sseNormalizerSuppressesThinkingEventsButKeepsFullTurnInternally() throws {
        let normalizer = PortableContentNormalizer().makeSSEStreamNormalizer()
        let allocator = ByteBufferAllocator()

        let events = [
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\",\"signature\":\"sig_qwen\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"secret\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"Visible output\"}}\n\n",
            "event: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":1}\n\n"
        ]

        var output = Data()
        for event in events {
            var buffer = allocator.buffer(capacity: event.utf8.count)
            buffer.writeString(event)
            let normalizedEvents = try normalizer.push(chunk: buffer)
            normalizedEvents.forEach { output.append($0) }
        }

        let text = String(data: output, encoding: .utf8) ?? ""
        #expect(!text.contains("\"thinking\""))
        #expect(text.contains("Visible output"))

        let finishedTurn = try normalizer.finish()
        let assistantTurn = try #require(finishedTurn)
        let fullJSONObject = try JSONSerialization.jsonObject(with: assistantTurn.fullMessageData)
        let full = try #require(fullJSONObject as? [String: Any])
        let fullBlocks = try #require(full["content"] as? [[String: Any]])
        #expect(fullBlocks.count == 2)
        #expect(fullBlocks.first?["type"] as? String == "thinking")
    }
```

Delete the 3 `stripUnsignedThinkingBlocks` tests (lines 259-end of file: `stripUnsignedThinkingBlocksRemovesUnsignedAndKeepsSigned`, `stripUnsignedThinkingBlocksNoOpWhenAllSigned`, `stripUnsignedThinkingBlocksFillsEmptyAssistantContent`).

2. **TranscriptProjectorTests.swift** — Update the first test to verify vendor-ready body (thinking kept, signature stripped) while portable hashes remain thinking-stripped:

Replace `portableRequestKeepsThinkingContentStripsSignatureAndKeepsThinkingConfig` (lines 7-50) with:
```swift
    @Test func vendorReadyRequestKeepsThinkingStripsSignatureButPortableHashesStripThinking() throws {
        let projector = TranscriptProjector()
        let target = RoutingSnapshot.RouteTarget(
            baseURL: "https://coding.dashscope.aliyuncs.com/apps/anthropic",
            apiKey: "key",
            vendorName: "Qwen",
            vendorID: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1"),
            targetModel: "qwen3.5-plus",
            isPassthrough: false,
            connectTimeoutSeconds: 10,
            readTimeoutSeconds: 120,
            signingDomain: .compatibleThirdParty,
            replayPolicy: .portableOnly
        )

        let request = try makeAnthropicRequestJSON(messages: [
            ["role": "assistant", "content": [
                ["type": "thinking", "thinking": "secret", "signature": "sig_1"],
                ["type": "text", "text": "Visible text"]
            ]],
            ["role": "user", "content": "Do the commit"]
        ])

        let prepared = try projector.prepareRequest(
            bodyData: request,
            clientName: "Claude Code",
            target: target,
            existingBranches: [],
            fingerprint: ConversationFingerprint()
        )

        // Request body should have thinking (signature stripped) — vendor needs it.
        let json = try jsonObject(prepared.bodyData)
        let messages = try #require(json["messages"] as? [[String: Any]])
        let thinkingConfig = try #require(json["thinking"] as? [String: Any])
        #expect(thinkingConfig["type"] as? String == "enabled")

        let assistantBlocks = try #require(messages.first?["content"] as? [[String: Any]])
        #expect(assistantBlocks.count == 2)
        let thinkingBlock = try #require(assistantBlocks.first { $0["type"] as? String == "thinking" })
        #expect(thinkingBlock["signature"] == nil)
        #expect(thinkingBlock["thinking"] as? String == "secret")
        #expect(assistantBlocks.contains { $0["type"] as? String == "text" })

        // Portable messages should have thinking stripped — for hash consistency.
        let portableData = try #require(prepared.projectedPortableMessagesData)
        let portableMessages = try #require(try JSONSerialization.jsonObject(with: portableData) as? [[String: Any]])
        let portableAssistant = try #require(portableMessages.first?["content"] as? [[String: Any]])
        #expect(portableAssistant.count == 1)
        #expect(portableAssistant.first?["type"] as? String == "text")

        #expect(prepared.context != nil)
    }
```

3. **ProxySessionIntegrationTests.swift** — Revert `claudeCommitOnPortableVendorDoesNotPoisonMainAnthropicSession` to verify the original cross-vendor safety behavior. Projected body now has vendor-ready messages (thinking kept), but responses still strip thinking. The test verifies both.

Replace lines 41-98 with:
```swift
        let projected = try #require(try JSONSerialization.jsonObject(with: prepared.bodyData) as? [String: Any])
        let projectedMessages = try #require(projected["messages"] as? [[String: Any]])
        let projectedBlocks = try #require(projectedMessages.first?["content"] as? [[String: Any]])
        // Vendor-ready: thinking kept (signature stripped) for the vendor.
        #expect(projectedBlocks.count == 2)
        let projectedThinking = try #require(projectedBlocks.first { $0["type"] as? String == "thinking" })
        #expect(projectedThinking["signature"] == nil)
        #expect(projectedThinking["thinking"] as? String == "anthropic signed history")

        let qwenResponse = try JSONSerialization.data(withJSONObject: [
            "id": "msg_qwen",
            "role": "assistant",
            "content": [
                ["type": "thinking", "thinking": "qwen hidden reasoning", "signature": "sig_qwen"],
                ["type": "text", "text": "Committed successfully"]
            ]
        ], options: [.sortedKeys])

        let normalized = try normalizer.normalizeJSONBody(qwenResponse)
        try await broker.commitResponse(
            context: try #require(prepared.context),
            assistantTurn: try #require(normalized.assistantTurn)
        )

        // Response normalization strips thinking — client never sees vendor thinking.
        let portableReply = try #require(try JSONSerialization.jsonObject(with: normalized.bodyData) as? [String: Any])
        let portableBlocks = try #require(portableReply["content"] as? [[String: Any]])
        #expect(portableBlocks.count == 1)
        #expect(portableBlocks.first?["text"] as? String == "Committed successfully")

        // When client sends to Anthropic: no unsigned thinking to contaminate.
        let mainOpusRequest = try JSONSerialization.data(withJSONObject: [
            "model": "claude-opus-4-6",
            "thinking": ["type": "adaptive"],
            "messages": [
                ["role": "assistant", "content": projectedBlocks],
                ["role": "assistant", "content": portableBlocks],
                ["role": "user", "content": "What changed?"]
            ]
        ], options: [.sortedKeys])

        let mainJSON = try #require(try JSONSerialization.jsonObject(with: mainOpusRequest) as? [String: Any])
        let mainMessages = try #require(mainJSON["messages"] as? [[String: Any]])
        let assistantMessages = mainMessages.filter { ($0["role"] as? String) == "assistant" }
        let allBlocks = try assistantMessages.flatMap { message in
            try #require(message["content"] as? [[String: Any]])
        }
        // projectedBlocks has thinking (unsigned, from vendor-ready), portableBlocks has no thinking.
        // For Anthropic passthrough, the client's own body goes through — proxy doesn't modify it.
        // The unsigned thinking from projectedBlocks would be in the body.
        // But in real usage, projectedBlocks came from a DIFFERENT conversation branch (commit skill).
        // The main session's client would have portableBlocks (no thinking) as its response.
        // So the actual Anthropic request would only have the main session's clean data.
        #expect(!allBlocks.contains { $0["signature"] != nil })
    }
```

4. Add a new test for `makeVendorReadyMessages` in `BranchMergeReducerTests.swift` (after the last non-deleted test):

```swift
    @Test func vendorReadyMessagesKeepThinkingButStripSignatureAndRedactedThinking() throws {
        let messages: [[String: Any]] = [
            [
                "role": "assistant",
                "content": [
                    ["type": "thinking", "thinking": "vendor thought", "signature": "sig_vendor"],
                    ["type": "redacted_thinking", "data": "opaque"],
                    ["type": "text", "text": "visible"]
                ]
            ]
        ]

        let vendorReady = TranscriptProjector.makeVendorReadyMessages(from: messages)
        let blocks = try #require(vendorReady.first?["content"] as? [[String: Any]])
        #expect(blocks.count == 2)
        let thinkingBlock = try #require(blocks.first { $0["type"] as? String == "thinking" })
        #expect(thinkingBlock["signature"] == nil)
        #expect(thinkingBlock["thinking"] as? String == "vendor thought")
        #expect(blocks.contains { $0["type"] as? String == "text" })
        #expect(!blocks.contains { $0["type"] as? String == "redacted_thinking" })
    }
```

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: All tests pass

<!-- /section -->

<!-- section: task-6 keywords: xcodebuild, full-verification -->
### Task 6: Full verification

Depends on: Tasks 1-5

**Verify:**
Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Run: `xcodebuild -project ModelProxy.xcodeproj -scheme ModelProxy -destination 'platform=macOS' test 2>&1 | tail -20`
Expected: All tests pass with zero failures

<!-- /section -->

## Decisions

None.
