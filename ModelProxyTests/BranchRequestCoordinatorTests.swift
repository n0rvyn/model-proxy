import Testing
import Foundation
@testable import ModelProxy

struct BranchRequestCoordinatorTests {

    @Test func exactDuplicateRequestReplaysLeaderResponse() async throws {
        let coordinator = BranchRequestCoordinator()
        let context = makeContext(hashes: ["m1", "m2"])

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
            bodyChunks: [Data("{\"ok\":true}".utf8)]
        )
        await coordinator.complete(lease: leaderLease, replay: replay)

        let followerDecision = await followerTask.value
        switch followerDecision {
        case .replay(let cachedResponse, let source):
            #expect(source == leaderLease)
            #expect(cachedResponse.statusCode == replay.statusCode)
            #expect(cachedResponse.bodyChunks == replay.bodyChunks)
            #expect(cachedResponse.headers.contains { $0.0 == "content-type" && $0.1 == "application/json" })
        default:
            Issue.record("Expected replay decision"); throw TestAbort()
        }
    }

    @Test func successorRequestWaitsThenAcquiresNewGeneration() async throws {
        let coordinator = BranchRequestCoordinator()
        let leaderContext = makeContext(hashes: ["m1", "m2"])
        let successorContext = makeContext(hashes: ["m1", "m2", "m3"])

        let leaderDecision = await coordinator.acquire(context: leaderContext)
        let leaderLease = switch leaderDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected leader lease acquisition"); throw TestAbort()
        }

        let successorTask = Task {
            await coordinator.acquire(context: successorContext)
        }
        await Task.yield()

        await coordinator.complete(lease: leaderLease, replay: nil)

        let waitedDecision = await successorTask.value
        switch waitedDecision {
        case .waited(let source):
            #expect(source == leaderLease)
        default:
            Issue.record("Expected waited decision"); throw TestAbort()
        }

        let successorDecision = await coordinator.acquire(context: successorContext)
        let successorLease = switch successorDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected successor acquisition after wait"); throw TestAbort()
        }
        #expect(successorLease.generation == leaderLease.generation + 1)
    }

    @Test func successorRequestReceivesLeaderFailureInsteadOfAcquiringAfterUpstreamError() async throws {
        let coordinator = BranchRequestCoordinator()
        let leaderContext = makeContext(hashes: ["m1", "m2"])
        let successorContext = makeContext(hashes: ["m1", "m2", "m3"])

        let leaderDecision = await coordinator.acquire(context: leaderContext)
        let leaderLease = switch leaderDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected leader lease acquisition"); throw TestAbort()
        }

        let successorTask = Task {
            await coordinator.acquire(context: successorContext)
        }
        await Task.yield()

        let upstreamError = ReplayableBranchResponse(
            statusCode: 400,
            headers: [("content-type", "application/json")],
            bodyChunks: [Data("{\"error\":\"invalid params\"}".utf8)]
        )
        await coordinator.complete(lease: leaderLease, replay: upstreamError)

        let followerDecision = await successorTask.value
        switch followerDecision {
        case .leaderFailed(let source, let replay):
            #expect(source == leaderLease)
            #expect(replay?.statusCode == upstreamError.statusCode)
            #expect(replay?.bodyChunks == upstreamError.bodyChunks)
        default:
            Issue.record("Expected leaderFailed decision"); throw TestAbort()
        }
    }

    @Test func staleGenerationFailsCommitCheckAfterNewerAcquire() async throws {
        let coordinator = BranchRequestCoordinator()
        let context = makeContext(hashes: ["m1"])

        let firstDecision = await coordinator.acquire(context: context)
        let firstLease = switch firstDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw TestAbort()
        }
        #expect(await coordinator.shouldCommit(lease: firstLease) == true)

        await coordinator.complete(lease: firstLease, replay: nil)

        let secondDecision = await coordinator.acquire(context: context)
        let secondLease = switch secondDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected second lease acquisition"); throw TestAbort()
        }

        #expect(await coordinator.shouldCommit(lease: firstLease) == false)
        #expect(await coordinator.shouldCommit(lease: secondLease) == true)
    }

    @Test func samePortableHashesFromDifferentClientsDoNotBlockEachOther() async throws {
        let coordinator = BranchRequestCoordinator()
        let claudeContext = makeContext(clientName: "Claude Code", hashes: ["m1", "m2"])
        let codexContext = makeContext(clientName: "Codex", hashes: ["m1", "m2"])

        let claudeDecision = await coordinator.acquire(context: claudeContext)
        let claudeLease = switch claudeDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected Claude lease acquisition"); throw TestAbort()
        }

        let codexDecision = await coordinator.acquire(context: codexContext)
        let codexLease = switch codexDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected Codex lease acquisition"); throw TestAbort()
        }

        #expect(claudeLease.clientName != codexLease.clientName)
        #expect(codexLease.generation == 1)

        await coordinator.complete(lease: claudeLease, replay: nil)
        await coordinator.complete(lease: codexLease, replay: nil)
    }

    @Test func samePortableHashesFromDifferentSessionScopesDoNotBlockEachOther() async throws {
        let coordinator = BranchRequestCoordinator()
        let sessionAContext = makeContext(sessionScopeKey: "session-a", hashes: ["m1", "m2"])
        let sessionBContext = makeContext(sessionScopeKey: "session-b", hashes: ["m1", "m2"])

        let firstDecision = await coordinator.acquire(context: sessionAContext)
        let firstLease = switch firstDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw TestAbort()
        }

        let secondDecision = await coordinator.acquire(context: sessionBContext)
        let secondLease = switch secondDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected second lease acquisition"); throw TestAbort()
        }

        #expect(firstLease.sessionScopeKey == "session-a")
        #expect(secondLease.sessionScopeKey == "session-b")
        #expect(secondLease.generation == 1)

        await coordinator.complete(lease: firstLease, replay: nil)
        await coordinator.complete(lease: secondLease, replay: nil)
    }

    @Test func samePortableHashesFromDifferentCoordinationScopesDoNotBlockEachOther() async throws {
        let coordinator = BranchRequestCoordinator()
        let channelAContext = makeContext(coordinationScopeKey: "Claude Code|channel|a", hashes: ["m1", "m2"])
        let channelBContext = makeContext(coordinationScopeKey: "Claude Code|channel|b", hashes: ["m1", "m2"])

        let firstDecision = await coordinator.acquire(context: channelAContext)
        let firstLease = switch firstDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw TestAbort()
        }

        let secondDecision = await coordinator.acquire(context: channelBContext)
        let secondLease = switch secondDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected second lease acquisition"); throw TestAbort()
        }

        #expect(firstLease.sessionScopeKey == nil)
        #expect(firstLease.coordinationScopeKey == "Claude Code|channel|a")
        #expect(secondLease.coordinationScopeKey == "Claude Code|channel|b")
        #expect(secondLease.generation == 1)

        await coordinator.complete(lease: firstLease, replay: nil)
        await coordinator.complete(lease: secondLease, replay: nil)
    }

    @Test func replayResponseHeadersCanBeAssertedWithoutOrderSensitivity() async throws {
        let coordinator = BranchRequestCoordinator()
        let context = makeContext(hashes: ["m1"])

        let firstDecision = await coordinator.acquire(context: context)
        let leaderLease = switch firstDecision {
        case .acquired(let lease): lease
        default: Issue.record("Expected first lease acquisition"); throw TestAbort()
        }

        let followerTask = Task {
            await coordinator.acquire(context: context)
        }
        await Task.yield()

        let replay = ReplayableBranchResponse(
            statusCode: 200,
            headers: [("x-request-id", "123"), ("content-type", "application/json")],
            bodyChunks: [Data("{}".utf8)]
        )
        await coordinator.complete(lease: leaderLease, replay: replay)

        let followerDecision = await followerTask.value
        switch followerDecision {
        case .replay(let cachedResponse, _):
            let headerMap = Dictionary(grouping: cachedResponse.headers, by: { $0.0.lowercased() }).mapValues { pairs in
                pairs.map(\.1)
            }
            #expect(headerMap["content-type"] == ["application/json"])
            #expect(headerMap["x-request-id"] == ["123"])
        default:
            Issue.record("Expected replay decision"); throw TestAbort()
        }
    }
}

private func makeContext(
    clientName: String = "Claude Code",
    sessionScopeKey: String? = nil,
    coordinationScopeKey: String? = nil,
    hashes: [String]
) -> PreparedBranchContext {
    PreparedBranchContext(
        lineageKey: "lineage-1",
        branchKey: "branch-1",
        clientName: clientName,
        sessionScopeKey: sessionScopeKey,
        coordinationScopeKey: coordinationScopeKey,
        vendorKey: "vendor-qwen",
        signingDomain: .compatibleThirdParty,
        replayPolicy: .portableOnly,
        preparedFullMessagesData: Data("[]".utf8),
        preparedPortableMessagesData: Data("[]".utf8),
        preparedPortableMessageHashes: hashes,
        reusedBranchHistory: false,
        reusedPortableMessageCount: 0
    )
}

private struct TestAbort: Error {}
