import Foundation
import OSLog

protocol SessionLineageBrokering: Actor, Sendable {
    func prepareRequest(
        bodyData: Data,
        clientName: String,
        sessionScopeKey: String?,
        coordinationScopeKey: String?,
        target: RoutingSnapshot.RouteTarget
    ) throws -> PreparedRequest

    func commitResponse(
        context: PreparedBranchContext,
        assistantTurn: PortableAssistantTurn
    ) throws

    func branches(for clientName: String, sessionScopeKey: String?) -> [BranchTranscript]
}

extension SessionLineageBrokering {
    func prepareRequest(
        bodyData: Data,
        clientName: String,
        target: RoutingSnapshot.RouteTarget
    ) throws -> PreparedRequest {
        try prepareRequest(
            bodyData: bodyData,
            clientName: clientName,
            sessionScopeKey: nil,
            coordinationScopeKey: nil,
            target: target
        )
    }

    func prepareRequest(
        bodyData: Data,
        clientName: String,
        sessionScopeKey: String?,
        target: RoutingSnapshot.RouteTarget
    ) throws -> PreparedRequest {
        try prepareRequest(
            bodyData: bodyData,
            clientName: clientName,
            sessionScopeKey: sessionScopeKey,
            coordinationScopeKey: sessionScopeKey,
            target: target
        )
    }

    func branches(for clientName: String) -> [BranchTranscript] {
        branches(for: clientName, sessionScopeKey: nil)
    }
}

actor SessionLineageBroker: SessionLineageBrokering {
    private let projector: any TranscriptProjecting
    private let fingerprint: any ConversationFingerprinting
    private let store: any LineageStoring
    private var lineages: [String: ConversationLineage]
    // Keep enough recent conversations for active branch reuse without letting the on-disk
    // cache grow unbounded for a single client.
    private let maxCachedLineagesPerClient = 24

    init(
        projector: any TranscriptProjecting = TranscriptProjector(),
        fingerprint: any ConversationFingerprinting = ConversationFingerprint(),
        store: any LineageStoring = LineageStoreFactory.makeDefaultStore()
    ) {
        self.projector = projector
        self.fingerprint = fingerprint
        self.store = store
        do {
            self.lineages = try store.loadLineages()
        } catch {
            AppLog.proxy.error("[Proxy] [Lineage] failed to load persisted lineages; starting cold cache: \(String(describing: error))")
            self.lineages = [:]
        }
    }

    func prepareRequest(
        bodyData: Data,
        clientName: String,
        sessionScopeKey: String?,
        coordinationScopeKey: String?,
        target: RoutingSnapshot.RouteTarget
    ) throws -> PreparedRequest {
        let prepared = try projector.prepareRequest(
            bodyData: bodyData,
            clientName: clientName,
            sessionScopeKey: sessionScopeKey,
            coordinationScopeKey: coordinationScopeKey,
            target: target,
            existingBranches: branchCandidates(for: clientName, sessionScopeKey: sessionScopeKey),
            fingerprint: fingerprint
        )
        if let context = prepared.context {
            AppLog.proxy.debug(
                "[Proxy] [Lineage] client=\(context.clientName) session=\(context.sessionScopeKey ?? "none") coordination=\(context.coordinationScopeKey ?? "none") lineage=\(context.lineageKey) branch=\(context.branchKey) vendor=\(context.vendorKey) replay=\(context.replayPolicy.rawValue) reused=\(context.reusedBranchHistory) reusedPortable=\(context.reusedPortableMessageCount)"
            )
        }
        return prepared
    }

    func commitResponse(
        context: PreparedBranchContext,
        assistantTurn: PortableAssistantTurn
    ) throws {
        let fullMessagesData = try TranscriptProjector.appendMessage(
            assistantTurn.fullMessageData,
            to: context.preparedFullMessagesData
        )
        let portableMessagesData = try TranscriptProjector.appendMessage(
            assistantTurn.portableMessageData,
            to: context.preparedPortableMessagesData
        )
        let portableHash = fingerprint.sha256Hex(assistantTurn.portableMessageData)

        var lineage = lineages[context.lineageKey] ?? ConversationLineage(
            lineageKey: context.lineageKey,
            clientName: context.clientName,
            sessionScopeKey: context.sessionScopeKey,
            branches: [:],
            lastUpdatedAt: .now
        )
        lineage.branches[context.branchKey] = BranchTranscript(
            lineageKey: context.lineageKey,
            branchKey: context.branchKey,
            clientName: context.clientName,
            sessionScopeKey: context.sessionScopeKey,
            vendorKey: context.vendorKey,
            signingDomain: context.signingDomain,
            replayPolicy: context.replayPolicy,
            fullMessagesData: fullMessagesData,
            portableMessagesData: portableMessagesData,
            portableMessageHashes: context.preparedPortableMessageHashes + [portableHash],
            lastUpdatedAt: .now
        )
        lineage.lastUpdatedAt = .now
        var updatedLineages = lineages
        updatedLineages[context.lineageKey] = lineage
        trimLineages(for: context.clientName, in: &updatedLineages)
        try store.saveLineages(updatedLineages)
        lineages = updatedLineages
    }

    func branches(for clientName: String, sessionScopeKey: String?) -> [BranchTranscript] {
        lineages.values
            .flatMap { $0.branches.values }
            .filter { $0.clientName == clientName && $0.sessionScopeKey == sessionScopeKey }
    }

    private func branchCandidates(for clientName: String, sessionScopeKey: String?) -> [BranchTranscript] {
        let candidates = lineages.values
            .filter { $0.clientName == clientName }
            .flatMap { $0.branches.values }

        guard sessionScopeKey == nil else {
            return candidates.filter { $0.sessionScopeKey == sessionScopeKey }
        }
        return candidates.filter { branch in
            guard let branchSessionScopeKey = branch.sessionScopeKey else { return true }
            return branchSessionScopeKey.contains("|channel|")
        }
    }

    private func trimLineages(for clientName: String, in lineages: inout [String: ConversationLineage]) {
        let matchingKeys = lineages.values
            .filter { $0.clientName == clientName }
            .sorted { $0.lastUpdatedAt > $1.lastUpdatedAt }
            .map(\.lineageKey)

        guard matchingKeys.count > maxCachedLineagesPerClient else { return }
        for lineageKey in matchingKeys.dropFirst(maxCachedLineagesPerClient) {
            lineages.removeValue(forKey: lineageKey)
        }
    }
}
