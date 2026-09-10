import SwiftUI

/// Confirmation surface for image paste (integration doc §8.4): shows the
/// destination pane captured at gesture time, strips EXIF/location metadata
/// by default behind a clearly labeled toggle, offers a downscale choice
/// when the re-encode would exceed the 16 MiB protocol cap, and explains
/// the remote-temp-file lifecycle. Nothing leaves the device until Send.
struct HerdrImagePasteSheet: View {
    let sourceBytes: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let needsDownscale: Bool
    let destinationPane: String
    let onSend: (_ preserveMetadata: Bool, _ downscaleFactor: Double) -> Void
    let onCancel: () -> Void

    @State private var includeMetadata = false
    @State private var downscaleFactor: Double = HerdrClipboard.downscaleFactors[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send image to \(destinationPane)")
                .font(.headline)
                .accessibilityIdentifier("herdr-image-sheet-title")
            Text("\(pixelWidth) × \(pixelHeight), \(sourceBytes) source bytes")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Include photo metadata (EXIF, location)", isOn: $includeMetadata)
                .accessibilityIdentifier("herdr-image-metadata-toggle")
            if needsDownscale {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Image exceeds the 16 MB clipboard limit at full size. Choose a scale:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Image scale", selection: $downscaleFactor) {
                        ForEach(HerdrClipboard.downscaleFactors, id: \.self) { factor in
                            Text("\(Int(factor * 100))%").tag(factor)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("herdr-image-downscale-picker")
                }
            }
            Text("The image is sent as a temporary file on the remote host; cleanup is governed by that Herdr server.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("herdr-image-cancel")
                Spacer()
                Button("Send Image") {
                    onSend(includeMetadata, needsDownscale ? downscaleFactor : 1.0)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("herdr-image-send")
            }
        }
        .padding()
        .presentationDetents([.medium])
    }
}
