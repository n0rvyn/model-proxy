import Foundation
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import AsyncHTTPClient
import OSLog

/// Async forwarding logic, called from a Task inside ProxyChannelHandler.
enum ProxyForwarder {
    static let maxBranchWaitAttempts = 3

    struct BranchWaitBudget: Sendable, Equatable {
        let maxAttempts: Int
        private(set) var attempts: Int = 0

        init(maxAttempts: Int = ProxyForwarder.maxBranchWaitAttempts) {
            self.maxAttempts = maxAttempts
        }

        mutating func recordWait() -> Bool {
            attempts += 1
            return attempts <= maxAttempts
        }
    }

    struct EffectiveTargetDecision: Sendable {
        let target: RoutingSnapshot.RouteTarget
        let bypassedVendorName: String?

        var didBypass: Bool {
            bypassedVendorName != nil
        }
    }

    static func forward(
        clientName: String,
        head: HTTPRequestHead,
        body: ByteBuffer,
        channel: any Channel,
        router: RequestRouter,
        httpClient: HTTPClient,
        trafficLog: TrafficLog,
        tokenStatsStore: TokenStatsStore,
        lineageBroker: any SessionLineageBrokering,
        portableNormalizer: any PortableContentNormalizing,
        requestCoordinator: any BranchRequestCoordinating,
        webSearchProvider: (any WebSearchBridgeProviding)?,
        webSearchForwardAsIs: Bool = false
    ) async {
        let requestID = String(UUID().uuidString.prefix(8))
        let startTime = Date.now
        let requestKind = requestKind(for: head.uri)
        let originalBodyData = body.getData(at: body.readerIndex, length: body.readableBytes) ?? Data()
        let requestScopes = requestScopeKeys(
            bodyData: originalBodyData,
            clientName: clientName,
            channel: channel
        )

        // 1. Extract original API key (support both x-api-key and Authorization: Bearer).
        let originalAPIKey = Self.extractAPIKey(from: head.headers)

        // 2. Resolve route.
        let resolveResult: RoutingSnapshot.ResolveResult
        let model: String
        var routeState: RoutingSnapshot.RouteState
        do {
            (resolveResult, model, routeState) = try await router.resolve(bodyBytes: body, originalAPIKey: originalAPIKey)
        } catch {
            await Self.sendError(channel: channel, status: .badRequest, message: "Bad request: \(error)")
            return
        }

        let resolvedTarget: RoutingSnapshot.RouteTarget
        switch resolveResult {
        case .routed(let t):
            resolvedTarget = t
        case .blocked(let reason):
            AppLog.proxy.info("[Proxy] [\(requestID)] \(head.method.rawValue) \(head.uri) model=\(model) BLOCKED")
            let blockedEntry = TrafficEntry(
                model: model,
                routeType: .blocked,
                requestKind: .blocked,
                httpStatus: 403
            )
            await MainActor.run { trafficLog.append(blockedEntry) }
            await Self.sendError(channel: channel, status: .forbidden, message: reason)
            return
        }

        let passthroughTarget = await router.passthroughTarget(originalAPIKey: originalAPIKey)
        let targetDecision = Self.effectiveTarget(
            for: requestKind,
            resolvedTarget: resolvedTarget,
            passthroughTarget: passthroughTarget
        )
        let target = targetDecision.target
        if let bypassedVendorName = targetDecision.bypassedVendorName {
            AppLog.proxy.info(
                "[Proxy] [\(requestID)] count_tokens bypass vendor=\(bypassedVendorName) defaultUpstream=\(target.baseURL)"
            )
        }

        // Log request routing (no API keys or body content).
        let routeType = target.isPassthrough ? "passthrough" : "mapped → \(target.vendorName)"
        let originalCL = head.headers.first(name: "content-length") ?? "absent"
        let hasThinking = Self.containsJSONStringField(originalBodyData, field: "thinking")
        let hasSignature = Self.containsJSONStringField(originalBodyData, field: "signature")
        AppLog.proxy.info(
            "[Proxy] [\(requestID)] \(head.method.rawValue) \(head.uri) model=\(model) \(routeType) → \(target.baseURL) body=\(originalBodyData.count)B cl=\(originalCL) thinking=\(hasThinking) signature=\(hasSignature)"
        )

        // 3b. Diagnostic logging for thinking/signature investigation (debug mode only).
        if hasThinking || hasSignature {
            let debugEnabled = await MainActor.run { AppLogManager.shared.isEnabled }
            if debugEnabled {
                Self.logThinkingDiagnostics(body: originalBodyData, requestID: requestID)
            }
        }

        let initialPreparedRequest: PreparedRequest
        do {
            initialPreparedRequest = try await lineageBroker.prepareRequest(
                bodyData: originalBodyData,
                clientName: clientName,
                sessionScopeKey: requestScopes.sessionScopeKey,
                coordinationScopeKey: requestScopes.coordinationScopeKey,
                target: target
            )
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] Lineage prepare failed: \(error)")
            await Self.sendError(channel: channel, status: .badRequest, message: "Request projection failed: \(error)")
            return
        }

        let debugEnabled = await MainActor.run { AppLogManager.shared.isEnabled }
        if debugEnabled {
            Self.logProjectionDiagnostics(
                requestID: requestID,
                originalBody: originalBodyData,
                preparedRequest: initialPreparedRequest
            )
        }

        var preparedRequest = initialPreparedRequest
        var branchLease: BranchRequestLease?
        var waitBudget = BranchWaitBudget()
        while let context = preparedRequest.context {
            let decision = await requestCoordinator.acquire(context: context)
            if debugEnabled {
                Self.logCoordinatorDiagnostics(requestID: requestID, decision: decision, context: context)
            }
            switch decision {
            case .acquired(let lease):
                branchLease = lease
                break
            case .replay(let cachedResponse, _):
                // This path never owns a lease; the leader completed the in-flight entry and handed
                // followers a cached response directly.
                await ResponseRelay.replay(
                    cachedResponse: cachedResponse,
                    to: channel,
                    requestID: requestID
                )
                let duration = Date.now.timeIntervalSince(startTime)
                let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                    ? .passthrough
                    : .mapped(targetModel: target.targetModel ?? model)
                let entry = TrafficEntry(
                    model: model,
                    routeType: entryRouteType,
                    requestKind: requestKind,
                    httpStatus: cachedResponse.statusCode,
                    duration: duration
                )
                await MainActor.run { trafficLog.append(entry) }
                return
            case .waited:
                // This path also does not own a lease. It only waits for the leader to finish, then
                // reprojection decides whether committed branch history can be reused.
                let shouldContinue = waitBudget.recordWait()
                if !shouldContinue {
                    AppLog.proxy.error(
                        "[Proxy] [\(requestID)] CoordinatorDiag: action=aborted reason=max_wait_attempts limit=\(waitBudget.maxAttempts) lineage=\(context.lineageKey) branch=\(context.branchKey) hashes=\(context.preparedPortableMessageHashes.count)"
                    )
                    await Self.sendError(
                        channel: channel,
                        status: .conflict,
                        message: "Branch request coordination exceeded max wait attempts (\(waitBudget.maxAttempts))"
                    )
                    return
                }
                do {
                    preparedRequest = try await lineageBroker.prepareRequest(
                        bodyData: originalBodyData,
                        clientName: clientName,
                        sessionScopeKey: requestScopes.sessionScopeKey,
                        coordinationScopeKey: requestScopes.coordinationScopeKey,
                        target: target
                    )
                } catch {
                    AppLog.proxy.error("[Proxy] [\(requestID)] Lineage reprepare failed: \(error)")
                    await Self.sendError(channel: channel, status: .badRequest, message: "Request reprojection failed: \(error)")
                    return
                }
                if debugEnabled {
                    Self.logProjectionDiagnostics(
                        requestID: requestID,
                        originalBody: originalBodyData,
                        preparedRequest: preparedRequest
                    )
                }
                continue
            case .leaderFailed(let source, let replay):
                AppLog.proxy.warning(
                    "[Proxy] [\(requestID)] CoordinatorDiag: action=leader_failed sourceGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) sourceHashes=\(source.portableMessageHashes.count) targetHashes=\(context.preparedPortableMessageHashes.count) status=\(replay?.statusCode ?? 0)"
                )
                if let replay {
                    await ResponseRelay.replay(
                        cachedResponse: replay,
                        to: channel,
                        requestID: requestID
                    )
                    let duration = Date.now.timeIntervalSince(startTime)
                    let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                        ? .passthrough
                        : .mapped(targetModel: target.targetModel ?? model)
                    let entry = TrafficEntry(
                        model: model,
                        routeType: entryRouteType,
                        requestKind: requestKind,
                        httpStatus: replay.statusCode,
                        duration: duration
                    )
                    await MainActor.run { trafficLog.append(entry) }
                } else {
                    await Self.sendError(
                        channel: channel,
                        status: .conflict,
                        message: "Prior branch request failed before committing vendor history"
                    )
                    let duration = Date.now.timeIntervalSince(startTime)
                    let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                        ? .passthrough
                        : .mapped(targetModel: target.targetModel ?? model)
                    let entry = TrafficEntry(
                        model: model,
                        routeType: entryRouteType,
                        requestKind: requestKind,
                        httpStatus: 409,
                        duration: duration
                    )
                    await MainActor.run { trafficLog.append(entry) }
                }
                return
            }
            break
        }

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

        if let webSearchProvider,
           WebSearchBridge.shouldHandle(
            bodyData: preparedRequest.bodyData,
            target: target,
            requestKind: requestKind
        ) {
            nonisolated(unsafe) var lastBridgeTarget: RoutingSnapshot.RouteTarget?
            do {
                let bridgeResult = try await WebSearchBridge.execute(
                    bodyData: preparedRequest.bodyData,
                    httpClient: httpClient,
                    portableNormalizer: portableNormalizer,
                    provider: webSearchProvider,
                    performModelTurn: { turnBodyData in
                        let (bridgeResponse, usedBridgeTarget) = await Self.executeWithFailover(
                            head: head,
                            bodyData: turnBodyData,
                            primaryTarget: target,
                            model: model,
                            router: router,
                            httpClient: httpClient,
                            routeState: &routeState,
                            requestID: requestID
                        )
                        guard let bridgeResponse, let usedBridgeTarget else {
                            throw WebSearchBridgeError.upstreamFailure(statusCode: 502, bodyPreview: "Upstream unreachable")
                        }
                        lastBridgeTarget = usedBridgeTarget
                        return WebSearchBridge.ModelResponse(
                            statusCode: Int(bridgeResponse.status.code),
                            headers: bridgeResponse.headers.map { ($0.name, $0.value) },
                            bodyData: try await Self.collectResponseBody(bridgeResponse)
                        )
                    }
                )
                await router.updateRouteState(model: model, state: routeState)

                let usedTarget = lastBridgeTarget ?? target
                let statsModel = usedTarget.targetModel ?? model
                let entryRouteType: TrafficEntry.RouteType = usedTarget.isPassthrough
                    ? .passthrough
                    : .mapped(targetModel: usedTarget.targetModel ?? model)
                let sourceModelForStats: String? = usedTarget.isPassthrough ? nil : model
                if let vendorID = usedTarget.vendorID {
                    await MainActor.run {
                        tokenStatsStore.add(
                            vendorID: vendorID,
                            model: statsModel,
                            input: bridgeResult.inputTokens,
                            output: bridgeResult.outputTokens,
                            sourceModel: sourceModelForStats
                        )
                    }
                }

                AppLog.proxy.debug(
                    "[Proxy] [\(requestID)] Response: 200 OK model=\(model) vendor=\(usedTarget.vendorName) bridge=web_search"
                )
                await ResponseRelay.replay(
                    cachedResponse: bridgeResult.clientResponse,
                    to: channel,
                    requestID: requestID
                )
                if let branchContext = preparedRequest.context,
                   let branchLease,
                   let assistantTurn = bridgeResult.assistantTurn {
                    await Self.commitBridgeAssistantTurnIfCurrent(
                        assistantTurn,
                        branchContext: branchContext,
                        branchLease: branchLease,
                        lineageBroker: lineageBroker,
                        requestCoordinator: requestCoordinator,
                        requestID: requestID
                    )
                    await requestCoordinator.complete(lease: branchLease, replay: bridgeResult.clientResponse)
                } else if let branchLease {
                    await requestCoordinator.complete(lease: branchLease, replay: bridgeResult.clientResponse)
                }

                let duration = Date.now.timeIntervalSince(startTime)
                let entry = TrafficEntry(
                    model: model,
                    routeType: entryRouteType,
                    requestKind: requestKind,
                    httpStatus: 200,
                    duration: duration,
                    outputTokens: bridgeResult.outputTokens
                )
                await MainActor.run { trafficLog.append(entry) }
                return
            } catch {
                await router.updateRouteState(model: model, state: routeState)
                if let branchLease {
                    await requestCoordinator.complete(lease: branchLease, replay: nil)
                }
                AppLog.proxy.error("[Proxy] [\(requestID)] WebSearch bridge failed: \(String(describing: error))")
                let duration = Date.now.timeIntervalSince(startTime)
                let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                    ? .passthrough
                    : .mapped(targetModel: target.targetModel ?? model)
                let entry = TrafficEntry(
                    model: model,
                    routeType: entryRouteType,
                    requestKind: requestKind,
                    httpStatus: 502,
                    duration: duration
                )
                await MainActor.run { trafficLog.append(entry) }
                await Self.sendError(channel: channel, status: .badGateway, message: "WebSearch bridge failed: \(error)")
                return
            }
        }

        // 3b. Sanitize tools for mapped vendors (always, regardless of web search config).
        // WebSearchBridge handles web_search_* tools separately; this catches other
        // vendor-incompatible tools (empty name, missing input_schema, server-side types).
        var forwardBodyData = preparedRequest.bodyData
        if !target.isPassthrough {
            forwardBodyData = Self.sanitizeToolsForVendor(in: forwardBodyData)
        }
        let toolCatalog = ToolCallInputGuard.ToolCatalog.fromRequestBody(forwardBodyData)

        // 4. Build and send upstream request.
        let (upstreamResponse, usedTarget) = await Self.executeWithFailover(
            head: head,
            bodyData: forwardBodyData,
            primaryTarget: target,
            model: model,
            router: router,
            httpClient: httpClient,
            routeState: &routeState,
            requestID: requestID
        )

        // 5. Write back mutated route state.
        await router.updateRouteState(model: model, state: routeState)

        guard let upstreamResponse, let usedTarget else {
            if let branchLease {
                await requestCoordinator.complete(lease: branchLease, replay: nil)
            }
            // executeWithFailover already sent error to channel on total failure.
            let duration = Date.now.timeIntervalSince(startTime)
            let entryRouteType: TrafficEntry.RouteType = target.isPassthrough
                ? .passthrough
                : .mapped(targetModel: target.targetModel ?? model)
            let entry = TrafficEntry(
                model: model,
                routeType: entryRouteType,
                requestKind: requestKind,
                httpStatus: 502,
                duration: duration
            )
            await MainActor.run { trafficLog.append(entry) }
            await Self.sendError(channel: channel, status: .badGateway, message: "Upstream unreachable")
            return
        }

        // 6. Build usage callback for the vendor that actually served the request.
        let statsModel = usedTarget.targetModel ?? model
        let entryRouteType: TrafficEntry.RouteType = usedTarget.isPassthrough
            ? .passthrough
            : .mapped(targetModel: usedTarget.targetModel ?? model)

        // Capture output tokens for TPS display in traffic log.
        // Safe: callback fires during `await relay()` below, read happens after relay returns.
        nonisolated(unsafe) var capturedOutputTokens: Int?

        let sourceModelForStats: String? = usedTarget.isPassthrough ? nil : model
        let toolCallGuard = Self.toolCallGuard(for: usedTarget, catalog: toolCatalog)

        let vendorID = usedTarget.vendorID
        let onUsage: ResponseRelay.UsageCallback = { [tokenStatsStore] input, output in
            capturedOutputTokens = output
            if let vendorID {
                Task { @MainActor in
                    tokenStatsStore.add(vendorID: vendorID, model: statsModel, input: input, output: output, sourceModel: sourceModelForStats)
                }
            }
        }

        // 7. Log status with readable text.
        let statusCode = Int(upstreamResponse.status.code)
        let elapsedMS = Int(Date.now.timeIntervalSince(startTime) * 1000)
        AppLog.proxy.debug(
            "[Proxy] [\(requestID)] Response: \(statusCode) \(HTTPStatusText.text(for: statusCode)) model=\(model) vendor=\(usedTarget.vendorName) \(elapsedMS)ms"
        )

        // 8. Relay response.
        let replayableResponse = await ResponseRelay.relay(
            upstreamResponse: upstreamResponse,
            to: channel,
            onUsage: onUsage,
            requestID: requestID,
            branchContext: preparedRequest.context,
            branchLease: branchLease,
            portableNormalizer: portableNormalizer,
            toolCallGuard: toolCallGuard,
            lineageBroker: lineageBroker,
            requestCoordinator: requestCoordinator
        )
        if let branchLease {
            await requestCoordinator.complete(lease: branchLease, replay: replayableResponse)
        }

        // 9. Publish traffic event with actual upstream status code.
        let duration = Date.now.timeIntervalSince(startTime)
        let entry = TrafficEntry(
            model: model,
            routeType: entryRouteType,
            requestKind: requestKind,
            httpStatus: statusCode,
            duration: duration,
            outputTokens: capturedOutputTokens
        )
        await MainActor.run { trafficLog.append(entry) }
    }

    private static func requestKind(for uri: String) -> TrafficEntry.RequestKind {
        let path = URLComponents(string: "http://localhost\(uri)")?.path ?? uri
        switch path {
        case "/v1/messages":
            return .generation
        case "/v1/messages/count_tokens":
            return .countTokens
        default:
            return .auxiliary(endpointPath: path)
        }
    }

    static func effectiveTarget(
        for requestKind: TrafficEntry.RequestKind,
        resolvedTarget: RoutingSnapshot.RouteTarget,
        passthroughTarget: RoutingSnapshot.RouteTarget
    ) -> EffectiveTargetDecision {
        guard requestKind == .countTokens,
              !resolvedTarget.isPassthrough,
              !resolvedTarget.supportsAnthropicCountTokens else {
            return EffectiveTargetDecision(target: resolvedTarget, bypassedVendorName: nil)
        }
        return EffectiveTargetDecision(
            target: passthroughTarget,
            bypassedVendorName: resolvedTarget.vendorName
        )
    }

    static func toolCallGuard(
        for target: RoutingSnapshot.RouteTarget,
        catalog: ToolCallInputGuard.ToolCatalog
    ) -> ToolCallInputGuard? {
        target.repairsAnthropicToolCalls ? ToolCallInputGuard(catalog: catalog) : nil
    }

    private static func collectResponseBody(_ response: HTTPClientResponse) async throws -> Data {
        var data = Data()
        for try await chunk in response.body {
            if let bytes = chunk.getData(at: chunk.readerIndex, length: chunk.readableBytes) {
                data.append(bytes)
            }
        }
        return data
    }

    private struct RequestScopeKeys {
        let sessionScopeKey: String?
        let coordinationScopeKey: String?
    }

    private static func requestScopeKeys(
        bodyData: Data,
        clientName: String,
        channel: any Channel
    ) -> RequestScopeKeys {
        if let explicit = explicitSessionScopeKey(from: bodyData) {
            let explicitScopeKey = "\(clientName)|explicit|\(explicit)"
            return RequestScopeKeys(
                sessionScopeKey: explicitScopeKey,
                coordinationScopeKey: explicitScopeKey
            )
        }
        let channelIdentity = ObjectIdentifier(channel as AnyObject)
        return RequestScopeKeys(
            sessionScopeKey: nil,
            coordinationScopeKey: "\(clientName)|channel|\(channelIdentity)"
        )
    }

    private static func explicitSessionScopeKey(from bodyData: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            return nil
        }

        let directKeys = ["session_id", "conversation_id", "thread_id"]
        for key in directKeys {
            if let value = json[key] as? String, !value.isEmpty {
                return "\(key)=\(value)"
            }
        }

        if let metadata = json["metadata"] as? [String: Any] {
            for key in directKeys {
                if let value = metadata[key] as? String, !value.isEmpty {
                    return "metadata.\(key)=\(value)"
                }
            }
        }

        if let container = json["container"] as? [String: Any],
           let value = container["id"] as? String,
           !value.isEmpty {
            return "container.id=\(value)"
        }

        return nil
    }

    // MARK: - Failover logic

    /// Execute upstream request with optional 429 failover to backup target.
    /// Returns the response and the target that was actually used, or (nil, nil) on total failure.
    private static func executeWithFailover(
        head: HTTPRequestHead,
        bodyData: Data,
        primaryTarget: RoutingSnapshot.RouteTarget,
        model: String,
        router: RequestRouter,
        httpClient: HTTPClient,
        routeState: inout RoutingSnapshot.RouteState,
        requestID: String
    ) async -> (HTTPClientResponse?, RoutingSnapshot.RouteTarget?) {

        // Try with primary (or current active) target.
        let primaryResponse = await Self.executeUpstream(
            head: head,
            bodyData: bodyData,
            target: primaryTarget,
            httpClient: httpClient,
            requestID: requestID
        )

        guard let primaryResponse else {
            // Network-level failure (unreachable).
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
            return (nil, nil)
        }

        let statusCode = Int(primaryResponse.status.code)

        // Success: reset failCount.
        if statusCode < 400 {
            routeState.failCount = 0
            return (primaryResponse, primaryTarget)
        }

        // 429 on mapped route: try failover to backup.
        if statusCode == 429 && !primaryTarget.isPassthrough {
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }

            // Get backup targets from router.
            if let allTargets = await router.targets(for: model), allTargets.count > 1 {
                let backupTarget = (primaryTarget.vendorID == allTargets[0].vendorID) ? allTargets[1] : allTargets[0]
                AppLog.proxy.info(
                    "[Proxy] [\(requestID)] Rate limited on \(primaryTarget.vendorName), failing over to \(backupTarget.vendorName)"
                )

                let backupResponse = await Self.executeUpstream(
                    head: head,
                    bodyData: bodyData,
                    target: backupTarget,
                    httpClient: httpClient,
                    requestID: requestID
                )
                if let backupResponse {
                    if Int(backupResponse.status.code) < 400 {
                        routeState.failCount = 0
                    }
                    return (backupResponse, backupTarget)
                }
            }

            // No backup or backup also failed: return original 429.
            return (primaryResponse, primaryTarget)
        }

        // Non-429 error: forward as-is, increment failCount.
        if statusCode >= 400 {
            routeState.failCount += 1
            if routeState.failCount >= 10 {
                routeState.activeTarget = (routeState.activeTarget == .primary) ? .backup : .primary
                routeState.failCount = 0
            }
        }

        return (primaryResponse, primaryTarget)
    }

    /// Build and execute a single upstream request for a given target.
    private static func executeUpstream(
        head: HTTPRequestHead,
        bodyData: Data,
        target: RoutingSnapshot.RouteTarget,
        httpClient: HTTPClient,
        requestID: String
    ) async -> HTTPClientResponse? {
        let finalURLString = target.baseURL.trimmingCharacters(in: .init(charactersIn: "/")) + head.uri
        guard URL(string: finalURLString) != nil else { return nil }

        // Build headers.
        var upstreamHeaders = HTTPHeaders()
        for (name, value) in head.headers {
            let lower = name.lowercased()
            if lower == "host" || lower == "connection" || lower == "transfer-encoding" || lower == "content-length" || lower == "accept-encoding" { continue }
            upstreamHeaders.add(name: name, value: value)
        }
        upstreamHeaders.add(name: "Accept-Encoding", value: "gzip, deflate")
        if !target.isPassthrough {
            upstreamHeaders.remove(name: "authorization")
            upstreamHeaders.remove(name: "x-api-key")
            upstreamHeaders.add(name: "Authorization", value: "Bearer \(target.apiKey)")
            upstreamHeaders.add(name: "x-api-key", value: target.apiKey)
        }
        if let host = URL(string: target.baseURL)?.host {
            upstreamHeaders.remove(name: "host")
            upstreamHeaders.add(name: "Host", value: host)
        }

        // Replace model field using prepared body.
        var bodyData = bodyData
        if let targetModel = target.targetModel {
            let replacement = Self.replaceModelField(in: bodyData, with: targetModel)
            bodyData = replacement.data
            let delta = replacement.newLength - replacement.originalLength
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] Model replace target=\(targetModel) replaced=\(replacement.replaced) body=\(replacement.originalLength)→\(replacement.newLength)B delta=\(delta)B"
            )
            if !replacement.replaced {
                AppLog.proxy.warning("[Proxy] [\(requestID)] Model field not found at top-level; request body forwarded unchanged")
            }
        }

        var upstreamRequest = HTTPClientRequest(url: finalURLString)
        upstreamRequest.method = head.method
        upstreamRequest.headers = upstreamHeaders
        upstreamRequest.body = .bytes(bodyData)

        do {
            // Note: readTimeoutSeconds is used as the overall request deadline (connect + transfer).
            // AsyncHTTPClient doesn't support per-request connect timeout; connectTimeoutSeconds
            // is set at the HTTPClient pool level in ProxyServer.start().
            return try await httpClient.execute(upstreamRequest, timeout: .seconds(Int64(target.readTimeoutSeconds)))
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] Upstream error for \(target.vendorName): \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    struct ModelReplacementResult {
        let data: Data
        let replaced: Bool
        let originalLength: Int
        let newLength: Int
    }

    /// Replace only the top-level `"model"` field value while preserving all other bytes exactly.
    /// This avoids mutating unrelated payload bytes, including thinking/signature blocks.
    static func replaceModelField(in data: Data, with newModel: String) -> ModelReplacementResult {
        let originalLength = data.count
        let bytes = [UInt8](data)
        guard let modelValueRange = Self.topLevelModelValueRange(in: bytes) else {
            return ModelReplacementResult(
                data: data,
                replaced: false,
                originalLength: originalLength,
                newLength: originalLength
            )
        }

        let escapedModelBytes = Self.escapeJSONString(newModel)
        var result = Data()
        result.reserveCapacity(originalLength - modelValueRange.count + escapedModelBytes.count)
        result.append(contentsOf: bytes[0..<modelValueRange.lowerBound])
        result.append(contentsOf: escapedModelBytes)
        result.append(contentsOf: bytes[modelValueRange.upperBound..<bytes.count])

        return ModelReplacementResult(
            data: result,
            replaced: true,
            originalLength: originalLength,
            newLength: result.count
        )
    }

    private static func topLevelModelValueRange(in bytes: [UInt8]) -> Range<Int>? {
        let quote: UInt8 = 34
        let colon: UInt8 = 58
        let openObject: UInt8 = 123
        let closeObject: UInt8 = 125
        let openArray: UInt8 = 91
        let closeArray: UInt8 = 93
        let modelKey = Array("model".utf8)

        var index = 0
        var depth = 0

        while index < bytes.count {
            let byte = bytes[index]

            if byte == quote {
                guard let (stringRange, nextIndex) = Self.parseJSONString(in: bytes, startingAt: index) else {
                    return nil
                }

                if depth == 1 {
                    var cursor = nextIndex
                    while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) {
                        cursor += 1
                    }

                    if cursor < bytes.count, bytes[cursor] == colon, bytes[stringRange].elementsEqual(modelKey) {
                        cursor += 1
                        while cursor < bytes.count, Self.isWhitespace(bytes[cursor]) {
                            cursor += 1
                        }

                        guard cursor < bytes.count, bytes[cursor] == quote,
                              let (modelValueRange, _) = Self.parseJSONString(in: bytes, startingAt: cursor) else {
                            return nil
                        }
                        return modelValueRange
                    }
                }

                index = nextIndex
                continue
            }

            switch byte {
            case openObject, openArray:
                depth += 1
            case closeObject, closeArray:
                depth = max(0, depth - 1)
            default:
                break
            }

            index += 1
        }

        return nil
    }

    private static func parseJSONString(in bytes: [UInt8], startingAt start: Int) -> (Range<Int>, Int)? {
        let quote: UInt8 = 34
        let backslash: UInt8 = 92
        guard start < bytes.count, bytes[start] == quote else { return nil }

        var index = start + 1
        var escaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }

            if byte == backslash {
                escaped = true
                index += 1
                continue
            }

            if byte == quote {
                return ((start + 1)..<index, index + 1)
            }

            index += 1
        }

        return nil
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 32 || byte == 9 || byte == 10 || byte == 13
    }

    private static func escapeJSONString(_ value: String) -> [UInt8] {
        var escaped = ""
        escaped.reserveCapacity(value.utf8.count)

        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 34:
                escaped += "\\\""
            case 92:
                escaped += "\\\\"
            case 8:
                escaped += "\\b"
            case 12:
                escaped += "\\f"
            case 10:
                escaped += "\\n"
            case 13:
                escaped += "\\r"
            case 9:
                escaped += "\\t"
            case 0..<32:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }

        return Array(escaped.utf8)
    }

    struct AnthropicBodySanitizationResult: Sendable, Equatable {
        let bodyData: Data
        let normalizedToolUseCount: Int
        let normalizedToolResultCount: Int
    }

    static func sanitizeAnthropicBodyIfNeeded(_ body: Data) -> AnthropicBodySanitizationResult {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let messages = json["messages"] as? [[String: Any]] else {
            return AnthropicBodySanitizationResult(
                bodyData: body,
                normalizedToolUseCount: 0,
                normalizedToolResultCount: 0
            )
        }

        let normalized = ToolUseIDNormalizer.normalizeMessages(messages)
        guard normalized.changed else {
            return AnthropicBodySanitizationResult(
                bodyData: body,
                normalizedToolUseCount: 0,
                normalizedToolResultCount: 0
            )
        }

        json["messages"] = normalized.messages
        let normalizedBody = (try? TranscriptProjector.encodeJSONObject(json)) ?? body
        return AnthropicBodySanitizationResult(
            bodyData: normalizedBody,
            normalizedToolUseCount: normalized.normalizedToolUseCount,
            normalizedToolResultCount: normalized.normalizedToolResultCount
        )
    }

    private static func containsJSONStringField(_ data: Data, field: String) -> Bool {
        data.range(of: Data(("\"\(field)\"").utf8)) != nil
    }

    struct RequestStructureSummary: Sendable, Equatable {
        let bodyBytes: Int
        let messageCount: Int
        let assistantMessageCount: Int
        let arrayContentMessageCount: Int
        let stringContentMessageCount: Int
        let textBlockCount: Int
        let thinkingBlockCount: Int
        let signedThinkingBlockCount: Int
        let redactedThinkingBlockCount: Int
        let toolUseBlockCount: Int
        let toolResultBlockCount: Int
        let otherBlockCount: Int
        let topLevelThinkingType: String?
        let topLevelThinkingBudget: Int?
    }

    static func summarizeRequestBody(_ body: Data) -> RequestStructureSummary? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let messages = json["messages"] as? [[String: Any]] ?? []
        let thinkingConfig = json["thinking"] as? [String: Any]

        var assistantMessageCount = 0
        var arrayContentMessageCount = 0
        var stringContentMessageCount = 0
        var textBlockCount = 0
        var thinkingBlockCount = 0
        var signedThinkingBlockCount = 0
        var redactedThinkingBlockCount = 0
        var toolUseBlockCount = 0
        var toolResultBlockCount = 0
        var otherBlockCount = 0

        for message in messages {
            if (message["role"] as? String) == "assistant" {
                assistantMessageCount += 1
            }

            if let blocks = message["content"] as? [[String: Any]] {
                arrayContentMessageCount += 1
                for block in blocks {
                    let blockType = (block["type"] as? String)?.lowercased()
                    switch blockType {
                    case "text":
                        textBlockCount += 1
                    case "thinking":
                        thinkingBlockCount += 1
                        if block["signature"] is String {
                            signedThinkingBlockCount += 1
                        }
                    case "redacted_thinking":
                        redactedThinkingBlockCount += 1
                    case "tool_use":
                        toolUseBlockCount += 1
                    case "tool_result":
                        toolResultBlockCount += 1
                    default:
                        otherBlockCount += 1
                    }
                }
            } else if message["content"] is String {
                stringContentMessageCount += 1
            }
        }

        return RequestStructureSummary(
            bodyBytes: body.count,
            messageCount: messages.count,
            assistantMessageCount: assistantMessageCount,
            arrayContentMessageCount: arrayContentMessageCount,
            stringContentMessageCount: stringContentMessageCount,
            textBlockCount: textBlockCount,
            thinkingBlockCount: thinkingBlockCount,
            signedThinkingBlockCount: signedThinkingBlockCount,
            redactedThinkingBlockCount: redactedThinkingBlockCount,
            toolUseBlockCount: toolUseBlockCount,
            toolResultBlockCount: toolResultBlockCount,
            otherBlockCount: otherBlockCount,
            topLevelThinkingType: thinkingConfig?["type"] as? String,
            topLevelThinkingBudget: thinkingConfig?["budget_tokens"] as? Int
        )
    }

    private static func logProjectionDiagnostics(
        requestID: String,
        originalBody: Data,
        preparedRequest: PreparedRequest
    ) {
        guard let original = summarizeRequestBody(originalBody),
              let prepared = summarizeRequestBody(preparedRequest.bodyData) else {
            return
        }

        let bodyDelta = prepared.bodyBytes - original.bodyBytes
        let thinkingConfig = prepared.topLevelThinkingType ?? "none"
        let budget = prepared.topLevelThinkingBudget.map(String.init) ?? "none"
        AppLog.proxy.debug(
            "[Proxy] [\(requestID)] ProjectionDiag: body=\(original.bodyBytes)→\(prepared.bodyBytes)B delta=\(bodyDelta) msgs=\(original.messageCount)→\(prepared.messageCount) assistant=\(original.assistantMessageCount)→\(prepared.assistantMessageCount) content[array/string]=\(original.arrayContentMessageCount)/\(original.stringContentMessageCount)→\(prepared.arrayContentMessageCount)/\(prepared.stringContentMessageCount) blocks[text/thinking/signed/redacted/tool_use/tool_result/other]=\(original.textBlockCount)/\(original.thinkingBlockCount)/\(original.signedThinkingBlockCount)/\(original.redactedThinkingBlockCount)/\(original.toolUseBlockCount)/\(original.toolResultBlockCount)/\(original.otherBlockCount)→\(prepared.textBlockCount)/\(prepared.thinkingBlockCount)/\(prepared.signedThinkingBlockCount)/\(prepared.redactedThinkingBlockCount)/\(prepared.toolUseBlockCount)/\(prepared.toolResultBlockCount)/\(prepared.otherBlockCount) thinking.config=\(thinkingConfig) budget=\(budget)"
        )

        if let context = preparedRequest.context {
            let portableBytes = preparedRequest.projectedPortableMessagesData?.count ?? 0
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] ProjectionDiag: branch lineage=\(context.lineageKey) branch=\(context.branchKey) reused=\(context.reusedBranchHistory) reusedPortable=\(context.reusedPortableMessageCount) portableHashes=\(context.preparedPortableMessageHashes.count) portableBytes=\(portableBytes)"
            )
        }
    }

    private static func logCoordinatorDiagnostics(
        requestID: String,
        decision: BranchRequestAcquireDecision,
        context: PreparedBranchContext
    ) {
        switch decision {
        case .acquired(let lease):
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=acquired lineage=\(context.lineageKey) branch=\(context.branchKey) generation=\(lease.generation) hashes=\(context.preparedPortableMessageHashes.count)"
            )
        case .replay(_, let source):
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=replay sourceGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) hashes=\(source.portableMessageHashes.count)"
            )
        case .waited(let source):
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=waited onGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) sourceHashes=\(source.portableMessageHashes.count) targetHashes=\(context.preparedPortableMessageHashes.count)"
            )
        case .leaderFailed(let source, let replay):
            AppLog.proxy.warning(
                "[Proxy] [\(requestID)] CoordinatorDiag: action=leader_failed sourceGeneration=\(source.generation) lineage=\(source.lineageKey) branch=\(source.branchKey) sourceHashes=\(source.portableMessageHashes.count) targetHashes=\(context.preparedPortableMessageHashes.count) status=\(replay?.statusCode ?? 0)"
            )
        }
    }

    // MARK: - Thinking Diagnostics

    /// Log structural metadata about thinking/signature blocks in the request body.
    /// Only logs message indices, roles, block type counts, and signature presence — no content.
    private static func logThinkingDiagnostics(body: Data, requestID: String) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }

        // Log top-level thinking configuration.
        if let thinking = json["thinking"] as? [String: Any] {
            let thinkingType = thinking["type"] as? String ?? "?"
            let budget = thinking["budget_tokens"] as? Int
            let budgetStr = budget.map { String($0) } ?? "none"
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] ThinkingDiag: config thinking.type=\(thinkingType) budget=\(budgetStr)"
            )
        }

        // Log per-message thinking block structure.
        guard let messages = json["messages"] as? [[String: Any]] else { return }
        for (index, message) in messages.enumerated() {
            let role = message["role"] as? String ?? "?"

            // content can be a string or an array of blocks.
            guard let contentArray = message["content"] as? [[String: Any]] else { continue }

            var thinkingCount = 0
            var allHaveSignature = true
            var anyHasSignature = false

            for block in contentArray {
                let blockType = block["type"] as? String ?? ""
                if blockType == "thinking" {
                    thinkingCount += 1
                    if block["signature"] is String {
                        anyHasSignature = true
                    } else {
                        allHaveSignature = false
                    }
                }
            }

            // Only log messages that contain thinking blocks.
            guard thinkingCount > 0 else { continue }
            let sigStatus: String
            if allHaveSignature && anyHasSignature {
                sigStatus = "all-signed"
            } else if anyHasSignature {
                sigStatus = "partial-signed"
            } else {
                sigStatus = "unsigned"
            }
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] ThinkingDiag: msg[\(index)] role=\(role) blocks=\(contentArray.count) thinking=\(thinkingCount) sig=\(sigStatus)"
            )
        }
    }

    private static func extractAPIKey(from headers: HTTPHeaders) -> String {
        if let bearer = headers.first(name: "authorization") {
            return bearer.hasPrefix("Bearer ") ? String(bearer.dropFirst(7)) : bearer
        }
        return headers.first(name: "x-api-key") ?? ""
    }

    static func sendError(channel: any Channel, status: HTTPResponseStatus, message: String) async {
        let bodyData = Data(message.utf8)
        var responseHead = HTTPResponseHead(version: .http1_1, status: status)
        responseHead.headers.add(name: "Content-Type", value: "text/plain")
        responseHead.headers.add(name: "Content-Length", value: "\(bodyData.count)")
        responseHead.headers.add(name: "Connection", value: "close")

        var buf = channel.allocator.buffer(capacity: bodyData.count)
        buf.writeBytes(bodyData)

        _ = try? await channel.write(
            NIOAny(HTTPServerResponsePart.head(responseHead))
        ).get()
        _ = try? await channel.write(
            NIOAny(HTTPServerResponsePart.body(.byteBuffer(buf)))
        ).get()
        _ = try? await channel.writeAndFlush(
            NIOAny(HTTPServerResponsePart.end(nil))
        ).get()
        try? await channel.close().get()
    }

    private static func commitBridgeAssistantTurnIfCurrent(
        _ assistantTurn: PortableAssistantTurn,
        branchContext: PreparedBranchContext,
        branchLease: BranchRequestLease,
        lineageBroker: any SessionLineageBrokering,
        requestCoordinator: any BranchRequestCoordinating,
        requestID: String
    ) async {
        guard await requestCoordinator.shouldCommit(lease: branchLease) else {
            AppLog.proxy.debug(
                "[Proxy] [\(requestID)] staleBridgeCommitDropped lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) generation=\(branchLease.generation)"
            )
            return
        }
        do {
            try await lineageBroker.commitResponse(context: branchContext, assistantTurn: assistantTurn)
        } catch {
            AppLog.proxy.error("[Proxy] [\(requestID)] bridgeCommitFailed lineage=\(branchContext.lineageKey) branch=\(branchContext.branchKey) error=\(String(describing: error))")
        }
    }

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
}
