import SwiftUI

struct GeneralTabView: View {
    @Environment(LoginItemService.self) private var loginItemService
    @Environment(ConfigStore.self) private var configStore
    @Environment(ProxyServer.self) private var proxyServer

    @State private var showAPIKey = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { loginItemService.isEnabled },
                    set: { loginItemService.setEnabled($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Launch at Login")
                        Text("ModelProxy will start automatically when you log in.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Launch at Login")
                .accessibilityHint("When enabled, ModelProxy starts automatically after you log in.")
            }

            Section("Web Search") {
                Picker("Search Provider", selection: binding(\.provider)) {
                    ForEach(WebSearchConfig.Provider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }

                apiKeyFields

                if let link = URL(string: configStore.config.webSearch.provider.registrationURL) {
                    Link("Get API Key", destination: link)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginItemService.refreshStatus()
        }
    }

    @ViewBuilder
    private var apiKeyFields: some View {
        switch configStore.config.webSearch.provider {
        case .forwardAsIs:
            Text("The web_search tool will be forwarded to the vendor unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .brave:
            apiKeyField("Brave API Key", binding: binding(\.braveAPIKey))
        case .google:
            apiKeyField("Google API Key", binding: binding(\.googleAPIKey))
            TextField("Search Engine ID", text: binding(\.googleSearchEngineID))
                .autocorrectionDisabled()
        case .tavily:
            apiKeyField("Tavily API Key", binding: binding(\.tavilyAPIKey))
        }
    }

    private func apiKeyField(_ label: String, binding: Binding<String>) -> some View {
        HStack {
            if showAPIKey {
                TextField(label, text: binding)
                    .autocorrectionDisabled()
            } else {
                SecureField(label, text: binding)
            }
            Button(showAPIKey ? "Hide" : "Reveal") {
                showAPIKey.toggle()
            }
            .buttonStyle(.mpInline)
            .accessibilityLabel(showAPIKey ? "Hide API Key" : "Reveal API Key")
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<WebSearchConfig, T>) -> Binding<T> {
        Binding(
            get: { configStore.config.webSearch[keyPath: keyPath] },
            set: { newValue in
                configStore.config.webSearch[keyPath: keyPath] = newValue
                configStore.saveAndReload(proxyServer: proxyServer)
            }
        )
    }
}

#Preview {
    GeneralTabView()
        .environment(LoginItemService())
        .environment(ConfigStore())
        .environment(ProxyServer(tokenStatsStore: TokenStatsStore()))
}
