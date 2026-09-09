import CoderNet
import Foundation
import XCTest
@testable import BicTermCore

struct CoderNativeFixture {
    let server: CoderServer
    let workspace: CoderWorkspace
    let resolver: CoderWorkspaceResolver

    static func load(name: String, loader: any CoderRequestLoading = SystemCoderRequestLoader(), tokenOverride: String? = nil, serverURLOverride: URL? = nil) async throws -> Self {
        let text = try String(contentsOf: SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/coder-dev.env"), encoding: .utf8)
        let entries = text.split(separator: "\n").compactMap { line -> (String, String)? in
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return nil }
            return (String(pair[0]), String(pair[1]))
        }
        let values = Dictionary(uniqueKeysWithValues: entries)
        let url = try XCTUnwrap(serverURLOverride ?? values["CODER_URL"].flatMap(URL.init(string:)))
        let token = try XCTUnwrap(tokenOverride ?? values["CODER_SESSION_TOKEN"])
        let server = try CoderServer(name: "native-fixture", baseURL: url, tokenKeychainTag: "native-selection")
        let tokens = NativeFixtureTokenStore(tag: server.tokenKeychainTag, token: token)
        let client = CoderClient(tokenStore: tokens, requestLoader: loader)
        let workspaces = try await client.workspaces(for: server)
        let workspace = try XCTUnwrap(workspaces.first { $0.name == name })
        let resolver = CoderWorkspaceResolver(serverStore: NativeFixtureServerStore(server: server), tokenStore: tokens, requestLoader: loader)
        return Self(server: server, workspace: workspace, resolver: resolver)
    }

    func connection(options: ProtocolOptions = ProtocolOptions()) throws -> Connection {
        try Connection(
            name: "native-selection", type: .coder,
            host: server.baseURL.host ?? "127.0.0.1", port: server.baseURL.port ?? 7080,
            username: "coder", keyReference: "none", protocolOptions: options,
            coderRef: CoderReference(serverID: server.id, workspaceID: workspace.id)
        )
    }

    func transport() -> CoderTransport {
        CoderTransport(
            resolver: resolver, tunnel: NativeFixtureBridge(),
            socketBaseDirectory: SSHTestFixture.repoRoot.appendingPathComponent("Fixtures/run/g12s").path
        )
    }
}

private actor NativeFixtureTokenStore: CoderTokenStoring {
    private var values: [String: String]
    init(tag: String, token: String) { values = [tag: token] }
    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? { values[keychainTag] }
    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) { values[keychainTag] = token }
    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) { values[keychainTag] = nil }
}

private actor NativeFixtureServerStore: CoderServerStoreProtocol {
    private var server: CoderServer
    init(server: CoderServer) { self.server = server }
    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] { [server] }
    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? { id == server.id ? server : nil }
    func save(_ server: CoderServer) async throws(PersistenceError) { self.server = server }
    func deleteCoderServer(id: UUID) async throws(PersistenceError) { XCTFail("Fixture server must not be deleted") }
}

private struct NativeFixtureBridge: CoderTunneling {
    func version() -> String {
        guard let value = CoderNetVersion() else { return "" }
        defer { CoderNetFreeString(value) }
        return String(cString: value)
    }
    func start(configJSON: String) async throws(CoderTunnelError) -> Int {
        let handle = configJSON.withCString { CoderNetStart(UnsafeMutablePointer(mutating: $0)) }
        guard handle != 0 else { throw .startRejected }
        return Int(handle)
    }
    func dialSSH(handle: Int) async throws(CoderTunnelError) -> String {
        guard let id = Int32(exactly: handle), let value = CoderNetDialSSH(id) else { return "" }
        defer { CoderNetFreeString(value) }
        return String(cString: value)
    }
    func rebind(handle: Int) {
        if let id = Int32(exactly: handle) { CoderNetRebind(id) }
    }
    func close(handle: Int) {
        if let id = Int32(exactly: handle) { CoderNetClose(id) }
    }
}
