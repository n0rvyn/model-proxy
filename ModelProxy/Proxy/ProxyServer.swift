import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import AsyncHTTPClient
import NIOHTTPCompression
import Observation
import OSLog

/// Manages one NIO listener per configured client port.
/// @MainActor: all state mutations happen on main thread for SwiftUI observers.
@MainActor
@Observable
final class ProxyServer {

    // MARK: - Observable State

    private(set) var isRunning: Bool = false
    /// True after user explicitly stops the proxy. Cleared on next start().
    private(set) var isStopped: Bool = false
    private(set) var lastError: String? = nil
    /// Ports currently bound, keyed by clientName for display.
    private(set) var boundPorts: [String: Int] = [:]
    /// Traffic log shared with all channel handlers.
    let trafficLog: TrafficLog = TrafficLog()
    /// Token stats store shared with all channel handlers.
    let tokenStatsStore: TokenStatsStore
    private let lineageBroker: any SessionLineageBrokering
    private let portableNormalizer: any PortableContentNormalizing
    private let requestCoordinator: any BranchRequestCoordinating
    private(set) var webSearchProvider: (any WebSearchBridgeProviding)?
    private(set) var webSearchForwardAsIs: Bool = false

    // MARK: - Init

    init(
        tokenStatsStore: TokenStatsStore,
        lineageBroker: any SessionLineageBrokering = SessionLineageBroker(store: LineageStoreFactory.makeDefaultStore()),
        portableNormalizer: any PortableContentNormalizing = PortableContentNormalizer(),
        requestCoordinator: any BranchRequestCoordinating = BranchRequestCoordinator()
    ) {
        self.tokenStatsStore = tokenStatsStore
        self.lineageBroker = lineageBroker
        self.portableNormalizer = portableNormalizer
        self.requestCoordinator = requestCoordinator
    }

    // MARK: - Internal State

    private struct ListenerSlot {
        let channel: any Channel
        let router: RequestRouter
        let clientName: String
    }

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var httpClient: HTTPClient?
    private var listeners: [ListenerSlot] = []

    // MARK: - Start

    /// Start one listener per client in `config`. Idempotent if already running.
    func start(config: AppConfig) async {
        guard !isRunning else { return }
        isStopped = false
        lastError = nil

        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.eventLoopGroup = group

        let clientConfig = HTTPClient.Configuration(
            redirectConfiguration: .disallow,
            timeout: .init(connect: .seconds(10)),
            decompression: .enabled(limit: .ratio(10))
        )
        let client = HTTPClient(eventLoopGroupProvider: .shared(group), configuration: clientConfig)
        self.httpClient = client
        self.webSearchProvider = WebSearchProviderFactory.make(from: config.webSearch)
        self.webSearchForwardAsIs = config.webSearch.provider == .forwardAsIs

        var slots: [ListenerSlot] = []
        var errors: [String] = []

        let trafficLog = self.trafficLog
        let tokenStatsStore = self.tokenStatsStore

        for clientCfg in config.clients {
            let snapshot = RoutingSnapshot(from: config, for: clientCfg)
            let router = RequestRouter(snapshot: snapshot)

            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 256)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                        channel.pipeline.addHandler(
                            ProxyChannelHandler(
                                clientName: clientCfg.clientName,
                                router: router,
                                httpClient: client,
                                trafficLog: trafficLog,
                                tokenStatsStore: tokenStatsStore,
                                lineageBroker: self.lineageBroker,
                                portableNormalizer: self.portableNormalizer,
                                requestCoordinator: self.requestCoordinator,
                                webSearchProvider: self.webSearchProvider,
                                webSearchForwardAsIs: self.webSearchForwardAsIs
                            )
                        )
                    }
                }
                .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

            do {
                let channel = try await bootstrap.bind(host: "127.0.0.1", port: clientCfg.port).get()
                let actualPort = channel.localAddress?.port ?? clientCfg.port
                AppLog.proxy.info("[ProxyServer] \(clientCfg.clientName) listening on 127.0.0.1:\(actualPort)")
                slots.append(ListenerSlot(channel: channel, router: router, clientName: clientCfg.clientName))
                boundPorts[clientCfg.clientName] = actualPort
            } catch let err as NIOCore.IOError where err.errnoCode == EADDRINUSE {
                errors.append("Port \(clientCfg.port) (\(clientCfg.clientName)) already in use.")
            } catch {
                errors.append("Failed to start \(clientCfg.clientName): \(error.localizedDescription)")
            }
        }

        self.listeners = slots

        if slots.isEmpty {
            // No listeners started — surface first error and clean up.
            self.lastError = errors.first ?? "No clients configured."
            try? await client.shutdown()
            try? await group.shutdownGracefully()
            self.httpClient = nil
            self.eventLoopGroup = nil
        } else {
            self.isRunning = true
            if !errors.isEmpty {
                // Partial start — surface warnings but remain running.
                self.lastError = errors.joined(separator: " ")
            }
        }
    }

    // MARK: - Stop

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        isStopped = true
        boundPorts = [:]

        for slot in listeners {
            try? await slot.channel.close().get()
        }
        listeners = []

        try? await httpClient?.shutdown()
        httpClient = nil

        try? await eventLoopGroup?.shutdownGracefully()
        eventLoopGroup = nil

        AppLog.proxy.info("[ProxyServer] Stopped.")
    }

    /// SF Symbol name for the menu bar icon. Adapts to light/dark via template rendering.
    /// States in priority order: not running → xmark.circle, partial error → exclamationmark.circle,
    /// normal → arrow.triangle.branch.
    var menuBarSymbol: String {
        guard isRunning else { return "xmark.circle" }
        if lastError != nil { return "exclamationmark.circle" }
        return "arrow.triangle.branch"
    }

    // MARK: - Hot Reload

    /// Push a new routing snapshot to all listeners that match by clientName.
    /// Called after ConfigStore.save(); does not restart any channel.
    func updateRouting(config: AppConfig) {
        self.webSearchProvider = WebSearchProviderFactory.make(from: config.webSearch)
        self.webSearchForwardAsIs = config.webSearch.provider == .forwardAsIs
        for slot in listeners {
            guard let clientCfg = config.clients.first(where: { $0.clientName == slot.clientName }) else {
                continue
            }
            let newSnapshot = RoutingSnapshot(from: config, for: clientCfg)
            Task {
                await slot.router.updateSnapshot(newSnapshot)
            }
        }
    }
}
