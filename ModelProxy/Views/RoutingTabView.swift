import SwiftUI

struct RoutingTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAddRow: Bool = false

    private var observedModels: [String] {
        KnownAnthropicModels.observedSuggestions(from: proxyServer.trafficLog.entries.map(\.model))
    }

    var body: some View {
        Form {
            Section {
                if configStore.config.modelMappings.isEmpty && !showAddRow {
                    Text("No routing rules. Add one to redirect models to other vendors.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)
                }

                ForEach(configStore.config.modelMappings) { mapping in
                    MappingRow(mapping: mapping, observedModels: observedModels)
                        .environment(configStore)
                        .environment(proxyServer)
                }

                if showAddRow {
                    AddMappingRow(
                        observedModels: observedModels,
                        onAdd: { newMapping in
                            configStore.config.modelMappings.append(newMapping)
                            ModelMappingActivation.enforceSingleEnabledSource(for: newMapping.id, in: &configStore.config.modelMappings)
                            configStore.saveAndReload(proxyServer: proxyServer)
                            showAddRow = false
                        },
                        onCancel: { showAddRow = false }
                    )
                    .environment(configStore)
                }

            } header: {
                HStack {
                    Text("Model Routing Rules")
                    Spacer()
                    Button("Add Rule") { showAddRow = true }
                        .buttonStyle(.mpInline)
                        .disabled(showAddRow || configStore.config.vendors.isEmpty)
                        .accessibilityLabel("Add Routing Rule")
                }
            } footer: {
                if configStore.config.vendors.isEmpty {
                    Text("Add at least one vendor in the Vendors tab before creating routing rules.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct MappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let mapping: ModelMapping
    let observedModels: [String]

    @State private var isEditing = false
    @State private var showDeleteConfirmation = false
    @State private var editSourceModel = ""
    @State private var editTargetModel = ""
    @State private var editVendorID: UUID?
    @State private var editBackupTargetModel = ""
    @State private var editBackupVendorID: UUID?
    @State private var showBackupFields = false

    private var vendorName: String {
        configStore.config.vendors.first(where: { $0.id == mapping.targetVendorID })?.name ?? "Unknown vendor"
    }

    private var currentIsEnabled: Bool {
        configStore.config.modelMappings.first(where: { $0.id == mapping.id })?.isEnabled ?? mapping.isEnabled
    }

    private func roleBadge(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(title)
            Image(systemName: icon)
                .imageScale(.small)
        }
        .font(.caption)
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
    }

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 8) {
                SourceModelField(text: $editSourceModel, observedModels: observedModels)
                VendorMenuField(
                    placeholder: "Target vendor",
                    selection: $editVendorID,
                    vendors: configStore.config.vendors,
                    clients: configStore.config.clients
                )
                VendorModelField(
                    placeholder: "Target model (vendor model name)",
                    text: $editTargetModel,
                    vendorSelection: $editVendorID,
                    vendors: configStore.config.vendors
                )

                if showBackupFields {
                    Divider()
                    Text("Backup Target")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VendorMenuField(
                        placeholder: "Backup vendor",
                        selection: $editBackupVendorID,
                        vendors: configStore.config.vendors,
                        clients: configStore.config.clients
                    )
                    VendorModelField(
                        placeholder: "Backup model (vendor model name)",
                        text: $editBackupTargetModel,
                        vendorSelection: $editBackupVendorID,
                        vendors: configStore.config.vendors
                    )
                }

                HStack {
                    Spacer()
                    if showBackupFields {
                        Button("Remove Backup") {
                            showBackupFields = false
                            editBackupTargetModel = ""
                            editBackupVendorID = nil
                        }
                        .buttonStyle(.mpDestructive)
                    } else {
                        Button("Add Backup Target") {
                            showBackupFields = true
                        }
                        .buttonStyle(.mpCancel)
                    }
                    Button("Cancel") { isEditing = false }
                        .buttonStyle(.mpCancel)
                    Button("Save") {
                        let trimmedSource = editSourceModel.trimmingCharacters(in: .whitespaces)
                        guard let index = configStore.config.modelMappings.firstIndex(where: { $0.id == mapping.id }),
                              !trimmedSource.isEmpty,
                              !editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                              let vendorID = editVendorID else { return }
                        configStore.config.modelMappings[index].sourceModel = trimmedSource
                        configStore.config.modelMappings[index].targetModel = editTargetModel.trimmingCharacters(in: .whitespaces)
                        configStore.config.modelMappings[index].targetVendorID = vendorID
                        if showBackupFields,
                           !editBackupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                           let backupVendorID = editBackupVendorID {
                            configStore.config.modelMappings[index].backupTargetModel = editBackupTargetModel.trimmingCharacters(in: .whitespaces)
                            configStore.config.modelMappings[index].backupTargetVendorID = backupVendorID
                        } else {
                            configStore.config.modelMappings[index].backupTargetModel = nil
                            configStore.config.modelMappings[index].backupTargetVendorID = nil
                        }
                        if configStore.config.modelMappings[index].isEnabled {
                            ModelMappingActivation.enforceSingleEnabledSource(for: mapping.id, in: &configStore.config.modelMappings)
                        }
                        configStore.saveAndReload(proxyServer: proxyServer)
                        isEditing = false
                    }
                    .buttonStyle(.mpPrimary)
                    .disabled(
                        editSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                        editTargetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                        editVendorID == nil ||
                        (showBackupFields && (editBackupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty || editBackupVendorID == nil))
                    )
                }
            }
            .padding(.vertical, 4)
            .onChange(of: editVendorID) { newVendorID in
                guard editTargetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let vendor = configStore.config.vendors.first(where: { $0.id == newVendorID }),
                      let firstModel = vendor.supportedModels.first else { return }
                editTargetModel = firstModel
            }
            .onChange(of: editBackupVendorID) { newVendorID in
                guard editBackupTargetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let vendor = configStore.config.vendors.first(where: { $0.id == newVendorID }),
                      let firstModel = vendor.supportedModels.first else { return }
                editBackupTargetModel = firstModel
            }
        } else {
            HStack {
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { currentIsEnabled },
                        set: { isEnabled in
                            ModelMappingActivation.setEnabled(isEnabled, for: mapping.id, in: &configStore.config.modelMappings)
                            configStore.saveAndReload(proxyServer: proxyServer)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Enable routing rule")
                .accessibilityLabel("Enable rule for \(mapping.sourceModel)")

                HStack {
                    Text(mapping.sourceModel)
                        .font(.system(.body, design: .monospaced))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        if mapping.backupTargetVendorID == nil {
                            Text(mapping.targetModel)
                                .font(.system(.body, design: .monospaced))
                        }
                        HStack(spacing: 4) {
                            if mapping.backupTargetVendorID != nil {
                                Text(mapping.targetModel)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Text(vendorName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if mapping.backupTargetVendorID != nil {
                                roleBadge("Primary", icon: "checkmark.circle.fill", color: .blue)
                            }
                        }
                        if let backupVendorID = mapping.backupTargetVendorID {
                            HStack(spacing: 4) {
                                Text(mapping.backupTargetModel ?? mapping.targetModel)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(configStore.config.vendors.first(where: { $0.id == backupVendorID })?.name ?? "Unknown")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                roleBadge("Backup", icon: "arrow.clockwise.circle.fill", color: .secondary)
                            }
                        }
                    }
                }
                .opacity(currentIsEnabled ? 1 : 0.55)
                Spacer()
                Button("Edit") {
                    editSourceModel = mapping.sourceModel
                    editTargetModel = mapping.targetModel
                    editVendorID = mapping.targetVendorID
                    editBackupTargetModel = mapping.backupTargetModel ?? ""
                    editBackupVendorID = mapping.backupTargetVendorID
                    showBackupFields = mapping.backupTargetVendorID != nil
                    isEditing = true
                }
                .buttonStyle(.mpInline)
                .accessibilityLabel("Edit rule for \(mapping.sourceModel)")
                Button("Delete") {
                    showDeleteConfirmation = true
                }
                .buttonStyle(.mpDestructive)
                .accessibilityLabel("Delete rule for \(mapping.sourceModel)")
            }
            .confirmationDialog(
                "Delete routing rule?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    configStore.config.modelMappings.removeAll { $0.id == mapping.id }
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Remove the rule for \"\(mapping.sourceModel)\"? This cannot be undone.")
            }
        }
    }
}

private struct AddMappingRow: View {
    @Environment(ConfigStore.self) private var configStore
    let observedModels: [String]
    let onAdd: (ModelMapping) -> Void
    let onCancel: () -> Void

    @State private var selectedSourceModel: String = ""
    @State private var targetModel: String = ""
    @State private var selectedVendorID: UUID? = nil
    @State private var backupTargetModel: String = ""
    @State private var backupTargetVendorID: UUID? = nil
    @State private var showBackupFields: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SourceModelField(text: $selectedSourceModel, observedModels: observedModels)
            VendorMenuField(
                placeholder: "Target vendor",
                selection: $selectedVendorID,
                vendors: configStore.config.vendors,
                clients: configStore.config.clients
            )
            VendorModelField(
                placeholder: "Target model (vendor model name)",
                text: $targetModel,
                vendorSelection: $selectedVendorID,
                vendors: configStore.config.vendors
            )

            if showBackupFields {
                Divider()
                Text("Backup Target")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                VendorMenuField(
                    placeholder: "Backup vendor",
                    selection: $backupTargetVendorID,
                    vendors: configStore.config.vendors,
                    clients: configStore.config.clients
                )
                VendorModelField(
                    placeholder: "Backup model (vendor model name)",
                    text: $backupTargetModel,
                    vendorSelection: $backupTargetVendorID,
                    vendors: configStore.config.vendors
                )
            }

            HStack {
                Spacer()
                if showBackupFields {
                    Button("Remove Backup") {
                        showBackupFields = false
                        backupTargetModel = ""
                        backupTargetVendorID = nil
                    }
                    .buttonStyle(.mpDestructive)
                } else {
                    Button("Add Backup Target") {
                        showBackupFields = true
                    }
                    .buttonStyle(.mpCancel)
                }
                Button("Cancel", action: onCancel)
                    .buttonStyle(.mpCancel)
                    .accessibilityLabel("Cancel")
                Button("Add") {
                    let trimmedSource = selectedSourceModel.trimmingCharacters(in: .whitespaces)
                    guard !trimmedSource.isEmpty,
                          !targetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                          let vendorID = selectedVendorID else { return }
                    var backupModel: String? = nil
                    var backupVendor: UUID? = nil
                    if showBackupFields,
                       !backupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty,
                       let bvID = backupTargetVendorID {
                        backupModel = backupTargetModel.trimmingCharacters(in: .whitespaces)
                        backupVendor = bvID
                    }
                    let mapping = ModelMapping(
                        sourceModel: trimmedSource,
                        targetModel: targetModel.trimmingCharacters(in: .whitespaces),
                        targetVendorID: vendorID,
                        backupTargetModel: backupModel,
                        backupTargetVendorID: backupVendor
                    )
                    onAdd(mapping)
                }
                .buttonStyle(.mpPrimary)
                .disabled(
                    selectedSourceModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    targetModel.trimmingCharacters(in: .whitespaces).isEmpty ||
                    selectedVendorID == nil ||
                    (showBackupFields && (backupTargetModel.trimmingCharacters(in: .whitespaces).isEmpty || backupTargetVendorID == nil))
                )
                .accessibilityLabel("Add Routing Rule")
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            selectedVendorID = configStore.config.vendors.first?.id
            if targetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let vendor = configStore.config.vendors.first,
               let firstModel = vendor.supportedModels.first {
                targetModel = firstModel
            }
        }
        .onChange(of: selectedVendorID) { newVendorID in
            guard targetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let vendor = configStore.config.vendors.first(where: { $0.id == newVendorID }),
                  let firstModel = vendor.supportedModels.first else { return }
            targetModel = firstModel
        }
        .onChange(of: backupTargetVendorID) { newVendorID in
            guard backupTargetModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let vendor = configStore.config.vendors.first(where: { $0.id == newVendorID }),
                  let firstModel = vendor.supportedModels.first else { return }
            backupTargetModel = firstModel
        }
    }
}

/// TextField with a preset menu for quick selection of known Anthropic model IDs.
private struct SourceModelField: View {
    @Binding var text: String
    let observedModels: [String]
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Source model (e.g. claude-sonnet-4-6)", text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($isFocused)
            .overlay(alignment: .trailing) {
                Menu {
                    Section("Current") {
                        ForEach(KnownAnthropicModels.current, id: \.self) { model in
                            Button(model) { text = model }
                        }
                    }
                    if !observedModels.isEmpty {
                        Section("Observed") {
                            ForEach(observedModels, id: \.self) { model in
                                Button(model) { text = model }
                            }
                        }
                    }
                    Section("Legacy") {
                        ForEach(KnownAnthropicModels.legacy, id: \.self) { model in
                            Button(model) { text = model }
                        }
                    }
                    Divider()
                    Button("Custom...") {
                        text = ""
                        isFocused = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: vendorSelectionMenuIconWidth)
                        .contentShape(Rectangle())
                }
                .menuIndicator(.hidden)
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Preset models")
                .padding(.trailing, 4)
            }
    }
}
