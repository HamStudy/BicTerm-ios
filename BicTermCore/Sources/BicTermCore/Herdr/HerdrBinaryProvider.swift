import Foundation

/// Seam that supplies the pinned herdr release binary for one install
/// attempt. Production uses ``HerdrReleaseBinaryProvider`` (URLSession
/// download + on-device cache); tests inject fixed bytes — the offline
/// fixture round-trip serves the repo-local pinned binary this way, so no
/// test ever touches the network.
public protocol HerdrBinaryProvider: Sendable {
    /// Returns the release binary bytes for `target`. Implementations
    /// SHOULD verify against the pin before returning; the installer
    /// re-verifies before upload regardless (defense in depth).
    func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data
}

/// Production provider: downloads the pinned release URL over HTTPS and
/// caches it under the app container's
/// `Library/Caches/herdr-releases/<version>/<target>/herdr`.
///
/// This is a deliberate, seam-isolated URLSession use — a one-shot HTTPS
/// file fetch, not transport I/O (every SSH byte still rides the NIO
/// channels; see the package's no-networking-in-transport rule). A cache
/// hit that still matches the pin skips the download; a stale or corrupted
/// cache entry is re-downloaded and replaced. A fresh download that fails
/// the pin never reaches the cache or the caller.
public struct HerdrReleaseBinaryProvider: HerdrBinaryProvider {
    private let session: URLSession
    private let cacheBase: URL

    /// - Parameters:
    ///   - session: the URLSession used for the one-shot release download.
    ///   - cacheBase: directory the release cache lives under. Defaults to
    ///     the app container's `Library/Caches/herdr-releases`.
    public init(session: URLSession = .shared, cacheBase: URL? = nil) {
        self.session = session
        self.cacheBase = cacheBase ?? Self.defaultCacheBase()
    }

    public func binary(for target: HerdrReleasePins.Target) async throws(HerdrRemoteInstallerError) -> Data {
        let asset = HerdrReleasePins.asset(for: target)
        let cacheURL = cacheBase
            .appendingPathComponent(HerdrReleasePins.version, isDirectory: true)
            .appendingPathComponent(target.rawValue, isDirectory: true)
            .appendingPathComponent("herdr")

        // Cache hit that still matches the pin skips the download.
        if let cached = try? Data(contentsOf: cacheURL),
           HerdrReleasePins.sha256Hex(cached) == asset.sha256 {
            return cached
        }

        guard let url = URL(string: asset.url) else {
            throw .downloadFailed("invalid pinned release URL for \(target.rawValue)")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw .downloadFailed(
                "herdr \(HerdrReleasePins.version) download for \(target.rawValue) failed: \(error.localizedDescription)"
            )
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw .downloadFailed(
                "herdr \(HerdrReleasePins.version) download for \(target.rawValue) returned HTTP \(http.statusCode)"
            )
        }

        let actual = HerdrReleasePins.sha256Hex(data)
        guard actual == asset.sha256 else {
            throw .checksumMismatch(target: target, expected: asset.sha256, actual: actual)
        }

        // Best-effort cache write: a failure only costs the next install a
        // re-download, never correctness (the pin is re-verified every time).
        try? FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: cacheURL, options: .atomic)
        return data
    }

    private static func defaultCacheBase() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("herdr-releases", isDirectory: true)
    }
}
