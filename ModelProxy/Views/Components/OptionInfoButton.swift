import SwiftUI

/// Explanation shown by an `OptionInfoButton`: what a setting does and how to pick a value.
struct OptionHelp {
    let title: String
    let whatItDoes: String
    let howToChoose: String
}

/// Small ⓘ button placed after a setting's label; click shows the setting's explanation in a popover.
struct OptionInfoButton: View {
    let help: OptionHelp
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(help.title)")
        .popover(isPresented: $isPresented, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 10) {
                Text(help.title)
                    .font(.headline)
                Text(help.whatItDoes)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("How to choose")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(help.howToChoose)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.callout)
            .padding(16)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// A setting label followed by its ⓘ button, for use as a Toggle or Picker label.
struct OptionLabel: View {
    let help: OptionHelp

    var body: some View {
        HStack(spacing: 4) {
            Text(help.title)
            OptionInfoButton(help: help)
        }
    }
}
