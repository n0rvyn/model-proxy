import Testing
import Foundation
import NIOCore
@testable import ModelProxy

struct ModelProxyTests {

    // MARK: - Vendor round-trip

    @Test func vendorCodableRoundTrip() throws {
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            apiKey: "test-key-placeholder"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - Vendor timeout round-trip

    @Test func vendorCodableRoundTripWithTimeouts() throws {
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "SlowVendor",
            baseURL: "https://slow.example.com",
            apiKey: "key",
            connectTimeoutSeconds: 30,
            readTimeoutSeconds: 300
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.connectTimeoutSeconds == 30)
        #expect(decoded.readTimeoutSeconds == 300)
    }

    // MARK: - Vendor compatibleClientID round-trip

    @Test func vendorCodableRoundTripWithCompatibleClientID() throws {
        let clientID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            apiKey: "key",
            compatibleClientID: clientID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.compatibleClientID == clientID)
    }

    // MARK: - Vendor supportedModels round-trip

    @Test func vendorCodableRoundTripWithSupportedModels() throws {
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "DashScope",
            baseURL: "https://dashscope.aliyuncs.com/compatible-mode",
            apiKey: "key",
            supportedModels: ["qwen-plus", "qwen-max"],
            supportsThinkingBlocks: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.supportedModels == ["qwen-plus", "qwen-max"])
        #expect(decoded.supportsThinkingBlocks == true)
    }

    // MARK: - Vendor legacy JSON (no timeout/compatibleClientID fields)

    @Test func vendorDecodesLegacyJSON() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "name": "DashScope",
            "baseURL": "https://dashscope.aliyuncs.com/compatible-mode",
            "apiKey": "test-key"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Vendor.self, from: legacyJSON)
        #expect(decoded.connectTimeoutSeconds == 10)
        #expect(decoded.readTimeoutSeconds == 120)
        #expect(decoded.compatibleClientID == nil)
        #expect(decoded.supportedModels.isEmpty)
        #expect(decoded.supportsThinkingBlocks == false)
        #expect(decoded.supportsAnthropicCountTokens == true)
        #expect(decoded.repairsAnthropicToolCalls == false)
        #expect(decoded.signingDomain == .compatibleThirdParty)
        #expect(decoded.replayPolicy == .portableOnly)
    }

    @Test func vendorDecodesLegacyDeepSeekCapabilitiesFromBaseURL() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-0000000000D5",
            "name": "DeepSeek",
            "baseURL": "https://api.deepseek.com/anthropic",
            "apiKey": "test-key"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Vendor.self, from: legacyJSON)
        #expect(decoded.supportsAnthropicCountTokens == false)
        #expect(decoded.repairsAnthropicToolCalls == true)
    }

    @Test func vendorExplicitCapabilityValuesOverrideDeepSeekInference() throws {
        let json = """
        {
            "id": "00000000-0000-0000-0000-0000000000D6",
            "name": "DeepSeek",
            "baseURL": "https://api.deepseek.com/anthropic",
            "apiKey": "test-key",
            "supportsAnthropicCountTokens": true,
            "repairsAnthropicToolCalls": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Vendor.self, from: json)
        #expect(decoded.supportsAnthropicCountTokens == true)
        #expect(decoded.repairsAnthropicToolCalls == false)
    }

    @Test func vendorCapabilityRoundTrip() throws {
        let original = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000D7")!,
            name: "Custom",
            baseURL: "https://custom.example.com/anthropic",
            apiKey: "key",
            supportsAnthropicCountTokens: false,
            repairsAnthropicToolCalls: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Vendor.self, from: data)
        #expect(decoded == original)
        #expect(decoded.supportsAnthropicCountTokens == false)
        #expect(decoded.repairsAnthropicToolCalls == true)
    }

    // MARK: - ClientConfig round-trip

    @Test func clientConfigCodableRoundTrip() throws {
        let original = ClientConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ClientConfig migration (old JSON without defaultUpstream)

    @Test func clientConfigDecodesLegacyJSON() throws {
        // Old format: has modelMappings, no defaultUpstream
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000003",
            "clientName": "Claude Code",
            "port": 8080,
            "modelMappings": {"claude-haiku-4-5": {"targetModel": "qwen-turbo", "targetVendorID": "00000000-0000-0000-0000-000000000002"}}
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: legacyJSON)
        #expect(decoded.clientName == "Claude Code")
        #expect(decoded.port == 8080)
        #expect(decoded.defaultUpstream == "") // empty = needs migration in ConfigStore
    }

    // MARK: - ModelMapping round-trip

    @Test func modelMappingCodableRoundTrip() throws {
        let vendorID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let original = ModelMapping(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            sourceModel: "claude-haiku-4-5",
            targetModel: "qwen-turbo",
            targetVendorID: vendorID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelMapping.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - ModelMapping with backup target round-trip

    @Test func modelMappingWithBackupTargetRoundTrip() throws {
        let vendorID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let backupVendorID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let original = ModelMapping(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            sourceModel: "claude-haiku-4-5",
            targetModel: "qwen-turbo",
            targetVendorID: vendorID,
            backupTargetModel: "glm-4-flash",
            backupTargetVendorID: backupVendorID
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelMapping.self, from: data)
        #expect(decoded == original)
        #expect(decoded.backupTargetModel == "glm-4-flash")
        #expect(decoded.backupTargetVendorID == backupVendorID)
    }

    // MARK: - ModelMapping legacy JSON (no backup fields)

    @Test func modelMappingDecodesLegacyJSON() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000010",
            "sourceModel": "claude-haiku-4-5",
            "targetModel": "qwen-turbo",
            "targetVendorID": "00000000-0000-0000-0000-000000000002"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ModelMapping.self, from: legacyJSON)
        #expect(decoded.backupTargetModel == nil)
        #expect(decoded.backupTargetVendorID == nil)
    }

    // MARK: - AppConfig round-trip

    @Test func appConfigCodableRoundTrip() throws {
        let config = AppConfig.makeDefault()
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        #expect(decoded.vendors.count == config.vendors.count)
        #expect(decoded.clients.count == config.clients.count)
        #expect(decoded.modelMappings.count == config.modelMappings.count)
        #expect(decoded.clients.first?.port == config.clients.first?.port)
        #expect(decoded.clients.first?.defaultUpstream == config.clients.first?.defaultUpstream)
    }

    // MARK: - AppConfig default shape

    @Test func defaultConfigHasExpectedShape() {
        let config = AppConfig.makeDefault()
        #expect(config.vendors.isEmpty)
        #expect(config.clients.count == 2)
        #expect(config.clients[0].clientName == "Claude Code")
        #expect(config.clients[0].port == 8080)
        #expect(config.clients[0].defaultUpstream == "https://api.anthropic.com")
        #expect(config.clients[1].clientName == "Codex")
        #expect(config.clients[1].port == 8081)
        #expect(config.modelMappings.isEmpty)
    }

    // MARK: - RoutingSnapshot: mapped model

    @Test func routingSnapshotResolvesMappedModel() {
        let vendor = Vendor(name: "DashScope", baseURL: "https://dashscope.aliyuncs.com/compatible-mode", apiKey: "dash-test-key")
        let mapping = ModelMapping(sourceModel: "claude-haiku-4-5", targetModel: "qwen-turbo", targetVendorID: vendor.id)
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [vendor], clients: [client], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let (result, _) = snapshot.resolve(model: "claude-haiku-4-5", originalAPIKey: "original-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(!target.isPassthrough)
        #expect(target.baseURL == "https://dashscope.aliyuncs.com/compatible-mode")
        #expect(target.apiKey == "dash-test-key")
        #expect(target.targetModel == "qwen-turbo")
        #expect(target.signingDomain == .compatibleThirdParty)
        #expect(target.replayPolicy == .portableOnly)
        #expect(target.supportsThinkingBlocks == false)
        #expect(target.supportsAnthropicCountTokens == true)
        #expect(target.repairsAnthropicToolCalls == false)
    }

    // MARK: - RoutingSnapshot: unmapped model passthrough

    @Test func routingSnapshotPassthroughUnmappedModel() {
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let config = AppConfig(vendors: [], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let (result, _) = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(target.isPassthrough)
        #expect(target.baseURL == "https://api.anthropic.com")
        #expect(target.apiKey == "my-key")
        #expect(target.targetModel == nil)
        #expect(target.signingDomain == .anthropicOfficial)
        #expect(target.replayPolicy == .transparent)
        #expect(target.supportsThinkingBlocks == true)
        #expect(target.supportsAnthropicCountTokens == true)
        #expect(target.repairsAnthropicToolCalls == false)
    }

    // MARK: - RoutingSnapshot: different client uses different defaultUpstream

    @Test func routingSnapshotUsesClientDefaultUpstream() {
        let codexClient = ClientConfig(clientName: "Codex", port: 8081, defaultUpstream: "https://api.openai.com")
        let config = AppConfig(vendors: [], clients: [codexClient], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: codexClient)

        let (result, _) = snapshot.resolve(model: "some-model", originalAPIKey: "key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(target.isPassthrough)
        #expect(target.baseURL == "https://api.openai.com")
    }

    // MARK: - UnmappedModelPolicy: block

    @Test func routingSnapshotBlocksUnmappedModel() {
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .block)
        let config = AppConfig(vendors: [], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let (result, _) = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .blocked = result else {
            Issue.record("Expected .blocked, got \(result)")
            return
        }
    }

    // MARK: - UnmappedModelPolicy: routeAll

    @Test func routingSnapshotRouteAllUnmappedModel() {
        let vendor = Vendor(name: "Fallback", baseURL: "https://fallback.example.com", apiKey: "fallback-test-key")
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com", unmappedPolicy: .routeAll, fallbackVendorID: vendor.id)
        let config = AppConfig(vendors: [vendor], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let (result, _) = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(!target.isPassthrough)
        #expect(target.baseURL == "https://fallback.example.com")
        #expect(target.apiKey == "fallback-test-key")
        #expect(target.targetModel == nil) // keeps original model name
        #expect(target.supportsThinkingBlocks == false)
        #expect(target.supportsAnthropicCountTokens == true)
        #expect(target.repairsAnthropicToolCalls == false)
    }

    @Test func routingSnapshotRouteAllUnmappedModelUsesFallbackTargetModel() {
        let vendor = Vendor(
            name: "Fallback",
            baseURL: "https://fallback.example.com",
            apiKey: "fallback-test-key",
            supportedModels: ["deepseek-v4-pro"],
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: false,
            repairsAnthropicToolCalls: true
        )
        let client = ClientConfig(
            clientName: "Claude Code",
            port: 8080,
            defaultUpstream: "https://api.anthropic.com",
            unmappedPolicy: .routeAll,
            fallbackVendorID: vendor.id,
            fallbackTargetModel: "deepseek-v4-pro"
        )
        let config = AppConfig(vendors: [vendor], clients: [client], modelMappings: [])
        let snapshot = RoutingSnapshot(from: config, for: client)

        let (result, _) = snapshot.resolve(model: "claude-opus-4-6", originalAPIKey: "my-key")
        guard case .routed(let target) = result else {
            Issue.record("Expected .routed, got \(result)")
            return
        }
        #expect(!target.isPassthrough)
        #expect(target.targetModel == "deepseek-v4-pro")
        #expect(target.supportsThinkingBlocks == true)
        #expect(target.supportsAnthropicCountTokens == false)
        #expect(target.repairsAnthropicToolCalls == true)
    }

    // MARK: - Legacy JSON decodes unmappedPolicy as .passthrough

    @Test func clientConfigLegacyDefaultsToPassthrough() throws {
        let legacyJSON = """
        {
            "id": "00000000-0000-0000-0000-000000000099",
            "clientName": "Test",
            "port": 9999,
            "defaultUpstream": "https://example.com"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ClientConfig.self, from: legacyJSON)
        #expect(decoded.unmappedPolicy == .passthrough)
        #expect(decoded.fallbackVendorID == nil)
    }

    // MARK: - TokenStats accumulation

    @Test func tokenStatsAccumulation() {
        var stats = TokenStats()
        let vendorID = UUID()
        stats.add(vendorID: vendorID, modelID: "claude-haiku-4-5", input: 100, output: 50)
        stats.add(vendorID: vendorID, modelID: "claude-haiku-4-5", input: 200, output: 75)
        #expect(stats.totalInputTokens() == 300)
        #expect(stats.totalOutputTokens() == 125)
    }

    // MARK: - ResponseRelay: Anthropic streaming usage extraction

    @Test func extractUsageFromAnthropicSSEStream() {
        // message_start carries input_tokens in message.usage
        let messageStart = """
        data: {"type":"message_start","message":{"usage":{"input_tokens":150,"output_tokens":0}}}

        """
        // message_delta carries output_tokens in top-level usage
        let messageDelta = """
        data: {"type":"message_delta","usage":{"output_tokens":42}}

        """
        let allocator = ByteBufferAllocator()
        var buf1 = allocator.buffer(capacity: messageStart.utf8.count)
        buf1.writeString(messageStart)
        let (input1, output1) = ResponseRelay.extractUsageFromSSEChunk(buf1)
        #expect(input1 == 150)
        #expect(output1 == 0)

        var buf2 = allocator.buffer(capacity: messageDelta.utf8.count)
        buf2.writeString(messageDelta)
        let (input2, output2) = ResponseRelay.extractUsageFromSSEChunk(buf2)
        #expect(input2 == 0)
        #expect(output2 == 42)
    }

    // MARK: - ResponseRelay: OpenAI streaming usage extraction

    @Test func extractUsageFromOpenAISSEStream() {
        let chunk = """
        data: {"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":80}}

        """
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        let (input, output) = ResponseRelay.extractUsageFromSSEChunk(buf)
        #expect(input == 200)
        #expect(output == 80)
    }

    // MARK: - ResponseRelay: Non-streaming Anthropic JSON

    @Test func extractUsageFromAnthropicJSONBody() {
        let json = """
        {"usage":{"input_tokens":100,"cache_read_input_tokens":50,"output_tokens":30}}
        """.data(using: .utf8)!
        let result = ResponseRelay.extractUsageFromJSONBody(json)
        #expect(result != nil)
        #expect(result?.0 == 150) // input_tokens + cache_read_input_tokens
        #expect(result?.1 == 30)
    }

    // MARK: - ResponseRelay: Non-streaming OpenAI JSON

    @Test func extractUsageFromOpenAIJSONBody() {
        let json = """
        {"usage":{"prompt_tokens":300,"completion_tokens":120}}
        """.data(using: .utf8)!
        let result = ResponseRelay.extractUsageFromJSONBody(json)
        #expect(result != nil)
        #expect(result?.0 == 300)
        #expect(result?.1 == 120)
    }

    // MARK: - ResponseRelay: Missing/malformed usage

    @Test func extractUsageFromMissingUsageReturnsNil() {
        let json = """
        {"id":"msg_123","content":[]}
        """.data(using: .utf8)!
        let result = ResponseRelay.extractUsageFromJSONBody(json)
        #expect(result == nil)
    }

    @Test func extractUsageFromSSEChunkWithNoUsage() {
        let chunk = """
        data: {"type":"content_block_delta","delta":{"text":"hello"}}

        """
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        let (input, output) = ResponseRelay.extractUsageFromSSEChunk(buf)
        #expect(input == 0)
        #expect(output == 0)
    }

    @Test func extractUsageFromSSEDoneMarker() {
        let chunk = "data: [DONE]\n\n"
        let allocator = ByteBufferAllocator()
        var buf = allocator.buffer(capacity: chunk.utf8.count)
        buf.writeString(chunk)
        let (input, output) = ResponseRelay.extractUsageFromSSEChunk(buf)
        #expect(input == 0)
        #expect(output == 0)
    }

    // MARK: - RoutingSnapshot: backup filtered by compatibleClientID

    @Test func routingSnapshotFiltersBackupByCompatibleClientID() {
        let client = ClientConfig(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
            clientName: "Claude Code", port: 8080,
            defaultUpstream: "https://api.anthropic.com"
        )
        let otherClientID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
        let primaryVendor = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!,
            name: "Primary", baseURL: "https://primary.example.com", apiKey: "pk"
        )
        // Backup vendor is only compatible with a DIFFERENT client
        let backupVendor = Vendor(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!,
            name: "Backup", baseURL: "https://backup.example.com", apiKey: "bk",
            compatibleClientID: otherClientID
        )
        let mapping = ModelMapping(
            sourceModel: "test-model", targetModel: "primary-model",
            targetVendorID: primaryVendor.id,
            backupTargetModel: "backup-model",
            backupTargetVendorID: backupVendor.id
        )
        let config = AppConfig(vendors: [primaryVendor, backupVendor], clients: [client], modelMappings: [mapping])
        let snapshot = RoutingSnapshot(from: config, for: client)

        // Backup should be excluded — targets(for:) should return only primary
        let targets = snapshot.targets(for: "test-model")
        #expect(targets?.count == 1)
        #expect(targets?.first?.vendorName == "Primary")
    }

    // MARK: - RoutingSnapshot: backup target resolves correctly

    @Test func routingSnapshotWithBackupTargetResolvesCorrectly() {
        let client = ClientConfig(clientName: "Claude Code", port: 8080, defaultUpstream: "https://api.anthropic.com")
        let primaryVendor = Vendor(name: "Primary", baseURL: "https://primary.example.com", apiKey: "pk")
        let backupVendor = Vendor(
            name: "Backup",
            baseURL: "https://backup.example.com",
            apiKey: "bk",
            supportsThinkingBlocks: true,
            supportsAnthropicCountTokens: false,
            repairsAnthropicToolCalls: true
        )
        let mapping = ModelMapping(
            sourceModel: "test-model", targetModel: "primary-model",
            targetVendorID: primaryVendor.id,
            backupTargetModel: "backup-model",
            backupTargetVendorID: backupVendor.id
        )
        let config = AppConfig(vendors: [primaryVendor, backupVendor], clients: [client], modelMappings: [mapping])
        var snapshot = RoutingSnapshot(from: config, for: client)

        // Default state = primary
        let (result1, _) = snapshot.resolve(model: "test-model", originalAPIKey: "key")
        guard case .routed(let target1) = result1 else {
            Issue.record("Expected .routed"); return
        }
        #expect(target1.vendorName == "Primary")
        #expect(target1.targetModel == "primary-model")

        // Switch to backup via state update
        var state = RoutingSnapshot.RouteState()
        state.activeTarget = .backup
        snapshot.updateRouteState(for: "test-model", state: state)

        let (result2, _) = snapshot.resolve(model: "test-model", originalAPIKey: "key")
        guard case .routed(let target2) = result2 else {
            Issue.record("Expected .routed"); return
        }
        #expect(target2.vendorName == "Backup")
        #expect(target2.targetModel == "backup-model")
        #expect(target2.supportsThinkingBlocks == true)
        #expect(target2.supportsAnthropicCountTokens == false)
        #expect(target2.repairsAnthropicToolCalls == true)
    }

    // MARK: - RouteState: failCount threshold switches activeTarget

    @Test func routeStateFailCountThreshold() {
        // Simulate the threshold logic from ProxyForwarder
        var state = RoutingSnapshot.RouteState()
        #expect(state.activeTarget == .primary)
        #expect(state.failCount == 0)

        // Increment to 9 — should NOT switch
        for _ in 0..<9 {
            state.failCount += 1
        }
        #expect(state.failCount == 9)
        #expect(state.activeTarget == .primary) // still primary

        // Increment to 10 — threshold reached, switch
        state.failCount += 1
        if state.failCount >= 10 {
            state.activeTarget = (state.activeTarget == .primary) ? .backup : .primary
            state.failCount = 0
        }
        #expect(state.activeTarget == .backup)
        #expect(state.failCount == 0)
    }

    // MARK: - RouteState: success resets failCount

    @Test func routeStateResetsOnSuccess() {
        var state = RoutingSnapshot.RouteState()
        state.failCount = 7
        state.activeTarget = .primary

        // Simulate success reset (as done in ProxyForwarder)
        state.failCount = 0
        #expect(state.failCount == 0)
        #expect(state.activeTarget == .primary) // target unchanged on success
    }

    // MARK: - DailyTokenSnapshot round-trip

    @Test func dailyTokenSnapshotRoundTrip() throws {
        let vendorID = UUID()
        let record = ModelTokenRecord(inputTokens: 500, outputTokens: 200)
        let snapshot = DailyTokenSnapshot(
            date: "2026-03-06",
            usageByVendorAndModel: [vendorID.uuidString: ["claude-sonnet-4-6": record]]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(DailyTokenSnapshot.self, from: data)
        #expect(decoded.date == snapshot.date)
        #expect(decoded.usageByVendorAndModel[vendorID.uuidString]?["claude-sonnet-4-6"] == record)
    }

    // MARK: - ProxyForwarder: model replacement safety

    @Test func replaceModelFieldUpdatesTopLevelOnlyAndKeepsFormatting() {
        let source = #"{"model" : "claude-opus-4-6","messages":[{"role":"user","content":"hi"}]}"#
        let replaced = ProxyForwarder.replaceModelField(in: Data(source.utf8), with: "qwen-plus")

        #expect(replaced.replaced)
        #expect(replaced.originalLength == source.utf8.count)
        #expect(String(data: replaced.data, encoding: .utf8) == #"{"model" : "qwen-plus","messages":[{"role":"user","content":"hi"}]}"#)
    }

    @Test func replaceModelFieldDoesNotTouchNestedModelMentions() {
        let source = #"{"messages":[{"role":"user","content":"literal {\"model\":\"nested\"}"}],"model":"claude-sonnet-4-6"}"#
        let replaced = ProxyForwarder.replaceModelField(in: Data(source.utf8), with: "glm-4")
        let output = String(data: replaced.data, encoding: .utf8)

        #expect(replaced.replaced)
        #expect(output?.contains(#"literal {\"model\":\"nested\"}"#) == true)
        #expect(output == #"{"messages":[{"role":"user","content":"literal {\"model\":\"nested\"}"}],"model":"glm-4"}"#)
    }

    @Test func replaceModelFieldPreservesThinkingAndSignatureBytes() {
        let thinkingBlock = #"{"type":"thinking","thinking":"chain-of-thought","signature":"sig_abc123"}"#
        let source = #"{"model":"claude-sonnet-4-6","messages":[{"role":"assistant","content":[\#(thinkingBlock)]}]}"#
        let replaced = ProxyForwarder.replaceModelField(in: Data(source.utf8), with: "qwen-plus")
        let output = String(data: replaced.data, encoding: .utf8)

        #expect(replaced.replaced)
        #expect(output?.contains(thinkingBlock) == true)
        #expect(output == #"{"model":"qwen-plus","messages":[{"role":"assistant","content":[\#(thinkingBlock)]}]}"#)
    }

    @Test func replaceModelFieldReturnsUnchangedWhenModelMissing() {
        let source = #"{"messages":[{"role":"user","content":"hi"}]}"#
        let replaced = ProxyForwarder.replaceModelField(in: Data(source.utf8), with: "qwen-plus")

        #expect(replaced.replaced == false)
        #expect(replaced.data == Data(source.utf8))
        #expect(replaced.originalLength == replaced.newLength)
    }

    // MARK: - App launch smoke

    @Test func hostAppBundleHasExpectedIdentity() throws {
        let hostBundle = Bundle.main
        #expect(hostBundle.bundleIdentifier == "com.90percent.ModelProxy")
        #expect(hostBundle.bundleURL.lastPathComponent == "ModelProxy.app")

        let executableURL = try #require(hostBundle.executableURL)
        #expect(FileManager.default.fileExists(atPath: executableURL.path))
        #expect(executableURL.lastPathComponent == "ModelProxy")
    }

    // MARK: - Projection diagnostics

    @Test func summarizeRequestBodyCountsPortableRelevantBlocks() throws {
        let request = try JSONSerialization.data(withJSONObject: [
            "model": "claude-haiku-4-5-20251001",
            "thinking": ["type": "enabled", "budget_tokens": 32000],
            "messages": [
                [
                    "role": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "secret", "signature": "sig_1"],
                        ["type": "redacted_thinking", "data": "opaque"],
                        ["type": "text", "text": "Visible text"],
                        ["type": "tool_use", "id": "toolu_1", "name": "bash", "input": ["cmd": "git status"]],
                        ["type": "tool_result", "tool_use_id": "toolu_1", "content": "clean"]
                    ]
                ],
                ["role": "user", "content": "Ship it"]
            ]
        ], options: [.sortedKeys])

        let summary = try #require(ProxyForwarder.summarizeRequestBody(request))
        #expect(summary.messageCount == 2)
        #expect(summary.assistantMessageCount == 1)
        #expect(summary.arrayContentMessageCount == 1)
        #expect(summary.stringContentMessageCount == 1)
        #expect(summary.textBlockCount == 1)
        #expect(summary.thinkingBlockCount == 1)
        #expect(summary.signedThinkingBlockCount == 1)
        #expect(summary.redactedThinkingBlockCount == 1)
        #expect(summary.toolUseBlockCount == 1)
        #expect(summary.toolResultBlockCount == 1)
        #expect(summary.otherBlockCount == 0)
        #expect(summary.topLevelThinkingType == "enabled")
        #expect(summary.topLevelThinkingBudget == 32000)
    }
}
