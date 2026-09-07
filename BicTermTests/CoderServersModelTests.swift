import BicTermCore
import XCTest
@testable import BicTerm

@MainActor
final class CoderServersModelTests: XCTestCase {
    func testSuccessfulAddSavesTokenAndMetadata() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )

        let result = await model.save(server, replacementToken: "valid-token")

        assertSaveSuccess(result)
        XCTAssertEqual(model.servers.map(\.id), [server.id])
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "Production")
    }

    func testBadTokenDoesNotSaveTokenOrMetadata() async throws {
        let loader = FakeCoderRequestLoader(succeed: false)
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )

        let result = await model.save(server, replacementToken: "bad-token")

        guard case .failure(let error) = result, case .validation = error else {
            return XCTFail("Expected validation failure, got \(result)")
        }
        XCTAssertTrue(model.servers.isEmpty)
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertNil(storedToken)
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNil(storedServer)
    }

    func testEditWithoutReplacementPreservesToken() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")

        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )
        let result = await model.save(edited, replacementToken: nil)

        assertSaveSuccess(result)
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "New Name")
        XCTAssertEqual(model.servers.first?.name, "New Name")
    }

    func testEditReplacementFailureRestoresOldToken() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "old-token")

        await store.setFailSave(true)
        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )
        let result = await model.save(edited, replacementToken: "new-token")

        guard case .failure(let error) = result, case .persistence = error else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "old-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "Old Name")
    }

    func testNewServerPersistenceFailureDeletesToken() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        await store.setFailSave(true)

        let result = await model.save(server, replacementToken: "valid-token")

        guard case .failure(let error) = result, case .persistence = error else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertNil(storedToken)
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNil(storedServer)
    }

    func testDeleteWarnsWhenReferenced() async throws {
        let (model, store, connectionStore, _) = makeModel()
        let server = try CoderServer(
            name: "Referenced",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")
        let connection = try Connection(
            name: "Workspace",
            type: .coder,
            host: "coder.example.com",
            port: 443,
            username: "user",
            keyReference: "key",
            coderRef: CoderReference(serverID: server.id, workspaceID: UUID())
        )
        await connectionStore.append(connection)

        let result = await model.delete(server)

        guard case .failure(let error) = result, case .referencedConnections = error else {
            return XCTFail("Expected referencedConnections failure, got \(result)")
        }
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNotNil(storedServer)
    }

    func testDeleteRemovesTokenAndMetadata() async throws {
        let (model, store, _, tokenStore) = makeModel()
        let server = try CoderServer(
            name: "To Delete",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")

        let result = await model.delete(server)

        assertDeleteSuccess(result)
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertNil(storedToken)
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNil(storedServer)
        XCTAssertTrue(model.servers.isEmpty)
    }

    func testForceDeleteRestoresTokenOnPersistenceFailure() async throws {
        let (model, store, _, tokenStore) = makeModel()
        let server = try CoderServer(
            name: "To Delete",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")
        await store.setFailDelete(true)

        let result = await model.forceDelete(server)

        guard case .failure(let error) = result, case .persistence = error else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNotNil(storedServer)
    }

    func testTokenNeverAppearsInModelState() async throws {
        let (model, _, _, _) = makeModel()
        let server = try CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "secret-token")

        let persistedServer = model.servers.first!
        XCTAssertEqual(persistedServer.tokenKeychainTag, server.tokenKeychainTag)
        let mirror = Mirror(reflecting: persistedServer)
        XCTAssertNil(mirror.descendant("token") as? String)
    }

    func testEditEmptyTokenRevalidatesStoredToken() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")

        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )
        let result = await model.save(edited, replacementToken: nil)

        assertSaveSuccess(result)
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "New Name")
    }

    func testDeleteTokenRemovalFailureSurfaces() async throws {
        let (model, store, _, tokenStore) = makeModel()
        let server = try CoderServer(
            name: "To Delete",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")
        await tokenStore.setFailDelete(true)

        let result = await model.delete(server)

        guard case .failure(let error) = result, case .tokenRemoval = error else {
            return XCTFail("Expected tokenRemoval failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNotNil(storedServer)
    }

    func testValidationFailureRestoresOldTokenWhenTokenSaveMutatesAndThrows() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "old-token")

        await tokenStore.setMutateThenThrowSave(true)
        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )

        let result = await model.save(edited, replacementToken: "new-token")

        guard case .failure(let error) = result, case .validation = error else {
            return XCTFail("Expected validation failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "old-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "Old Name")
    }

    func testValidationFailureDeletesNewTokenWhenTokenSaveMutatesAndThrowsOnNewServer() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )

        await tokenStore.setMutateThenThrowSave(true)

        let result = await model.save(server, replacementToken: "candidate-token")

        guard case .failure(let error) = result, case .validation = error else {
            return XCTFail("Expected validation failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertNil(storedToken)
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNil(storedServer)
    }

    func testTokenReadFailureDuringRecoveryIsReported() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "old-token")

        await tokenStore.setMutateThenThrowSave(true)
        await tokenStore.setFailReadAfterCount(2)
        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )

        let result = await model.save(edited, replacementToken: "new-token")

        guard case .failure(let error) = result,
              case .validation(_, let recovery) = error else {
            return XCTFail("Expected validation failure with recovery, got \(result)")
        }
        XCTAssertFalse(recovery.isEmpty, "Token-read failure during recovery should be reported")
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "old-token", "Old token must be restored despite read failure")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "Old Name")
    }

    func testNewServerMetadataSaveFailureRollsBackMutatedMetadata() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Production",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )

        await store.setMutateThenThrowSave(true)

        let result = await model.save(server, replacementToken: "valid-token")

        guard case .failure(let error) = result, case .persistence = error else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNil(storedServer)
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertNil(storedToken)
    }

    func testEditMetadataSaveFailureRestoresOriginalAndOldToken() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "old-token")

        await store.setMutateThenThrowSave(true)
        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )

        let result = await model.save(edited, replacementToken: "new-token")

        guard case .failure(let error) = result, case .persistence = error else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "Old Name")
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "old-token")
    }

    func testForceDeleteTokenRemovalFailureRestoresMutatedToken() async throws {
        let (model, store, _, tokenStore) = makeModel()
        let server = try CoderServer(
            name: "To Delete",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")
        await tokenStore.setMutateThenThrowDelete(true)

        let result = await model.forceDelete(server)

        guard case .failure(let error) = result, case .tokenRemoval = error else {
            return XCTFail("Expected tokenRemoval failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNotNil(storedServer)
    }

    func testForceDeleteMetadataDeleteFailureRestoresMutatedMetadataAndToken() async throws {
        let (model, store, _, tokenStore) = makeModel()
        let server = try CoderServer(
            name: "To Delete",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "valid-token")
        await store.setMutateThenThrowDelete(true)

        let result = await model.forceDelete(server)

        guard case .failure(let error) = result, case .persistence = error else {
            return XCTFail("Expected persistence failure, got \(result)")
        }
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "valid-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertNotNil(storedServer)
    }

    func testRecoveryMutationIsReportedAsRecoveryFailure() async throws {
        let loader = FakeCoderRequestLoader()
        let (model, store, _, tokenStore) = makeModel(requestLoader: loader)
        let server = try CoderServer(
            name: "Old Name",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: tag()
        )
        _ = await model.save(server, replacementToken: "old-token")

        await store.setMutateThenThrowSave(true)
        let edited = try CoderServer(
            id: server.id,
            name: "New Name",
            baseURL: server.baseURL,
            tokenKeychainTag: server.tokenKeychainTag
        )

        let result = await model.save(edited, replacementToken: "new-token")

        guard case .failure(let error) = result,
              case .persistence(_, let recovery) = error else {
            return XCTFail("Expected persistence failure with recovery, got \(result)")
        }
        XCTAssertFalse(recovery.isEmpty, "A recovery attempt that mutated and threw must be reported")
        let storedToken = try await tokenStore.token(for: server.tokenKeychainTag)
        XCTAssertEqual(storedToken, "old-token")
        let storedServer = try await store.coderServer(id: server.id)
        XCTAssertEqual(storedServer?.name, "Old Name")
    }
}

private extension CoderServersModelTests {
    func tag() -> String {
        "com.bicterm.coder.server.\(UUID().uuidString)"
    }

    func makeModel(
        requestLoader: FakeCoderRequestLoader = FakeCoderRequestLoader()
    ) -> (
        model: CoderServersModel,
        store: InMemoryCoderServerStore,
        connectionStore: InMemoryConnectionStore,
        tokenStore: InMemoryTokenStore
    ) {
        let store = InMemoryCoderServerStore()
        let connectionStore = InMemoryConnectionStore()
        let tokenStore = InMemoryTokenStore()
        let model = CoderServersModel(
            store: store,
            connectionStore: connectionStore,
            tokenStore: tokenStore,
            makeClient: { CoderClient(tokenStore: $0, requestLoader: requestLoader) }
        )
        return (model, store, connectionStore, tokenStore)
    }

    func assertSaveSuccess(
        _ result: Result<Void, CoderServerSaveError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Expected save success, got failure: \(error)", file: file, line: line)
        }
    }

    func assertDeleteSuccess(
        _ result: Result<Void, CoderServerDeleteError>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .failure(let error) = result {
            XCTFail("Expected delete success, got failure: \(error)", file: file, line: line)
        }
    }
}

private actor InMemoryCoderServerStore: CoderServerStoreProtocol {
    var storage: [UUID: CoderServer] = [:]
    private var failSave = false
    private var failDelete = false
    private var mutateThenThrowSave = false
    private var mutateThenThrowDelete = false

    func setFailSave(_ flag: Bool) {
        failSave = flag
    }

    func setFailDelete(_ flag: Bool) {
        failDelete = flag
    }

    func setMutateThenThrowSave(_ flag: Bool) {
        mutateThenThrowSave = flag
    }

    func setMutateThenThrowDelete(_ flag: Bool) {
        mutateThenThrowDelete = flag
    }

    func loadCoderServers() async throws(PersistenceError) -> [CoderServer] {
        storage.values.sorted { $0.name < $1.name }
    }

    func coderServer(id: UUID) async throws(PersistenceError) -> CoderServer? {
        storage[id]
    }

    func save(_ server: CoderServer) async throws(PersistenceError) {
        if mutateThenThrowSave {
            storage[server.id] = server
            throw .operationFailed("save mutated then threw")
        }
        if failSave { throw .operationFailed("save rejected") }
        storage[server.id] = server
    }

    func deleteCoderServer(id: UUID) async throws(PersistenceError) {
        if mutateThenThrowDelete {
            storage[id] = nil
            throw .operationFailed("delete mutated then threw")
        }
        if failDelete { throw .operationFailed("delete rejected") }
        storage[id] = nil
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

    func append(_ connection: Connection) {
        storage[connection.id] = connection
    }
}

private actor InMemoryTokenStore: CoderTokenStoring {
    private var storage: [String: String] = [:]
    private var failSave = false
    private var failDelete = false
    private var failReadAfterCount = 0
    private var mutateThenThrowSave = false
    private var mutateThenThrowDelete = false

    func setFailSave(_ flag: Bool) {
        failSave = flag
    }

    func setFailDelete(_ flag: Bool) {
        failDelete = flag
    }

    func setFailReadAfterCount(_ count: Int) {
        failReadAfterCount = count
    }

    func setMutateThenThrowSave(_ flag: Bool) {
        mutateThenThrowSave = flag
    }

    func setMutateThenThrowDelete(_ flag: Bool) {
        mutateThenThrowDelete = flag
    }

    func token(for keychainTag: String) async throws(CoderTokenStoreError) -> String? {
        if failReadAfterCount > 0 {
            failReadAfterCount -= 1
            if failReadAfterCount == 0 {
                throw .keychain(-1)
            }
        }
        return storage[keychainTag]
    }

    func save(_ token: String, for keychainTag: String) async throws(CoderTokenStoreError) {
        if mutateThenThrowSave {
            storage[keychainTag] = token
            throw .keychain(-1)
        }
        if failSave { throw .keychain(-1) }
        storage[keychainTag] = token
    }

    func deleteToken(for keychainTag: String) async throws(CoderTokenStoreError) {
        if mutateThenThrowDelete {
            storage[keychainTag] = nil
            throw .keychain(-1)
        }
        if failDelete { throw .keychain(-1) }
        storage[keychainTag] = nil
    }
}

private actor FakeCoderRequestLoader: CoderRequestLoading {
    var workspaces: [CoderWorkspace]
    var succeed: Bool
    var statusCode: Int
    private var isFrozen = false
    private var pending: CheckedContinuation<Void, Never>?

    init(
        workspaces: [CoderWorkspace] = [],
        succeed: Bool = true,
        statusCode: Int = 200
    ) {
        self.workspaces = workspaces
        self.succeed = succeed
        self.statusCode = statusCode
    }

    func setWorkspaces(_ workspaces: [CoderWorkspace]) {
        self.workspaces = workspaces
    }

    func freeze() {
        isFrozen = true
    }

    func thaw() {
        isFrozen = false
        pending?.resume()
        pending = nil
    }

    func load(_ request: URLRequest) async throws(CoderRequestLoadingError) -> CoderHTTPResponse {
        if isFrozen {
            await withCheckedContinuation { continuation in
                pending = continuation
            }
        }
        if !succeed {
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

@MainActor
final class CoderWorkspaceConnectionModelTests: XCTestCase {
    private func makeServer(name: String = "Prod", id: UUID = UUID()) -> CoderServer {
        // swiftlint:disable:next force_try
        try! CoderServer(
            id: id,
            name: name,
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: "com.bicterm.coder.server.\(id.uuidString)"
        )
    }

    private func makeWorkspace(
        id: UUID = UUID(),
        name: String,
        ownerName: String = "me",
        state: CoderWorkspaceState
    ) -> CoderWorkspace {
        CoderWorkspace(stateOnly: id, name: name, ownerName: ownerName, state: state)
    }

    private func makeModel(
        server: CoderServer,
        token: String = "fixture-token",
        workspaces: [CoderWorkspace] = [],
        succeed: Bool = true,
        statusCode: Int = 200
    ) async -> (
        model: CoderWorkspaceConnectionModel,
        loader: FakeCoderRequestLoader,
        tokenStore: InMemoryTokenStore
    ) {
        let store = InMemoryCoderServerStore()
        try? await store.save(server)
        let tokenStore = InMemoryTokenStore()
        try? await tokenStore.save(token, for: server.tokenKeychainTag)
        let loader = FakeCoderRequestLoader(workspaces: workspaces, succeed: succeed, statusCode: statusCode)
        let model = CoderWorkspaceConnectionModel(
            coderServerStore: store,
            coderTokenStore: tokenStore,
            clientFactory: { coderTokenStore in
                CoderClient(tokenStore: coderTokenStore, requestLoader: loader)
            }
        )
        await model.reloadServers()
        return (model, loader, tokenStore)
    }

    func testCanSaveWhenRunningWorkspaceSelected() async {
        let server = makeServer()
        let workspace = makeWorkspace(name: "dev", state: .running)
        let (model, _, _) = await makeModel(server: server, workspaces: [workspace])

        model.selectServer(server)
        await model.loadWorkspaces()
        model.selectWorkspace(workspace)

        XCTAssertTrue(model.canSave)
        XCTAssertNotNil(model.coderReference())
    }

    func testCannotSaveWhenStoppedWorkspaceSelected() async {
        let server = makeServer()
        let workspace = makeWorkspace(name: "dev", state: .stopped)
        let (model, _, _) = await makeModel(server: server, workspaces: [workspace])

        model.selectServer(server)
        await model.loadWorkspaces()
        model.selectWorkspace(workspace)

        XCTAssertFalse(model.canSave)
        XCTAssertNil(model.coderReference())
        XCTAssertEqual(model.workspaceStatus(), CoderWorkspaceConnectionModel.WorkspaceStatus(state: .stopped, connectable: false))
    }

    func testUnauthorizedClearsSelectionButKeepsServer() async {
        let server = makeServer()
        let (model, _, _) = await makeModel(server: server, succeed: false, statusCode: 401)

        model.selectServer(server)
        model.prepareForInitialValues(serverID: server.id, workspaceID: UUID())
        await model.loadWorkspaces()

        if case .unauthorized(let unauthorizedServer) = model.loadingState {
            XCTAssertEqual(unauthorizedServer.id, server.id)
        } else {
            XCTFail("Expected unauthorized, got \(model.loadingState)")
        }
        XCTAssertEqual(model.selectedServer?.id, server.id)
        XCTAssertNil(model.selectedWorkspaceID)
    }

    func testStaleWhileRevalidatePreservesListDuringRefresh() async {
        let server = makeServer()
        let first = makeWorkspace(name: "first", state: .running)
        let (model, loader, _) = await makeModel(server: server, workspaces: [first])

        model.selectServer(server)
        await model.loadWorkspaces()
        XCTAssertEqual(model.loadingState, .loaded(workspaces: [first]))

        let second = makeWorkspace(id: first.id, name: "first", state: .stopped)
        await loader.setWorkspaces([second])
        await model.loadWorkspaces()

        XCTAssertEqual(model.loadingState, .loaded(workspaces: [second]))
        XCTAssertFalse(model.canSave)
    }

    func testStaleStateIsRenderedWhileRevalidationIsInFlight() async {
        let server = makeServer()
        let workspace = makeWorkspace(name: "dev", state: .running)
        let (model, loader, _) = await makeModel(server: server, workspaces: [workspace])

        model.selectServer(server)
        await model.loadWorkspaces()
        model.selectWorkspace(workspace)
        XCTAssertTrue(model.canSave)

        await loader.freeze()
        await loader.setWorkspaces([makeWorkspace(id: workspace.id, name: "dev", state: .stopped)])

        let refreshTask = Task {
            await model.loadWorkspaces()
        }

        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.loadingState, .staleRevalidating(workspaces: [workspace]))
        XCTAssertTrue(model.canSave, "previous running selection must remain valid while refresh is in flight")

        await loader.thaw()
        await refreshTask.value

        XCTAssertEqual(model.loadingState, .loaded(workspaces: [makeWorkspace(id: workspace.id, name: "dev", state: .stopped)]))
        XCTAssertFalse(model.canSave)
    }

    func testSelectionReconciledWhenWorkspaceDisappears() async {
        let server = makeServer()
        let workspace = makeWorkspace(name: "dev", state: .running)
        let (model, loader, _) = await makeModel(server: server, workspaces: [workspace])

        model.selectServer(server)
        await model.loadWorkspaces()
        model.selectWorkspace(workspace)
        XCTAssertTrue(model.canSave)

        await loader.setWorkspaces([])
        await model.loadWorkspaces()

        XCTAssertNil(model.selectedWorkspace)
        XCTAssertFalse(model.canSave)
    }

    func testSelectionReconciledWhenWorkspaceStops() async {
        let server = makeServer()
        let workspace = makeWorkspace(name: "dev", state: .running)
        let (model, loader, _) = await makeModel(server: server, workspaces: [workspace])

        model.prepareForInitialValues(serverID: server.id, workspaceID: workspace.id)
        model.selectServer(server)
        await model.loadWorkspaces()

        await loader.setWorkspaces([makeWorkspace(id: workspace.id, name: workspace.name, state: .stopped)])
        await model.loadWorkspaces()

        XCTAssertFalse(model.canSave)
        XCTAssertEqual(model.workspaceStatus(), CoderWorkspaceConnectionModel.WorkspaceStatus(state: .stopped, connectable: false))
    }

    func testCoderReferenceRoundTripMetadata() async {
        let server = makeServer(name: "Office", id: UUID())
        let workspace = makeWorkspace(name: "backend", state: .running)
        let (model, _, _) = await makeModel(server: server, workspaces: [workspace])

        model.selectServer(server)
        await model.loadWorkspaces()
        model.selectWorkspace(workspace)

        guard let ref = model.coderReference() else {
            return XCTFail("Expected coder reference")
        }
        XCTAssertEqual(ref.serverID, server.id)
        XCTAssertEqual(ref.workspaceID, workspace.id)
    }
}
