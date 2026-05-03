import SwiftUI

struct VendorModelField: View {
    let placeholder: String
    @Binding var text: String
    @Binding var vendorSelection: UUID?
    let vendors: [Vendor]
    let emptySelectionTitle: String?
    @FocusState private var isFocused: Bool

    init(
        placeholder: String,
        text: Binding<String>,
        vendorSelection: Binding<UUID?>,
        vendors: [Vendor],
        emptySelectionTitle: String? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self._vendorSelection = vendorSelection
        self.vendors = vendors
        self.emptySelectionTitle = emptySelectionTitle
    }

    private var models: [String] {
        guard let vendorID = vendorSelection,
              let vendor = vendors.first(where: { $0.id == vendorID }) else {
            return []
        }
        return vendor.supportedModels
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .focused($isFocused)
            .overlay(alignment: .trailing) {
                Menu {
                    if let emptySelectionTitle {
                        Button(emptySelectionTitle) {
                            text = ""
                            isFocused = true
                        }
                        Divider()
                    }

                    if vendorSelection == nil {
                        Button("Select vendor first") {}
                            .disabled(true)
                    } else if models.isEmpty {
                        Button("No models configured") {}
                            .disabled(true)
                    } else {
                        ForEach(models, id: \.self) { model in
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
                .accessibilityLabel(placeholder)
                .padding(.trailing, 4)
            }
    }
}

struct VendorMenuField: View {
    let placeholder: String
    @Binding var selection: UUID?
    let vendors: [Vendor]
    let clients: [ClientConfig]

    private var displayName: String {
        guard let vendorID = selection,
              let vendor = vendors.first(where: { $0.id == vendorID }) else {
            return ""
        }
        return vendor.name
    }

    var body: some View {
        TextField(placeholder, text: .constant(displayName))
            .textFieldStyle(.roundedBorder)
            .allowsHitTesting(false)
            .overlay(alignment: .trailing) {
                Menu {
                    Button("Select...") { selection = nil }
                    Divider()
                    ForEach(vendors) { vendor in
                        Button(vendorPickerLabel(vendor: vendor, clients: clients)) {
                            selection = vendor.id
                        }
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
                .accessibilityLabel(placeholder)
                .padding(.trailing, 4)
            }
    }
}

func vendorPickerLabel(vendor: Vendor, clients: [ClientConfig]) -> String {
    guard let clientID = vendor.compatibleClientID,
          let client = clients.first(where: { $0.id == clientID }) else {
        return vendor.name
    }
    return "\(vendor.name) (\(client.clientName) only)"
}

let vendorSelectionMenuIconWidth: CGFloat = 24
