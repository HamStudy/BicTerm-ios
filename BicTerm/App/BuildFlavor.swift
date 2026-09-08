#if CODER_TUNNEL
// Default (open-source) flavors compile with CODER_TUNNEL=1 and link
// CoderTunnel.framework; AppStore-* configurations exclude the framework
// target, the link flag, and this import — no CoderNet symbol can exist in
// an AppStore binary.
import CoderTunnel
#endif

/// Compile-time build-flavor surface. Runtime capability checks funnel
/// through here so the AppStore flavor can never claim tunnel support.
enum BuildFlavor {
    /// True iff this binary ships the AGPL CoderNet tailnet tunnel core.
    /// False in AppStore-* configurations, where coder connections use the
    /// direct-SSH path.
    static var coderTailnetTunnelSupported: Bool {
        #if CODER_TUNNEL
        // Metatype round-trip, not decoration: referencing
        // `CoderNetTunnel.self` demands the type's metadata accessor at LINK
        // time, which is what pulls the conformer — and transitively the Go
        // core objects — out of the CoderTunnel static archive.
        return String(describing: CoderNetTunnel.self).isEmpty == false
        #else
        return false
        #endif
    }
}
