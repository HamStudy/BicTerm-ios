import BicTermCore
import XCTest
@testable import BicTerm

@MainActor
final class ConnectionsModelRefreshTests: XCTestCase {
    private func server(
        id: UUID = UUID(),
        name: String = "Office",
        baseURL: URL = URL(string: "https://coder.example.com")!
    ) throws -> CoderServer {
        try CoderServer(
            id: id,
            name: name,
            baseURL: baseURL,
            tokenKeychainTag: "com.bicterm.coder.server.\(id.uuidString)"
        )
    }

    private func connection(
        name: String = "Coder Connection",
        serverID: UUID,
        workspaceID: UUID,
        workspaceName: String = "dev",
        serverName: String = "Office"
    ) throws -> Connection {
        let options = try ProtocolOptions([
            "coder.workspaceName": .string(workspaceName),
            "coder.serverName": .string(serverName),
        ])
        return try Connection(
            name: name,
            type: .coder,
            host: "coder.example.com",
            port: 443,
            username: "user",
            keyReference: "key",
            protocolOptions: options,
            coderRef: CoderReference(serverID: serverID, workspaceID: workspaceID)
        )
    }

    private func workspace(
        id: UUID = UUID(),
        name: String = "dev",
        state: CoderWorkspaceState
    ) -> CoderWorkspace {
        CoderWorkspace(stateOnly: id, name: name, ownerName: "me", state: state)
    }

    private func makeModel(
        connections: [Connection] = [],
        servers: [CoderServer] = [],
        workspaces: [CoderWorkspace] = [],
        statusCode: Int = 200
    ) async -> (
        model: ConnectionsModel,
        connectionStore: InMemoryConnectionStore,
        serverStore: InMemoryCoderServerStore,
        loader: FakeCoderRequestLoader
    ) {
        let connectionStore = InMemoryConnectionStore()
        let serverStore = InMemoryCoderServerStore()
        let tokenStore = InMemoryTokenStore()
        let loader = FakeCoderRequestLoader(
            workspaces: workspaces,
            statusCode: statusCode
        )

        for connection in connections {
            try? await connectionStore.save(connection)
        }

        let coderDescriptor = ProtocolDescriptor(
            id: "coder",
            displayName: "Coder",
            supportsAgentForwarding: false,
            supportsJumpChain: false,
            supportsRoamingResume: false,
            requiresServerComponent: true,
            defaultPort: 443,
            keyAlgorithmsAccepted: ["ssh-ed25519"],
            resumeStrategy: .rehandshake
        )
        let model = ConnectionsModel(
            connectionStore: connectionStore,
            coderServerStore: serverStore,
            coderClientFactory: { tokenStore in
                CoderClient(tokenStore: tokenStore, requestLoader: loader)
            },
            coderTokenStore: tokenStore,
            protocolDescriptors: [coderDescriptor],
            descriptorProvider: { $0 == "coder" ? coderDescriptor : nil }
        )
        await model.reload()

        for server in servers {
            try? await serverStore.save(server)
            try? await tokenStore.save("fixture-token", for: server.tokenKeychainTag)
        }

        return (model, connectionStore, serverStore, loader)
    }

    func testRefreshSetsRunningStatus() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let srv = try server(id: serverID, name: "Office")
        let ws = workspace(id: workspaceID, name: "dev", state: .running)
        let (model, _, _, _) = await makeModel(
            connections: [try connection(serverID: serverID, workspaceID: workspaceID)],
            servers: [srv],
            workspaces: [ws]
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertEqual(status?.workspaceName, "dev")
        XCTAssertEqual(status?.serverName, "Office")
        XCTAssertEqual(status?.state, .running)
        XCTAssertTrue(status?.isConnectable == true)
        XCTAssertFalse(status?.isUnauthorized == true)
        XCTAssertEqual(status?.serverID, serverID)
    }

    func testRefreshSetsStoppedStatusNotConnectable() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let srv = try server(id: serverID)
        let ws = workspace(id: workspaceID, name: "dev", state: .stopped)
        let (model, _, _, _) = await makeModel(
            connections: [try connection(serverID: serverID, workspaceID: workspaceID)],
            servers: [srv],
            workspaces: [ws]
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertEqual(status?.state, .stopped)
        XCTAssertFalse(status?.isConnectable == true)
    }

    func testRefreshSetsUnauthorizedStatus() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let srv = try server(id: serverID)
        let (model, _, _, _) = await makeModel(
            connections: [try connection(serverID: serverID, workspaceID: workspaceID, workspaceName: "dev")],
            servers: [srv],
            statusCode: 401
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertTrue(status?.isUnauthorized == true)
        XCTAssertFalse(status?.isConnectable == true)
        XCTAssertNil(status?.state)
        XCTAssertEqual(status?.workspaceName, "dev")
        XCTAssertEqual(status?.serverName, "Office")
        XCTAssertEqual(status?.serverID, serverID)
    }

    func testRefreshHandlesMissingWorkspace() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let otherWorkspaceID = UUID()
        let srv = try server(id: serverID)
        let ws = workspace(id: otherWorkspaceID, name: "other", state: .running)
        let (model, _, _, _) = await makeModel(
            connections: [try connection(serverID: serverID, workspaceID: workspaceID, workspaceName: "dev")],
            servers: [srv],
            workspaces: [ws]
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertEqual(status?.workspaceName, "dev")
        XCTAssertEqual(status?.serverName, "Office")
        XCTAssertNil(status?.state)
        XCTAssertFalse(status?.isConnectable == true)
        XCTAssertFalse(status?.isUnauthorized == true)
        XCTAssertEqual(status?.serverID, serverID)
    }

    func testRefreshHandlesMissingServer() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let (model, _, _, _) = await makeModel(
            connections: [try connection(serverID: serverID, workspaceID: workspaceID, workspaceName: "dev")],
            servers: []
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertEqual(status?.workspaceName, "dev")
        XCTAssertEqual(status?.serverName, "Office")
        XCTAssertNil(status?.state)
        XCTAssertFalse(status?.isConnectable == true)
        XCTAssertFalse(status?.isUnauthorized == true)
    }

    func testRefreshHandlesRequestFailure() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let srv = try server(id: serverID)
        let (model, _, _, _) = await makeModel(
            connections: [try connection(serverID: serverID, workspaceID: workspaceID, workspaceName: "dev")],
            servers: [srv],
            statusCode: 500
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertEqual(status?.workspaceName, "dev")
        XCTAssertEqual(status?.serverName, "Office")
        XCTAssertNil(status?.state)
        XCTAssertFalse(status?.isConnectable == true)
        XCTAssertFalse(status?.isUnauthorized == true)
        XCTAssertEqual(status?.serverID, serverID)
    }

    func testRefreshUsesPersistedNameFallback() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let options = try ProtocolOptions([
            "coder.workspaceName": .string("Renamed Workspace"),
            "coder.serverName": .string("Old Server"),
        ])
        let conn = try Connection(
            name: "Coder Connection",
            type: .coder,
            host: "coder.example.com",
            port: 443,
            username: "user",
            keyReference: "key",
            protocolOptions: options,
            coderRef: CoderReference(serverID: serverID, workspaceID: workspaceID)
        )
        let (model, _, _, _) = await makeModel(
            connections: [conn],
            servers: []
        )

        await model.refreshCoderStatuses()

        let status = model.coderStatus(for: model.connections[0])
        XCTAssertEqual(status?.workspaceName, "Renamed Workspace")
        XCTAssertEqual(status?.serverName, "Old Server")
    }

    func testRefreshClearsStatusesWhenNoCoderConnections() async throws {
        let serverID = UUID()
        let workspaceID = UUID()
        let conn = try connection(serverID: serverID, workspaceID: workspaceID)
        let (model, connectionStore, _, _) = await makeModel(
            connections: [conn],
            servers: [try server(id: serverID)],
            workspaces: [workspace(id: workspaceID, name: "dev", state: .running)]
        )
        await model.refreshCoderStatuses()
        XCTAssertNotNil(model.coderStatus(for: conn))

        try? await connectionStore.deleteConnection(id: conn.id)
        await model.reload()
        await model.refreshCoderStatuses()

        XCTAssertTrue(model.coderStatuses.isEmpty)
    }

    func testRefreshHandlesMultipleConnectionsOnSameServer() async throws {
        let serverID = UUID()
        let runningID = UUID()
        let stoppedID = UUID()
        let srv = try server(id: serverID)
        let conn1 = try connection(
            name: "Running Conn",
            serverID: serverID,
            workspaceID: runningID,
            workspaceName: "running-ws"
        )
        let conn2 = try connection(
            name: "Stopped Conn",
            serverID: serverID,
            workspaceID: stoppedID,
            workspaceName: "stopped-ws"
        )
        let (model, _, _, _) = await makeModel(
            connections: [conn1, conn2],
            servers: [srv],
            workspaces: [
                workspace(id: runningID, name: "running-ws", state: .running),
                workspace(id: stoppedID, name: "stopped-ws", state: .stopped),
            ]
        )

        await model.refreshCoderStatuses()

        let status1 = model.coderStatus(for: conn1)
        let status2 = model.coderStatus(for: conn2)
        XCTAssertTrue(status1?.isConnectable == true)
        XCTAssertEqual(status1?.workspaceName, "running-ws")
        XCTAssertFalse(status2?.isConnectable == true)
        XCTAssertEqual(status2?.workspaceName, "stopped-ws")
    }
}

private actor InMemoryConnectionStore: ConnectionStoreProtocol {
    private var storage: [UUID: Connection] = [:]

    func loadConnections() async throws(PersistenceError) -> [Connection] {
        storage.values.sorted { $0.name < $1.name }
    }

    func connection(id: UUID) async throws(PersistenceError) -> Connection? {
        storage[id]
    }

    func save(_ connection: Connection) async throws(PersistenceError) {
        storage[connection.id] = connection
    }

    func deleteConnection(id: UUID) async throws(PersistenceError) {
        storage[id] = nil
    }
}

private actor InMemoryCoderServerStore: CoderServerStoreProtocol {
    private var storage: [UUID: CoderServer] = [:]

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        storage.values.sorted { $0.name < $1.name }
    }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        storage[id]
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {
        storage[server.id] = server
    }

    func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        storage[id] = nil
    }
}

private actor InMemoryTokenStore: CoderTokenStoring {
    private var storage: [String: String] = [:]

    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        storage[keychainTag]
    }

    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        storage[keychainTag] = token
    }

    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
        storage[keychainTag] = nil
    }
}

private actor FakeCoderRequestLoader: CoderRequestLoading {
    private var workspaces: [CoderWorkspace]
    private let statusCode: Int

    init(workspaces: [CoderWorkspace] = [], statusCode: Int = 200) {
        self.workspaces = workspaces
        self.statusCode = statusCode
    }

    func setWorkspaces(_ workspaces: [CoderWorkspace]) {
        self.workspaces = workspaces
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.path == "/api/v2/workspaces" else {
            throw .invalidURL
        }
        if statusCode == 401 {
            return CoderHTTPResponse(statusCode: 401, body: Data())
        }
        if statusCode >= 500 {
            return CoderHTTPResponse(statusCode: statusCode, body: Data())
        }
        let items = workspaces.map { workspace in
            #"{"id":"\#(workspace.id.uuidString)","name":"\#(workspace.name)","owner_name":"\#(workspace.ownerName)","latest_build":{"status":"\#(workspace.state.rawValue)"}}"#
        }
        let list = "[" + items.joined(separator: ",") + "]"
        let body = Data(#"{"workspaces":\#(list),"count":\#(workspaces.count)}"#.utf8)
        return CoderHTTPResponse(statusCode: statusCode, body: body)
    }
}
