import Foundation

struct BranchTranscript: Codable, Sendable {
    let lineageKey: String
    let branchKey: String
    let clientName: String
    let sessionScopeKey: String?
    let vendorKey: String
    let signingDomain: SigningDomain
    let replayPolicy: TranscriptReplayPolicy
    var fullMessagesData: Data
    var portableMessagesData: Data
    var portableMessageHashes: [String]
    var lastUpdatedAt: Date

    init(
        lineageKey: String,
        branchKey: String,
        clientName: String,
        sessionScopeKey: String? = nil,
        vendorKey: String,
        signingDomain: SigningDomain,
        replayPolicy: TranscriptReplayPolicy,
        fullMessagesData: Data,
        portableMessagesData: Data,
        portableMessageHashes: [String],
        lastUpdatedAt: Date
    ) {
        self.lineageKey = lineageKey
        self.branchKey = branchKey
        self.clientName = clientName
        self.sessionScopeKey = sessionScopeKey
        self.vendorKey = vendorKey
        self.signingDomain = signingDomain
        self.replayPolicy = replayPolicy
        self.fullMessagesData = fullMessagesData
        self.portableMessagesData = portableMessagesData
        self.portableMessageHashes = portableMessageHashes
        self.lastUpdatedAt = lastUpdatedAt
    }
}

struct ConversationLineage: Codable, Sendable {
    let lineageKey: String
    let clientName: String
    let sessionScopeKey: String?
    var branches: [String: BranchTranscript]
    var lastUpdatedAt: Date

    init(
        lineageKey: String,
        clientName: String,
        sessionScopeKey: String? = nil,
        branches: [String: BranchTranscript],
        lastUpdatedAt: Date
    ) {
        self.lineageKey = lineageKey
        self.clientName = clientName
        self.sessionScopeKey = sessionScopeKey
        self.branches = branches
        self.lastUpdatedAt = lastUpdatedAt
    }
}

struct PreparedBranchContext: Sendable {
    let lineageKey: String
    let branchKey: String
    let clientName: String
    let sessionScopeKey: String?
    let vendorKey: String
    let signingDomain: SigningDomain
    let replayPolicy: TranscriptReplayPolicy
    let preparedFullMessagesData: Data
    let preparedPortableMessagesData: Data
    let preparedPortableMessageHashes: [String]
    let reusedBranchHistory: Bool
    let reusedPortableMessageCount: Int

    init(
        lineageKey: String,
        branchKey: String,
        clientName: String,
        sessionScopeKey: String? = nil,
        vendorKey: String,
        signingDomain: SigningDomain,
        replayPolicy: TranscriptReplayPolicy,
        preparedFullMessagesData: Data,
        preparedPortableMessagesData: Data,
        preparedPortableMessageHashes: [String],
        reusedBranchHistory: Bool,
        reusedPortableMessageCount: Int
    ) {
        self.lineageKey = lineageKey
        self.branchKey = branchKey
        self.clientName = clientName
        self.sessionScopeKey = sessionScopeKey
        self.vendorKey = vendorKey
        self.signingDomain = signingDomain
        self.replayPolicy = replayPolicy
        self.preparedFullMessagesData = preparedFullMessagesData
        self.preparedPortableMessagesData = preparedPortableMessagesData
        self.preparedPortableMessageHashes = preparedPortableMessageHashes
        self.reusedBranchHistory = reusedBranchHistory
        self.reusedPortableMessageCount = reusedPortableMessageCount
    }
}

struct PreparedRequest: Sendable {
    let bodyData: Data
    let context: PreparedBranchContext?
    let projectedPortableMessagesData: Data?
}

struct PortableAssistantTurn: Sendable {
    let fullMessageData: Data
    let portableMessageData: Data
}
