/// Session identity follows connect/reconnect tasks, including nested jump dials.
/// A connection UUID alone cannot route prompts when two scenes use the same connection.
public enum SessionTransportContext {
    @TaskLocal public static var sceneID: String?
}
