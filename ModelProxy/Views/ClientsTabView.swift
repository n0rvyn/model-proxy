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
    @State private var showCopied: Bool = false

    private var client: ClientConfig { configStore.config.clients[index] }

    private var portChanged: Bool {
        guard let boundPort = proxyServer.boundPorts[client.clientName] else { return false }
        return boundPort != client.port
    }

    private var envExportCommand: String {
        let toolCommand: String
        switch client.clientName.lowercased() {
        case let n where n.contains("claude"):
            toolCommand = "claude"
        case let n where n.contains("codex"):
            toolCommand = "codex"
        default:
            toolCommand = client.clientName.lowercased()
        }
        return "export ANTHROPIC_BASE_URL=http://localhost:\(client.port) && \\\(toolCommand)"
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

            Picker("Unmapped models", selection: Binding(
                get: { configStore.config.clients[index].unmappedPolicy },
                set: { newValue in
                    configStore.config.clients[index].unmappedPolicy = newValue
                    configStore.saveAndReload(proxyServer: proxyServer)
                }
            )) {
                Text("Passthrough").tag(UnmappedModelPolicy.passthrough)
                Text("Route to vendor").tag(UnmappedModelPolicy.routeAll)
                Text("Block").tag(UnmappedModelPolicy.block)
            }

            if client.unmappedPolicy == .routeAll {
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
                    Text(envExportCommand)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button(showCopied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(envExportCommand, forType: .string)
                        showCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            showCopied = false
                        }
                    }
                    .buttonStyle(MPInlineButtonStyle(color: showCopied ? .green : nil))
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
