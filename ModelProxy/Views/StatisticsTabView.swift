import SwiftUI

struct StatisticsTabView: View {
    @Environment(TokenStatsStore.self) private var tokenStatsStore
    @Environment(ConfigStore.self) private var configStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow

            Divider()

            let rows = tokenStatsStore.tableRows
            if rows.isEmpty {
                emptyState
            } else {
                statsTable(rows: rows)
                savingsSummary
            }
        }
        .padding()
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack {
            Text("Statistics — \(tokenStatsStore.statsDate)")
                .font(.headline)
            Spacer()
            Text("Today: \(tokenStatsStore.todayTotalTokens.compactTokenString) tokens")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No token usage recorded today")
                .font(.body)
                .foregroundStyle(.secondary)
            Text("Token counts appear after the first proxied request.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // MARK: - Stats Table

    @ViewBuilder
    private func statsTable(
        rows: [(vendorID: UUID, model: String, record: ModelTokenRecord)]
    ) -> some View {
        let mappings = configStore.config.modelMappings
        let overrides = configStore.config.modelPricingOverrides

        ScrollView {
            VStack(spacing: 0) {
                // Column headers
                HStack {
                    Text("Model")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Input")
                        .frame(width: 60, alignment: .trailing)
                    Text("Output")
                        .frame(width: 60, alignment: .trailing)
                    Text("Total")
                        .frame(width: 60, alignment: .trailing)
                    Text("Cost")
                        .frame(width: 60, alignment: .trailing)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)

                Divider()

                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let sourceModel = mappings.first(where: { $0.targetModel == row.model })?.sourceModel
                    let price = ModelPrice.lookup(row.model, overrides: overrides)
                    let cost = price?.cost(input: row.record.inputTokens, output: row.record.outputTokens)

                    HStack {
                        // Model column: "source → target" for mapped, plain name for passthrough
                        if let sourceModel {
                            HStack(spacing: 2) {
                                Text(sourceModel)
                                    .foregroundStyle(.secondary)
                                Text("→")
                                    .foregroundStyle(.tertiary)
                                Text(row.model)
                            }
                            .font(.body)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(row.model)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Text(row.record.inputTokens.compactTokenString)
                            .font(.body.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                        Text(row.record.outputTokens.compactTokenString)
                            .font(.body.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                        Text((row.record.inputTokens + row.record.outputTokens).compactTokenString)
                            .font(.body.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                        Text(costText(cost))
                            .font(.body.monospacedDigit())
                            .frame(width: 60, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    .padding(.horizontal, 4)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(sourceModel.map { "\($0) to " } ?? "")\(row.model): \(row.record.inputTokens.compactTokenString) input, \(row.record.outputTokens.compactTokenString) output, cost \(costText(cost))")

                    Divider()
                }
            }
        }
    }

    private func costText(_ cost: Double?) -> String {
        guard let cost else { return "—" }
        if cost < 0.01 { return cost > 0 ? "<$0.01" : "$0.00" }
        return String(format: "$%.2f", cost)
    }

    // MARK: - Savings Summary

    @ViewBuilder
    private var savingsSummary: some View {
        let savings = computeSavings()
        if savings > 0.001 {
            Divider()
            HStack {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
                Text("Estimated savings today: $\(savings, specifier: "%.2f")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 4)
        }
    }

    private func computeSavings() -> Double {
        let overrides = configStore.config.modelPricingOverrides
        let mappings = configStore.config.modelMappings
        let sourceRecords = tokenStatsStore.stats.sourceModelRecords

        var totalSavings = 0.0
        for (sourceModel, record) in sourceRecords {
            guard let sourcePrice = ModelPrice.lookup(sourceModel, overrides: overrides) else { continue }
            guard let mapping = mappings.first(where: { $0.sourceModel == sourceModel }) else { continue }
            guard let targetPrice = ModelPrice.lookup(mapping.targetModel, overrides: overrides) else { continue }

            let sourceCost = sourcePrice.cost(input: record.inputTokens, output: record.outputTokens)
            let targetCost = targetPrice.cost(input: record.inputTokens, output: record.outputTokens)
            totalSavings += max(0, sourceCost - targetCost)
        }
        return totalSavings
    }
}

#Preview {
    StatisticsTabView()
        .environment(TokenStatsStore())
        .environment(ConfigStore())
        .frame(width: 520, height: 400)
}
