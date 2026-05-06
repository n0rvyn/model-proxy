import Foundation

/// A single global model routing rule.
/// Maps one Anthropic source model to a vendor-specific target model.
/// Global across all clients — routing rules do not differ by tool.
struct ModelMapping: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    /// Anthropic model ID to match exactly, e.g. "claude-haiku-4-5".
    var sourceModel: String
    /// Vendor-specific model name to substitute, e.g. "qwen-turbo".
    var targetModel: String
    /// UUID of the Vendor to route to.
    var targetVendorID: UUID
    /// Backup vendor-specific model name for failover.
    var backupTargetModel: String?
    /// UUID of the backup Vendor for failover.
    var backupTargetVendorID: UUID?
    /// Whether this routing rule participates in runtime routing.
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        sourceModel: String,
        targetModel: String,
        targetVendorID: UUID,
        backupTargetModel: String? = nil,
        backupTargetVendorID: UUID? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.sourceModel = sourceModel
        self.targetModel = targetModel
        self.targetVendorID = targetVendorID
        self.backupTargetModel = backupTargetModel
        self.backupTargetVendorID = backupTargetVendorID
        self.isEnabled = isEnabled
    }

    // MARK: - Codable (legacy-tolerant)

    enum CodingKeys: String, CodingKey {
        case id, sourceModel, targetModel, targetVendorID
        case backupTargetModel, backupTargetVendorID, isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceModel = try c.decode(String.self, forKey: .sourceModel)
        targetModel = try c.decode(String.self, forKey: .targetModel)
        targetVendorID = try c.decode(UUID.self, forKey: .targetVendorID)
        backupTargetModel = try? c.decode(String.self, forKey: .backupTargetModel)
        backupTargetVendorID = try? c.decode(UUID.self, forKey: .backupTargetVendorID)
        if c.contains(.isEnabled) {
            isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        } else {
            isEnabled = true
        }
    }
}

enum ModelMappingActivation {
    static func setEnabled(_ isEnabled: Bool, for id: UUID, in mappings: inout [ModelMapping]) {
        guard let index = mappings.firstIndex(where: { $0.id == id }) else { return }
        mappings[index].isEnabled = isEnabled
        guard isEnabled else { return }
        enforceSingleEnabledSource(for: id, in: &mappings)
    }

    static func enforceSingleEnabledSource(for id: UUID, in mappings: inout [ModelMapping]) {
        guard let index = mappings.firstIndex(where: { $0.id == id }),
              mappings[index].isEnabled else { return }
        let sourceModel = mappings[index].sourceModel.trimmingCharacters(in: .whitespaces)
        for mappingIndex in mappings.indices where mappings[mappingIndex].id != id {
            if mappings[mappingIndex].sourceModel.trimmingCharacters(in: .whitespaces) == sourceModel {
                mappings[mappingIndex].isEnabled = false
            }
        }
    }
}
