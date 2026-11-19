import SwiftUI

struct ClientsTabView: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    var body: some View {
        Form {
            ForEach(configStore.config.clients.indices, id: \.self) { index in
                ClientRowSection(index: index)
                    .environment(configStore)
                    .environment(proxyServer)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

private struct ClientRowSection: View {
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer
    let index: Int

    @State private var portText: String = ""
    @State private var tokenText = ""
    @State private var isTokenVisible = false
    @State private var showCopied: Bool = false
    @FocusState private var editingToken: Bool

    private var client: ClientConfig { configStore.config.clients[index] }

    private var portChanged: Bool {
        guard let boundPort = proxyServer.boundPorts[client.clientName] else { return false }
        return boundPort != client.port
    }

    private var envExportCommand: String {
        let name = client.clientName.lowercased()
        let toolCommand = name.contains("codex") ? "codex" : name
        return "export ANTHROPIC_BASE_URL=http://localhost:\(client.port) && \\\(toolCommand)"
    }

    private var quickStartClient: ClientConfig {
        var draft = client
        let token = tokenText.trimmingCharacters(in: .whitespaces)
        draft.localAuthToken = token.isEmpty ? nil : token
        return draft
    }

    private var canCopyQuickStart: Bool {
        !client.isClaudeCode || quickStartClient.claudeQuickStartCommand() != nil
    }

    private func saveLocalToken() {
        let token = quickStartClient.localAuthToken
        guard ClientConfig.isValidLocalAuthToken(token ?? ""), token != client.localAuthToken else { return }
        configStore.config.clients[index].localAuthToken = token
        configStore.saveAndReload(proxyServer: proxyServer)
    }

    private var localTokenField: some View {
        let prompt = Text(client.isVendorOnly ? "Required" : "Optional")
        let visibilityAction = isTokenVisible ? "Hide local proxy token" : "Show local proxy token"

        return LabeledContent("Local proxy token") {
            HStack(spacing: 6) {
                Group {
                    if isTokenVisible {
                        TextField("Local proxy token", text: $tokenText, prompt: prompt)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("Local proxy token", text: $tokenText, prompt: prompt)
                    }
                }
                .labelsHidden()
                .focused($editingToken)
                .onSubmit(saveLocalToken)
                .onChange(of: editingToken) { _, editing in
                    if !editing { saveLocalToken() }
                }

                Button {
                    isTokenVisible.toggle()
                } label: {
                    Label(visibilityAction, systemImage: isTokenVisible ? "eye.slash" : "eye")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(visibilityAction)
            }
        }
        .onAppear { tokenText = client.localAuthToken ?? "" }
        .onDisappear { isTokenVisible = false }
    }

    var body: some View {
        Section(client.clientName) {
            TextField("Port", text: $portText)
                .onAppear { portText = "\(client.port)" }
                .onSubmit {
                    guard let port = Int(portText), (1024...65535).contains(port) else { return }
                    configStore.config.clients[index].port = port
                    configStore.saveAndReload(proxyServer: proxyServer)
                }

            // Port change banner (DP-002: port change needs manual Stop/Start)
            if portChanged {
                Text("Port change takes effect after stopping and restarting the proxy.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            TextField("Default upstream", text: Binding(
                get: { configStore.config.clients[index].defaultUpstream },
                set: { newValue in
                    configStore.config.clients[index].defaultUpstream = newValue
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
            ))
            .autocorrectionDisabled()
            .textContentType(nil)

            if client.isClaudeCode {
                Picker("Connection mode", selection: Binding(
                    get: { client.claudeConnectionMode },
                    set: { mode in
                        configStore.config.clients[index].claudeConnectionMode = mode
                        configStore.saveAndReload(proxyServer: proxyServer)
                    }
                )) {
                    Text("Claude Subscription").tag(ClaudeConnectionMode.subscription)
                    Text("Vendor Only").tag(ClaudeConnectionMode.vendorOnly)
                }

                localTokenField

                if !ClientConfig.isValidLocalAuthToken(tokenText) {
                    Text("Use printable ASCII characters on one line.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Picker("Unmapped models", selection: Binding(
                get: { client.isVendorOnly ? .block : client.unmappedPolicy },
                set: { newValue in
                    configStore.config.clients[index].unmappedPolicy = newValue
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
            )) {
                Text("Passthrough").tag(UnmappedModelPolicy.passthrough)
                Text("Route to vendor").tag(UnmappedModelPolicy.routeAll)
                Text("Block").tag(UnmappedModelPolicy.block)
            }
            .disabled(client.isVendorOnly)

            if !client.isVendorOnly && client.unmappedPolicy == .routeAll {
                Picker("Fallback vendor", selection: Binding(
                    get: { configStore.config.clients[index].fallbackVendorID },
                    set: { newValue in
                        configStore.config.clients[index].fallbackVendorID = newValue
                        configStore.saveAndReload(proxyServer: proxyServer)
                    }
                )) {
                    Text("None").tag(UUID?.none)
                    ForEach(configStore.config.vendors) { vendor in
                        Text(vendor.name).tag(UUID?.some(vendor.id))
                    }
                }

                VendorModelField(
                    placeholder: "Fallback model (empty = keep original)",
                    text: fallbackModelBinding,
                    vendorSelection: fallbackVendorBinding,
                    vendors: configStore.config.vendors,
                    emptySelectionTitle: "Keep original model"
                )
            }

            LabeledContent("Quick start") {
                HStack(spacing: 6) {
                    Text(client.isClaudeCode
                         ? (quickStartClient.claudeQuickStartCommand(maskToken: true) ?? "Set a valid local proxy token")
                         : envExportCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(showCopied ? "Copied" : "Copy") {
                        let command: String
                        if client.isClaudeCode {
                            guard let quickStart = quickStartClient.claudeQuickStartCommand() else { return }
                            saveLocalToken()
                            command = quickStart
                        } else {
                            command = envExportCommand
                        }
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    }
                    .buttonStyle(MPInlineButtonStyle(color: showCopied ? .green : nil))
                    .disabled(!canCopyQuickStart)
                    .accessibilityLabel("Copy quick start command for \(client.clientName)")
                    .accessibilityHint("Copies the export command to clipboard.")
                }
            }
        }
    }

    private var fallbackVendorBinding: Binding<UUID?> {
        Binding(
            get: { configStore.config.clients[index].fallbackVendorID },
            set: { newValue in
                configStore.config.clients[index].fallbackVendorID = newValue
                configStore.saveAndReload(proxyServer: proxyServer)
            }
        )
    }

    private var fallbackModelBinding: Binding<String> {
        Binding(
            get: { configStore.config.clients[index].fallbackTargetModel ?? "" },
            set: { newValue in
                configStore.config.clients[index].fallbackTargetModel = newValue.isEmpty ? nil : newValue
                configStore.saveAndReload(proxyServer: proxyServer)
            }
        )
    }
}
