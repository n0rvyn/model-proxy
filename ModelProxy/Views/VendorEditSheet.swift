import SwiftUI

/// Sheet for adding a new vendor or editing an existing one.
struct VendorEditSheet: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    @Environment(\.dismiss) private var dismiss

    /// nil = adding new; non-nil = editing existing (matched by id)
    let editingVendorID: UUID?

    @State private var name: String = ""
    @State private var baseURL: String = ""
    @State private var apiKey: String = ""
    @State private var showAPIKey: Bool = false
    @State private var connectTimeoutSeconds: Int = 10
    @State private var readTimeoutSeconds: Int = 120
    @State private var compatibleClientID: UUID?
    @State private var supportedModels: [String] = [""]
    @State private var modelInputPrices: [Int: String] = [:]
    @State private var modelOutputPrices: [Int: String] = [:]
    @State private var signingDomain: SigningDomain = .compatibleThirdParty
    @State private var replayPolicy: TranscriptReplayPolicy = .portableOnly

    private var isEditing: Bool { editingVendorID != nil }
    private var title: String { isEditing ? "Edit Vendor" : "Add Vendor" }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Vendor Details") {
                    TextField("Name", text: $name)
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()

                    HStack {
                        if showAPIKey {
                            TextField("API Key", text: $apiKey)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("API Key", text: $apiKey)
                        }
                        Button(showAPIKey ? "Hide" : "Reveal") {
                            showAPIKey.toggle()
                        }
                        .buttonStyle(.mpInline)
                        .accessibilityLabel(showAPIKey ? "Hide API Key" : "Reveal API Key")
                    }

                    Picker("Compatible Client", selection: $compatibleClientID) {
                        Text("All Clients").tag(UUID?.none)
                        ForEach(configStore.config.clients) { client in
                            Text(client.clientName).tag(UUID?.some(client.id))
                        }
                    }

                    Picker("Signing Domain", selection: $signingDomain) {
                        ForEach(SigningDomain.allCases, id: \.self) { domain in
                            Text(domain.displayName).tag(domain)
                        }
                    }

                    Picker("Replay Policy", selection: $replayPolicy) {
                        ForEach(TranscriptReplayPolicy.allCases, id: \.self) { policy in
                            Text(policy.displayName).tag(policy)
                        }
                    }
                }

                Section {
                    // Column headers
                    HStack {
                        Text("Model")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("In $/M")
                            .frame(width: 46, alignment: .trailing)
                        Text("Out $/M")
                            .frame(width: 46, alignment: .trailing)
                        Color.clear.frame(width: 24)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    ForEach(Array(supportedModels.indices), id: \.self) { index in
                        HStack {
                            TextField("Model name", text: Binding(
                                get: { supportedModels[index] },
                                set: { supportedModels[index] = $0 }
                            ))
                            .autocorrectionDisabled()

                            TextField(
                                modelPricePlaceholder(for: index, isInput: true),
                                text: Binding(
                                    get: { modelInputPrices[index] ?? "" },
                                    set: { modelInputPrices[index] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 46)
                            .multilineTextAlignment(.trailing)
                            .font(.caption.monospacedDigit())
                            .labelsHidden()

                            TextField(
                                modelPricePlaceholder(for: index, isOutput: true),
                                text: Binding(
                                    get: { modelOutputPrices[index] ?? "" },
                                    set: { modelOutputPrices[index] = $0 }
                                )
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 46)
                            .multilineTextAlignment(.trailing)
                            .font(.caption.monospacedDigit())
                            .labelsHidden()

                            Button {
                                removeSupportedModel(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove Supported Model")
                        }
                    }

                    Button {
                        supportedModels.append("")
                    } label: {
                        Label("Add Model", systemImage: "plus")
                    }
                    .buttonStyle(.mpInline)
                    .accessibilityLabel("Add Supported Model")
                } header: {
                    Text("Supported Models")
                }

                Section("Timeouts (seconds)") {
                    Stepper("Connect: \(connectTimeoutSeconds)s", value: $connectTimeoutSeconds, in: 1...120)
                    Stepper("Read: \(readTimeoutSeconds)s", value: $readTimeoutSeconds, in: 10...600)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.mpCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Cancel")
                Button(isEditing ? "Save" : "Add") {
                    commitVendor()
                    dismiss()
                }
                .buttonStyle(.mpPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespaces).isEmpty
                    || baseURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || URL(string: baseURL.trimmingCharacters(in: .whitespaces))?.scheme == nil
                )
                .accessibilityLabel(isEditing ? "Save Vendor" : "Add Vendor")
            }
            .padding()
        }
        .frame(width: 420)
        .onAppear {
            if let vid = editingVendorID,
               let vendor = configStore.config.vendors.first(where: { $0.id == vid }) {
                name = vendor.name
                baseURL = vendor.baseURL
                apiKey = vendor.apiKey
                connectTimeoutSeconds = vendor.connectTimeoutSeconds
                readTimeoutSeconds = vendor.readTimeoutSeconds
                compatibleClientID = vendor.compatibleClientID
                supportedModels = vendor.supportedModels.isEmpty ? [""] : vendor.supportedModels
                initializeModelPrices()
                signingDomain = vendor.signingDomain
                replayPolicy = vendor.replayPolicy
            }
        }
    }

    private func commitVendor() {
        let normalizedSupportedModels = normalizedSupportedModels()
        if let vid = editingVendorID,
           let idx = configStore.config.vendors.firstIndex(where: { $0.id == vid }) {
            configStore.config.vendors[idx].name = name
            configStore.config.vendors[idx].baseURL = baseURL
            configStore.config.vendors[idx].apiKey = apiKey
            configStore.config.vendors[idx].connectTimeoutSeconds = connectTimeoutSeconds
            configStore.config.vendors[idx].readTimeoutSeconds = readTimeoutSeconds
            configStore.config.vendors[idx].compatibleClientID = compatibleClientID
            configStore.config.vendors[idx].supportedModels = normalizedSupportedModels
            configStore.config.vendors[idx].signingDomain = signingDomain
            configStore.config.vendors[idx].replayPolicy = replayPolicy
        } else {
            let v = Vendor(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                connectTimeoutSeconds: connectTimeoutSeconds,
                readTimeoutSeconds: readTimeoutSeconds,
                compatibleClientID: compatibleClientID,
                supportedModels: normalizedSupportedModels,
                signingDomain: signingDomain,
                replayPolicy: replayPolicy
            )
            configStore.config.vendors.append(v)
        }
        commitModelPrices()
        configStore.saveAndReload(proxyServer: proxyServer)
    }

    private func modelPricePlaceholder(for index: Int, isInput: Bool = false, isOutput: Bool = false) -> String {
        let modelName = supportedModels[index].trimmingCharacters(in: .whitespaces)
        guard !modelName.isEmpty else { return isInput ? "In" : "Out" }
        guard let builtIn = ModelPrice.builtInDefaults
            .filter({ modelName.hasPrefix($0.prefix) })
            .max(by: { $0.prefix.count < $1.prefix.count })?
            .price else { return isInput ? "In" : "Out" }
        return String(format: "%.2f", isInput ? builtIn.inputPerMillion : builtIn.outputPerMillion)
    }

    private func initializeModelPrices() {
        let overrides = configStore.config.modelPricingOverrides
        for (index, modelName) in supportedModels.enumerated() {
            let trimmed = modelName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let price = overrides[trimmed] {
                modelInputPrices[index] = String(format: "%.2f", price.inputPerMillion)
                modelOutputPrices[index] = String(format: "%.2f", price.outputPerMillion)
            }
        }
    }

    private func commitModelPrices() {
        for (index, modelName) in normalizedSupportedModels().enumerated() {
            guard let inputStr = modelInputPrices[index], let inputVal = Double(inputStr),
                  let outputStr = modelOutputPrices[index], let outputVal = Double(outputStr) else {
                continue
            }
            let price = ModelPrice(inputPerMillion: inputVal, outputPerMillion: outputVal)
            // Skip if it matches built-in default exactly.
            let builtIn = ModelPrice.builtInDefaults
                .filter { modelName.hasPrefix($0.prefix) }
                .max { $0.prefix.count < $1.prefix.count }?
                .price
            if price == builtIn {
                configStore.config.modelPricingOverrides.removeValue(forKey: modelName)
            } else {
                configStore.config.modelPricingOverrides[modelName] = price
            }
        }
    }

    private func removeSupportedModel(at index: Int) {
        guard supportedModels.indices.contains(index) else { return }
        supportedModels.remove(at: index)
        if supportedModels.isEmpty {
            supportedModels = [""]
        }
    }

    private func normalizedSupportedModels() -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for model in supportedModels {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }
}

private extension SigningDomain {
    var displayName: String {
        switch self {
        case .anthropicOfficial:
            return "Anthropic API"
        case .bedrockAnthropic:
            return "Bedrock Anthropic"
        case .vertexAnthropic:
            return "Vertex Anthropic"
        case .compatibleThirdParty:
            return "Compatible Third-Party"
        }
    }
}

private extension TranscriptReplayPolicy {
    var displayName: String {
        switch self {
        case .transparent:
            return "Transparent Replay"
        case .portableOnly:
            return "Portable Blocks Only"
        }
    }
}
