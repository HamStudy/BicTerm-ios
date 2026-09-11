import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Per-endpoint clipboard policy (integration doc §8.3): whether an inbound
/// OSC 52 server clipboard write may land on the system pasteboard without a
/// per-occurrence gesture. Default OFF — "Copy from remote" is the shipped
/// behavior; the opt-in is a deliberate per-host choice.
struct HerdrClipboardSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func autoCopyRemoteClipboard(for endpoint: HerdrEndpointID) -> Bool {
        defaults.bool(forKey: key(for: endpoint))
    }

    func setAutoCopyRemoteClipboard(_ enabled: Bool, for endpoint: HerdrEndpointID) {
        defaults.set(enabled, forKey: key(for: endpoint))
    }

    /// Per-host forget: removes the endpoint's stored opt-in so a re-added
    /// host starts from the privacy-preserving default (OFF).
    func forgetEndpoint(_ endpoint: HerdrEndpointID) {
        defaults.removeObject(forKey: key(for: endpoint))
    }

    private func key(for endpoint: HerdrEndpointID) -> String {
        "herdr.clipboard.autocopy.\(endpoint.rawValue)"
    }
}

/// The herdr layer's only pasteboard touch-points (doc §8.2/§8.3). Reads
/// happen exclusively after an explicit user gesture and are counted in
/// DEBUG builds so the UI suites can prove zero pre-gesture reads; clipboard
/// content is never logged anywhere — only counts and kinds are observable.
/// Main-actor isolated: every call site is the workspace view layer or the
/// @MainActor session model.
@MainActor
enum HerdrPasteboard {
    #if DEBUG
    private(set) static var readCount = 0
    private(set) static var writeCount = 0
    /// Test-only record of the last written string so unit tests can assert
    /// the auto-copy round trip in memory; never logged.
    private(set) static var lastWrittenText: String?

    static func resetCounters() {
        readCount = 0
        writeCount = 0
        lastWrittenText = nil
    }
    #endif

    /// Metadata queries only (no content read; cannot trigger the system
    /// paste prompt) — used to pick the text vs. image flow for a gesture.
    static var hasStrings: Bool { UIPasteboard.general.hasStrings }
    static var hasImages: Bool { UIPasteboard.general.hasImages }

    static func readText() -> String? {
        #if DEBUG
        readCount += 1
        #endif
        return UIPasteboard.general.string
    }

    /// Un-decoded image bytes (PNG/JPEG/HEIC representation). The pipeline
    /// re-encodes before anything is sent; the supplied type is never
    /// trusted (doc §8.4).
    static func readImageData() -> Data? {
        let pasteboard = UIPasteboard.general
        for type in [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier] {
            if let data = pasteboard.data(forPasteboardType: type) {
                #if DEBUG
                readCount += 1
                #endif
                return data
            }
        }
        return nil
    }

    static func writeText(_ text: String) {
        #if DEBUG
        writeCount += 1
        lastWrittenText = text
        #endif
        UIPasteboard.general.string = text
    }
}

enum HerdrClipboard {
    /// App-side cap for one pasted text payload in UTF-8 bytes. A semantic
    /// Paste event travels as a normal client frame (protocol default frame
    /// cap ~2 MiB); 1 MiB leaves envelope headroom and stops a misguided
    /// paste from queueing megabytes of terminal input.
    static let maxTextPasteBytes = 1_048_576

    /// Pastes at or above this size confirm first, showing the destination
    /// pane (doc §8.2).
    static let largePasteConfirmationThreshold = 100_000

    /// Protocol clipboard-image cap (16 MiB), mirroring
    /// `MAX_CLIPBOARD_IMAGE_PAYLOAD` in the vendored protocol crate. That
    /// constant is not exported over the C ABI; the FFI re-enforces the cap
    /// on send, so a protocol-side change fails closed instead of silently
    /// drifting.
    static let maxImagePayloadBytes = 16 * 1024 * 1024

    enum TextPaste: Equatable, Sendable {
        case empty
        case ready(String)
        case needsConfirmation(String)
        case tooLarge
    }

    /// Classifies one pasteboard string. The text passes through byte-exact
    /// — no newline rewriting, no bracketed-paste wrapping; the remote
    /// terminal runtime owns both decisions (doc §8.2: "send the exact
    /// approved text").
    static func classifyTextPaste(_ text: String?) -> TextPaste {
        guard let text, !text.isEmpty else { return .empty }
        let bytes = text.utf8.count
        if bytes > maxTextPasteBytes { return .tooLarge }
        if bytes >= largePasteConfirmationThreshold { return .needsConfirmation(text) }
        return .ready(text)
    }

    // MARK: - Image pipeline (doc §8.4)

    struct PreparedImage: Equatable, Sendable {
        let data: Data
        let `extension`: String
        let pixelWidth: Int
        let pixelHeight: Int
        let metadataStripped: Bool
    }

    enum ImagePasteError: Equatable, Error {
        /// Source bytes exceeded the cap before decode, or a streamed file
        /// crossed the cap mid-read.
        case exceedsCap
        case undecodable
        case encodeFailed
        /// Re-encoded bytes still exceed the cap; offer a downscale choice.
        case needsDownscale
    }

    /// Downscale choices presented when re-encoding overflows the cap:
    /// fractions of the source's maximum pixel dimension.
    static let downscaleFactors: [Double] = [0.75, 0.5, 0.25]

    /// Pixel dimensions via metadata only — no full decode.
    static func imageDimensions(of data: Data) -> (width: Int, height: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        return (width, height)
    }

    /// Streams a picked or dropped image file into memory with the cap
    /// enforced DURING the read: the moment the running total crosses the
    /// cap the read aborts, so the whole object is never retained.
    static func readCapped(
        url: URL,
        maxBytes: Int = maxImagePayloadBytes
    ) -> Result<Data, ImagePasteError> {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.undecodable)
        }
        defer { try? handle.close() }
        var data = Data()
        do {
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                data.append(chunk)
                if data.count > maxBytes { return .failure(.exceedsCap) }
            }
        } catch {
            return .failure(.undecodable)
        }
        return .success(data)
    }

    /// Decodes and re-encodes the source as PNG. Re-encoding — never the
    /// supplied extension — determines what reaches the wire; EXIF/location
    /// metadata is stripped by default and only carried when the labeled
    /// preserve option is on. Corrupt metadata still decodes (ImageIO
    /// tolerates it) and is stripped like any other. `maxPayloadBytes` is
    /// the output cap, clamped to the protocol cap so tests can exercise
    /// the downscale path with small images and never weaken production.
    static func prepareImage(
        from source: Data,
        preserveMetadata: Bool = false,
        maxPayloadBytes: Int = maxImagePayloadBytes
    ) -> Result<PreparedImage, ImagePasteError> {
        guard source.count <= maxImagePayloadBytes else { return .failure(.exceedsCap) }
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return .failure(.undecodable)
        }
        return encode(
            image,
            properties: preservedProperties(from: imageSource, when: preserveMetadata),
            maxPayloadBytes: min(maxPayloadBytes, maxImagePayloadBytes)
        )
    }

    /// Downscale variant: renders through ImageIO's thumbnail path at the
    /// given maximum pixel dimension, then re-encodes under the same rules.
    static func prepareImage(
        from source: Data,
        maxPixelSize: Int,
        preserveMetadata: Bool = false,
        maxPayloadBytes: Int = maxImagePayloadBytes
    ) -> Result<PreparedImage, ImagePasteError> {
        guard source.count <= maxImagePayloadBytes else { return .failure(.exceedsCap) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                  imageSource, 0, options as CFDictionary
              ) else {
            return .failure(.undecodable)
        }
        return encode(
            thumbnail,
            properties: preservedProperties(from: imageSource, when: preserveMetadata),
            maxPayloadBytes: min(maxPayloadBytes, maxImagePayloadBytes)
        )
    }

    private static func preservedProperties(
        from source: CGImageSource,
        when preserveMetadata: Bool
    ) -> [CFString: Any]? {
        guard preserveMetadata else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private static func encode(
        _ image: CGImage,
        properties: [CFString: Any]?,
        maxPayloadBytes: Int
    ) -> Result<PreparedImage, ImagePasteError> {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return .failure(.encodeFailed) }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary?)
        guard CGImageDestinationFinalize(destination) else { return .failure(.encodeFailed) }
        let data = output as Data
        guard data.count <= maxPayloadBytes else { return .failure(.needsDownscale) }
        return .success(PreparedImage(
            data: data,
            extension: "png",
            pixelWidth: image.width,
            pixelHeight: image.height,
            metadataStripped: properties == nil
        ))
    }
}
