import Foundation
import NIOCore
import NIOFoundationCompat
import NIOHTTP1
import AsyncHTTPClient
import OSLog

enum ResponseRelay {
    static let maxReplayBodyBytes = 1 * 1024 * 1024

    /// Token usage callback: (inputTokens, outputTokens).
    typealias UsageCallback = @Sendable (Int, Int) -> Void

    /// Relay an AsyncHTTPClient response (headers + body) back to a NIO client channel.
    /// Writes each body chunk immediately as it arrives — no buffering for SSE.
    /// - Parameter onUsage: optional closure invoked once with extracted token counts.
    ///   Called at most once per relay call; never called if usage cannot be parsed.
    static func relay(
        upstreamResponse: HTTPClientResponse,
        to channel: any Channel,
        onUsage: UsageCallback? = nil,
        requestID: String,
        branchContext: PreparedBranchContext? = nil,
        branchLease: BranchRequestLease? = nil,
        portableNormalizer: (any PortableContentNormalizing)? = nil,
        toolCallGuard: ToolCallInputGuard? = nil,
        lineageBroker: (any SessionLineageBrokering)? = nil,
        requestCoordinator: (any BranchRequestCoordinating)? = nil
    ) async -> ReplayableBranchResponse? {
        // 1. Forward status + response headers.
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: Int(upstreamResponse.status.code))
        )
        for (name, value) in upstreamResponse.headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" || lower == "connection" || lower == "content-length" || lower == "content-encoding" { continue }
            responseHead.headers.add(name: name, value: value)
        }
        responseHead.headers.add(name: "connection", value: "close")

        // Determine response type from Content-Type header.
        let contentType = upstreamResponse.headers.first(name: "content-type") ?? ""
        let isSSE = contentType.lowercased().contains("text/event-stream")
        let statusCode = Int(upstreamResponse.status.code)
        let isError = statusCode >= 400
        let shouldNormalize = branchContext != nil && portableNormalizer != nil && !isError
        let shouldGuardToolCalls = toolCallGuard != nil && !isError
        let shouldTransformBody = shouldNormalize || shouldGuardToolCalls
        let shouldCaptureReplay = branchLease != nil
        let replayHeaders = responseHead.headers.map { ($0.name, $0.value) }
        var replayRecorder = BranchReplayRecorder(statusCode: statusCode, headers: replayHeaders)
        var replayOverflowLogged = false

        do {
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.head(responseHead))
            ).get()

            if isSSE {
                // 2a. SSE: forward each chunk immediately; accumulate usage across events.
                // Anthropic splits input_tokens (message_start) and output_tokens (message_delta).
                var accumulatedInput = 0
                var accumulatedOutput = 0
                var errorAccumulator = Data()
                let streamNormalizer = shouldTransformBody
                    ? (portableNormalizer ?? PortableContentNormalizer()).makeSSEStreamNormalizer(
                        portableMode: shouldNormalize,
                        toolCallGuard: shouldGuardToolCalls ? toolCallGuard : nil
                    )
                    : nil
                for try await chunk in upstreamResponse.body {
                    if let streamNormalizer {
                        let normalizedEvents = try streamNormalizer.push(chunk: chunk)
                        for eventData in normalizedEvents {
                            Self.recordReplayChunk(
                                eventData,
                                shouldCaptureReplay: shouldCaptureReplay,
                                requestID: requestID,
                                statusCode: statusCode,
                                replayRecorder: &replayRecorder,
                                replayOverflowLogged: &replayOverflowLogged
                            )
                            var out = channel.allocator.buffer(capacity: eventData.count)
                            out.writeBytes(eventData)
                            try await channel.writeAndFlush(
                                NIOAny(HTTPServerResponsePart.body(.byteBuffer(out)))
                            ).get()
                        }
                    } else {
                        if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                            Self.recordReplayChunk(
                                bytes,
                                shouldCaptureReplay: shouldCaptureReplay,
                                requestID: requestID,
                                statusCode: statusCode,
                                replayRecorder: &replayRecorder,
                                replayOverflowLogged: &replayOverflowLogged
                            )
                        }
                        try await channel.writeAndFlush(
                            NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
                        ).get()
                    }

                    // Scan chunk for usage data, accumulate across events.
                    if onUsage != nil {
                        let (input, output) = extractUsageFromSSEChunk(chunk)
                        accumulatedInput += input
                        accumulatedOutput += output
                    }
                    if isError, let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                        errorAccumulator.append(bytes)
                    }
                }
                // Report accumulated totals at stream end.
                if let callback = onUsage, (accumulatedInput > 0 || accumulatedOutput > 0) {
                    callback(accumulatedInput, accumulatedOutput)
                }
                if isError, !errorAccumulator.isEmpty {
                    let preview = String(data: errorAccumulator.prefix(2048), encoding: .utf8) ?? "<non-UTF8, \(errorAccumulator.count)B>"
                    AppLog.proxy.warning("[Proxy] [\(requestID)] Upstream \(statusCode) body (\(errorAccumulator.count)B): \(preview)")
                    logUpstreamErrorBranchContext(branchContext, requestID: requestID)
                }
                if let streamNormalizer {
                    let guardSummary = streamNormalizer.toolCallGuardSummary()
                    if guardSummary.changed {
                        let reasons = guardSummary.reasons.joined(separator: ",")
                        AppLog.proxy.info(
                            "[Proxy] [\(requestID)] ToolCallGuard: repaired=\(guardSummary.repairedCount) dropped=\(guardSummary.droppedCount) parseFailed=false reasons=\(reasons)"
                        )
                    }
                }
                if let streamNormalizer,
                   let branchContext,
                   let lineageBroker,
                   let assistantTurn = try streamNormalizer.finish() {
                    await Self.commitAssistantTurnIfCurrent(
                        assistantTurn,
                        branchContext: branchContext,
                        branchLease: branchLease,
                        lineageBroker: lineageBroker,
                        requestCoordinator: requestCoordinator,
                        requestID: requestID
                    )
                }
            } else {
                // 2b. Non-streaming: forward chunks immediately; accumulate a parallel copy
                // for token usage extraction. This doubles peak memory for the response body,
                // but most API responses are small enough that this is acceptable.
                var bodyAccumulator = Data()
                let shouldAccumulate = onUsage != nil || isError || shouldTransformBody

                for try await chunk in upstreamResponse.body {
                    if shouldAccumulate {
                        if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                            bodyAccumulator.append(bytes)
                            if !shouldTransformBody {
                                Self.recordReplayChunk(
                                    bytes,
                                    shouldCaptureReplay: shouldCaptureReplay,
                                    requestID: requestID,
                                    statusCode: statusCode,
                                    replayRecorder: &replayRecorder,
                                    replayOverflowLogged: &replayOverflowLogged
                                )
                            }
                        }
                    }
                    if !shouldTransformBody {
                        try await channel.writeAndFlush(
                            NIOAny(HTTPServerResponsePart.body(.byteBuffer(chunk)))
                        ).get()
                    }
                }

                // Parse usage from full body after all chunks forwarded.
                if let callback = onUsage, !bodyAccumulator.isEmpty {
                    if let (input, output) = extractUsageFromJSONBody(bodyAccumulator) {
                        callback(input, output)
                    }
                }
                if isError, !bodyAccumulator.isEmpty {
                    let preview = String(data: bodyAccumulator.prefix(2048), encoding: .utf8) ?? "<non-UTF8, \(bodyAccumulator.count)B>"
                    AppLog.proxy.warning("[Proxy] [\(requestID)] Upstream \(statusCode) body (\(bodyAccumulator.count)B): \(preview)")
                    logUpstreamErrorBranchContext(branchContext, requestID: requestID)
                }
                var transformedBody = bodyAccumulator
                if shouldGuardToolCalls, let toolCallGuard, !transformedBody.isEmpty {
                    let guarded = toolCallGuard.transformJSONResponseBody(transformedBody)
                    transformedBody = guarded.data
                    if guarded.changed || guarded.parseFailed {
                        let reasons = guarded.reasons.joined(separator: ",")
                        AppLog.proxy.info(
                            "[Proxy] [\(requestID)] ToolCallGuard: repaired=\(guarded.repairedCount) dropped=\(guarded.droppedCount) parseFailed=\(guarded.parseFailed) reasons=\(reasons)"
                        )
                    }
                }

                if shouldNormalize,
                   let portableNormalizer,
                   let branchContext,
                   let lineageBroker {
                    let normalized = try portableNormalizer.normalizeJSONBody(transformedBody)
                    Self.replaceReplayBody(
                        normalized.bodyData,
                        shouldCaptureReplay: shouldCaptureReplay,
                        requestID: requestID,
                        statusCode: statusCode,
                        replayRecorder: &replayRecorder,
                        replayOverflowLogged: &replayOverflowLogged
                    )
                    var out = channel.allocator.buffer(capacity: normalized.bodyData.count)
                    out.writeBytes(normalized.bodyData)
                    try await channel.writeAndFlush(
                        NIOAny(HTTPServerResponsePart.body(.byteBuffer(out)))
                    ).get()
                    if let assistantTurn = normalized.assistantTurn {
                        await Self.commitAssistantTurnIfCurrent(
                            assistantTurn,
                            branchContext: branchContext,
                            branchLease: branchLease,
                            lineageBroker: lineageBroker,
                            requestCoordinator: requestCoordinator,
                            requestID: requestID
                        )
                    }
                } else if shouldTransformBody {
                    Self.replaceReplayBody(
                        transformedBody,
                        shouldCaptureReplay: shouldCaptureReplay,
                        requestID: requestID,
                        statusCode: statusCode,
                        replayRecorder: &replayRecorder,
                        replayOverflowLogged: &replayOverflowLogged
                    )
                    var out = channel.allocator.buffer(capacity: transformedBody.count)
                    out.writeBytes(transformedBody)
                    try await channel.writeAndFlush(
                        NIOAny(HTTPServerResponsePart.body(.byteBuffer(out)))
                    ).get()
                }
            }

            // 3. Signal end of response.
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.end(nil))
            ).get()

        } catch {
            AppLog.proxy.warning("[Proxy] [\(requestID)] Response relay write error (client may have disconnected): \(error)")
        }

        try? await channel.close().get()
        return shouldCaptureReplay ? replayRecorder.replayableResponse() : nil
    }

    static func replay(
        cachedResponse: ReplayableBranchResponse,
        to channel: any Channel,
        requestID: String
    ) async {
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: cachedResponse.statusCode)
        )
        for (name, value) in cachedResponse.headers {
            let lower = name.lowercased()
            if lower == "transfer-encoding" || lower == "connection" || lower == "content-length" || lower == "content-encoding" { continue }
            responseHead.headers.add(name: name, value: value)
        }
        responseHead.headers.add(name: "connection", value: "close")

        do {
            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.head(responseHead))
            ).get()

            for bodyChunk in cachedResponse.bodyChunks {
                var out = channel.allocator.buffer(capacity: bodyChunk.count)
                out.writeBytes(bodyChunk)
                try await channel.writeAndFlush(
                    NIOAny(HTTPServerResponsePart.body(.byteBuffer(out)))
                ).get()
            }

            try await channel.writeAndFlush(
                NIOAny(HTTPServerResponsePart.end(nil))
            ).get()
        } catch {
            AppLog.proxy.warning("[Proxy] [\(requestID)] Cached response replay write error: \(error)")
        }

        try? await channel.close().get()
    }

    // MARK: - Usage Extraction

    /// Extract token usage from a non-streaming JSON response body.
    /// Handles both Anthropic format (`input_tokens`, `output_tokens`, `cache_read_input_tokens`)
    /// and OpenAI format (`prompt_tokens`, `completion_tokens`).
    static func extractUsageFromJSONBody(_ data: Data) -> (Int, Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = json["usage"] as? [String: Any] else {
            return nil
        }
        return parseUsageDict(usage)
    }

    /// Extract token usage from a single SSE chunk (may contain multiple `data:` lines).
    /// Checks both top-level `usage` and nested `message.usage` paths to handle
    /// Anthropic streaming (input_tokens in message_start, output_tokens in message_delta).
    /// Returns (0, 0) if no usage found in this chunk.
    static func extractUsageFromSSEChunk(_ buffer: ByteBuffer) -> (Int, Int) {
        guard let text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            return (0, 0)
        }
        var chunkInput = 0
        var chunkOutput = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let jsonString = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard jsonString != "[DONE]",
                  let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }
            // Check top-level usage (Anthropic message_delta, OpenAI final chunk).
            if let usage = json["usage"] as? [String: Any],
               let (input, output) = parseUsageDict(usage) {
                chunkInput += input
                chunkOutput += output
            }
            // Check nested message.usage (Anthropic message_start contains input_tokens here).
            if let message = json["message"] as? [String: Any],
               let usage = message["usage"] as? [String: Any],
               let (input, _) = parseUsageDict(usage) {
                chunkInput += input
            }
        }
        return (chunkInput, chunkOutput)
    }

    /// Parse a `usage` dictionary into (inputTokens, outputTokens).
    /// Supports Anthropic keys (`input_tokens`, `output_tokens`, `cache_read_input_tokens`)
    /// and OpenAI keys (`prompt_tokens`, `completion_tokens`).
    /// Returns nil only if no recognized token field is found.
    static func parseUsageDict(_ usage: [String: Any]) -> (Int, Int)? {
        let anthropicInput = (usage["input_tokens"] as? Int ?? 0)
            + (usage["cache_read_input_tokens"] as? Int ?? 0)
        let anthropicOutput = usage["output_tokens"] as? Int ?? 0
        let openaiInput = usage["prompt_tokens"] as? Int ?? 0
        let openaiOutput = usage["completion_tokens"] as? Int ?? 0

        let input = max(anthropicInput, openaiInput)
        let output = max(anthropicOutput, openaiOutput)

        guard input > 0 || output > 0 else { return nil }
        return (input, output)
    }

    private static func recordReplayChunk(
        _ data: Data,
        shouldCaptureReplay: Bool,
        requestID: String,
        statusCode: Int,
        replayRecorder: inout BranchReplayRecorder,
        replayOverflowLogged: inout Bool
    ) {
        guard shouldCaptureReplay else { return }
        let attempt = replayRecorder.append(data)
        if attempt.disabledByLimit && !replayOverflowLogged {
            replayOverflowLogged = true
            AppLog.proxy.warning(
                "[Proxy] [\(requestID)] ReplayDiag: action=disabled reason=size_limit limit=\(Self.maxReplayBodyBytes)B attemptedChunk=\(attempt.attemptedBytes)B status=\(statusCode)"
            )
        }
    }

    private static func replaceReplayBody(
        _ data: Data,
        shouldCaptureReplay: Bool,
        requestID: String,
        statusCode: Int,
        replayRecorder: inout BranchReplayRecorder,
        replayOverflowLogged: inout Bool
    ) {
        guard shouldCaptureReplay else { return }
        let attempt = replayRecorder.replace(with: data)
        if attempt.disabledByLimit && !replayOverflowLogged {
            replayOverflowLogged = true
            AppLog.proxy.warning(
                "[Proxy] [\(requestID)] ReplayDiag: action=disabled reason=size_limit limit=\(Self.maxReplayBodyBytes)B normalizedBody=\(attempt.attemptedBytes)B status=\(statusCode)"
            )
        }
    }

    private static func commitAssistantTurnIfCurrent(
        _ assistantTurn: PortableAssistantTurn,
        branchContext: PreparedBranchContext,
        branchLease: BranchRequestLease?,
        lineageBroker: any SessionLineageBrokering,
        requestCoordinator: (any BranchRequestCoordinating)?,
        requestID: String
    ) async {
        let shouldCommit = if let branchLease, let requestCoordinator {
            await requestCoordinator.shouldCommit(lease: branchLease)
        } else {
            true
        }
        guard shouldCommit else {
            AppLog.proxy.debug("[Proxy] [\(requestID)] staleCommitDropped lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) generation=\(branchLease?.generation ?? 0)")
            return
        }
        do {
            try await lineageBroker.commitResponse(context: branchContext, assistantTurn: assistantTurn)
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] branchCommitFailed lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) error=\(String(describing: error))")
        }
    }

    private static func logUpstreamErrorBranchContext(_ branchContext: PreparedBranchContext?, requestID: String) {
        guard let branchContext else { return }
        AppLog.proxy.warning(
            "[Proxy] [\(requestID)] UpstreamErrorDiag: lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) vendor=\(branchContext.vendorKey) replay=\(branchContext.replayPolicy.rawValue) reused=\(branchContext.reusedBranchHistory) reusedPortable=\(branchContext.reusedPortableMessageCount) hashes=\(branchContext.preparedPortableMessageHashes.count)"
        )
    }
}
