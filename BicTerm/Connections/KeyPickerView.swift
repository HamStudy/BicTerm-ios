import BicTermCore
import SwiftUI

/// Lists keychain keys by label + SHA256 fingerprint ONLY — private key
/// material is never read, displayed, or accepted here.
struct KeyPickerView: View {
    @Environment(\.terminalColors) var colors
    @Environment(\.terminalTypography) var typography
    @Environment(\.terminalSpacing) var spacing
    @Environment(\.dismiss) private var dismiss

    let keys: [KeyMetadata]
    var selectedReference: String?
    let onSelect: (KeyMetadata) -> Void

    init(
        keys: [KeyMetadata],
        selectedReference: String? = nil,
        onSelect: @escaping (KeyMetadata) -> Void
    ) {
        self.keys = keys
        self.selectedReference = selectedReference
        self.onSelect = onSelect
    }

    var body: some View {
        List {
            if keys.isEmpty {
                Text("No keys yet. Generate or import one under Settings.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            }
            ForEach(keys, id: \.reference) { key in
                Button {
                    onSelect(key)
                    dismiss()
                } label: {
                    HStack(spacing: spacing.sm) {
                        Image(systemName: key.reference == selectedReference ? "checkmark.circle.fill" : "key")
                            .foregroundColor(key.reference == selectedReference ? colors.success : colors.dimmed)
                        VStack(alignment: .leading, spacing: spacing.xxxs) {
                            Text(key.label)
                                .font(typography.body)
                                .foregroundColor(colors.foreground)
                            Text(key.fingerprint)
                                .font(typography.caption)
                                .foregroundColor(colors.dimmed)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(key.algorithm.rawValue + (key.requiresBiometry ? " · biometry" : ""))
                                .font(typography.caption)
                                .foregroundColor(colors.dimmed)
                        }
                        Spacer()
                    }
                }
                .accessibilityIdentifier("key-\(sanitized(key.label))")
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(colors.background)
        .navigationTitle("Select Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sanitized(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "-")
    }
}
