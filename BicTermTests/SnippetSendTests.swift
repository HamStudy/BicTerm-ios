import BicTermCore
import XCTest
@testable import BicTerm

/// t8 snippet delivery: scope filtering (global plus current
/// connection), Insert's exact bytes without Return, exactly-one
/// confirmed Run (bytes + CR), no pre-confirm send, stale/changed-session
/// cancellation with zero bytes, disconnect surfacing an inline error
/// without sending, and management saves never sending.
@MainActor
final class SnippetSendTests: XCTestCase {

    private func makeConnection(name: String) throws -> Connection {
        try Connection(
            name: name,
            type: .ssh,
            host: "127.0.0.1",
            port: 22,
            username: "unit",
            customKeys: ["unit-key"]
        )
    }

    private func makeModel(
        name: String = "snippet-unit",
        snippetStore: any SnippetStoreProtocol = InMemorySnippetStore(),
        factory: TerminalTransportFactory = ScriptedSessionTransportFactory(fallback: .succeed)
    ) throws -> (model: SessionSceneModel, store: SessionStore, snippetStore: any SnippetStoreProtocol, connection: Connection) {
        let store = SessionStore(
            transportFactory: factory,
            snapshotStore: InMemoryAppSnapshotStore(),
            connectionLookup: { _ in nil },
            snippetStore: snippetStore
        )
        let connection = try makeConnection(name: name)
        let descriptor = store.openSession(for: connection)
        let model = try XCTUnwrap(store.sceneModel(for: descriptor.id))
        return (model, store, snippetStore, connection)
    }

    @discardableResult
    private func startAndWaitActive(_ model: SessionSceneModel) async -> Bool {
        await model.start()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if model.state == .active { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return model.state == .active
    }

    private func makeRunRequest(
        command: String = "echo probe",
        connectionName: String = "snippet-unit"
    ) -> TerminalSnippetRunRequest {
        TerminalSnippetRunRequest(snippetName: "Probe", command: command, connectionName: connectionName)
    }

    // MARK: - Scope filtering

    func testReloadSnippetsListsGlobalAndCurrentConnectionOnly() async throws {
        let snippetStore = InMemorySnippetStore()
        let (model, _, _, connection) = try makeModel(snippetStore: snippetStore)
        try await snippetStore.save(try Snippet(name: "Global One", command: "echo one"))
        try await snippetStore.save(try Snippet(name: "Scoped", command: "echo scoped", connectionID: connection.id))
        try await snippetStore.save(try Snippet(name: "Other Scope", command: "echo other", connectionID: UUID()))

        await model.reloadSnippets()

        XCTAssertEqual(model.snippets.map(\.name), ["Global One", "Scoped"])
        XCTAssertNil(model.snippetLoadError)
    }

    func testReloadSnippetsSurfacesLoadError() async throws {
        let snippetStore = FailingSnippetStore()
        let (model, _, _, _) = try makeModel(snippetStore: snippetStore)

        await model.reloadSnippets()

        XCTAssertNotNil(model.snippetLoadError)
        XCTAssertTrue(model.snippets.isEmpty)
    }

    // MARK: - Insert

    func testInsertSendsExactCommandBytesWithoutReturn() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        await model.insertSnippet(try Snippet(name: "Probe", command: "echo probe"))

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertEqual(sent, [Data("echo probe".utf8)], "Insert must deliver the exact command bytes with no CR")
        XCTAssertNil(model.snippetErrorMessage)
    }

    // MARK: - Run confirmation lifecycle

    func testPresentRunConfirmationSendsNothingBeforeConfirm() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        let request = makeRunRequest()
        model.presentSnippetRunConfirmation(request)
        XCTAssertEqual(model.pendingSnippetRunRequest, request)
        XCTAssertEqual(model.currentSnippetRunRequest, request)

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "presenting the confirmation must send zero bytes")
    }

    func testConfirmedRunSendsExactBytesPlusCROnce() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        model.presentSnippetRunConfirmation(makeRunRequest(command: "echo probe"))
        await model.confirmSnippetRun()

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertEqual(
            sent,
            [Data("echo probe".utf8) + Data([0x0D])],
            "a confirmed Run must deliver the exact command bytes plus CR exactly once"
        )
        XCTAssertNil(model.pendingSnippetRunRequest)
        XCTAssertNil(model.snippetRunErrorMessage)
    }

    func testDuplicateConfirmSendsExactlyOnce() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        model.presentSnippetRunConfirmation(makeRunRequest())

        // A double-tap races two confirms onto the main actor.
        async let first: Void = model.confirmSnippetRun()
        async let second: Void = model.confirmSnippetRun()
        _ = await (first, second)
        // A late third tap after the confirmation is gone.
        await model.confirmSnippetRun()

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertEqual(sent.count, 1, "duplicate confirm must send exactly once")
    }

    func testSecondRunRequestReplacesPendingOne() throws {
        let (model, _, _, _) = try makeModel()
        let first = makeRunRequest(command: "first")
        let second = makeRunRequest(command: "second")
        model.presentSnippetRunConfirmation(first)
        model.presentSnippetRunConfirmation(second)
        XCTAssertEqual(model.pendingSnippetRunRequest, second, "a second Run replaces, never queues")
    }

    func testCancelRunConfirmationSendsNothing() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        model.presentSnippetRunConfirmation(makeRunRequest())
        model.cancelSnippetRunConfirmation()
        XCTAssertNil(model.pendingSnippetRunRequest)
        XCTAssertNil(model.currentSnippetRunRequest)

        await model.confirmSnippetRun()

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "a canceled confirmation must never send")
    }

    // MARK: - Stale / changed-session invalidation

    func testStaleGenerationRunConfirmIsNoOp() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        model.presentSnippetRunConfirmation(makeRunRequest())
        // A new placement claims the surface (rebind): the generation
        // bumps without a detach clear — the pending request goes stale.
        model.surfaceAttached()
        XCTAssertNil(model.currentSnippetRunRequest, "a stale request must not present")

        await model.confirmSnippetRun()

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "a stale-generation confirm must send nothing")
        XCTAssertNil(model.pendingSnippetRunRequest)
    }

    func testSurfaceDetachInvalidatesPendingRunRequest() throws {
        let (model, _, _, _) = try makeModel()
        model.presentSnippetRunConfirmation(makeRunRequest())
        model.surfaceDetached()
        XCTAssertNil(model.pendingSnippetRunRequest)
        XCTAssertNil(model.currentSnippetRunRequest)
    }

    func testBackgroundingInvalidatesPendingRunRequest() async throws {
        let (model, _, _, _) = try makeModel()
        model.presentSnippetRunConfirmation(makeRunRequest())
        await model.scenePhaseChanged(.background)
        XCTAssertNil(model.pendingSnippetRunRequest)
    }

    func testReconnectInvalidatesPendingRunRequest() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)
        model.presentSnippetRunConfirmation(makeRunRequest())

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        await transport.finishOutput()

        let deadline = Date().addingTimeInterval(5)
        while model.pendingSnippetRunRequest != nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(model.pendingSnippetRunRequest, "a reconnect must invalidate the pending Run")
    }

    // MARK: - Disconnect

    func testInsertAfterDisconnectSurfacesInlineErrorWithoutSending() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        await transport.remoteExit()
        let deadline = Date().addingTimeInterval(5)
        while model.state != .disconnected, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .disconnected, "a clean remote exit must land disconnected")

        await model.insertSnippet(try Snippet(name: "Probe", command: "echo probe"))

        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "a disconnected session must receive zero bytes")
        XCTAssertNotNil(model.snippetErrorMessage, "the failed Insert must surface an inline error")
    }

    func testConfirmedRunAfterDisconnectSurfacesInlineErrorWithoutSending() async throws {
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        await transport.remoteExit()
        let deadline = Date().addingTimeInterval(5)
        while model.state != .disconnected, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.state, .disconnected)

        model.presentSnippetRunConfirmation(makeRunRequest())
        await model.confirmSnippetRun()

        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "a disconnected session must receive zero bytes")
        XCTAssertNotNil(model.snippetRunErrorMessage, "the failed Run must surface an inline error")
        XCTAssertNotNil(model.pendingSnippetRunRequest, "the failed Run must retain the confirmation")
    }

    // MARK: - Management (Settings surface)

    func testManagementListsGlobalSnippetsOnly() async throws {
        let snippetStore = InMemorySnippetStore()
        let connection = try makeConnection(name: "scoped-host")
        try await snippetStore.save(try Snippet(name: "Global", command: "echo global"))
        try await snippetStore.save(try Snippet(name: "Scoped", command: "echo scoped", connectionID: connection.id))
        let management = SnippetManagementModel(store: snippetStore)

        await management.reload()

        XCTAssertEqual(management.snippets.map(\.name), ["Global"])
    }

    func testManagementSaveEditAndDelete() async throws {
        let snippetStore = InMemorySnippetStore()
        let management = SnippetManagementModel(store: snippetStore)

        let created = await management.save(name: "Probe", command: "echo one", editing: nil)
        XCTAssertNil(created)
        XCTAssertEqual(management.snippets.map(\.name), ["Probe"])

        let updated = await management.save(name: "Probe", command: "echo two", editing: management.snippets.first)
        XCTAssertNil(updated)
        XCTAssertEqual(management.snippets.first?.command, "echo two", "an edit must update the stored command")

        await management.delete(management.snippets.first!)
        XCTAssertTrue(management.snippets.isEmpty)
    }

    func testManagementSaveSurfacesEmptyFieldErrors() async throws {
        let management = SnippetManagementModel(store: InMemorySnippetStore())

        let nameError = await management.save(name: "  ", command: "echo x", editing: nil)
        XCTAssertNotNil(nameError, "an empty name must surface an error")

        let commandError = await management.save(name: "Probe", command: " \t ", editing: nil)
        XCTAssertNotNil(commandError, "an empty command must surface an error")
        XCTAssertTrue(management.snippets.isEmpty, "invalid snippets must not persist")
    }

    func testManagementSaveSurfacesDuplicateNameError() async throws {
        let snippetStore = InMemorySnippetStore()
        let management = SnippetManagementModel(store: snippetStore)

        let first = await management.save(name: "Dup", command: "echo one", editing: nil)
        XCTAssertNil(first)
        let second = await management.save(name: "Dup", command: "echo two", editing: nil)
        XCTAssertEqual(second, "A snippet named Dup already exists in this scope")
        XCTAssertEqual(management.snippets.count, 1, "the duplicate must not persist")
    }

    func testManagementSaveNeverSendsSessionBytes() async throws {
        let snippetStore = InMemorySnippetStore()
        let factory = ScriptedSessionTransportFactory(fallback: .succeed)
        let (model, _, _, _) = try makeModel(snippetStore: snippetStore, factory: factory)
        let active = await startAndWaitActive(model)
        XCTAssertTrue(active)

        let management = SnippetManagementModel(store: snippetStore)
        let error = await management.save(name: "Managed", command: "echo managed", editing: nil)
        XCTAssertNil(error)

        let transport = try XCTUnwrap(factory.transport(named: "snippet-unit"))
        let sent = await transport.sent
        XCTAssertTrue(sent.isEmpty, "saving a snippet must never send bytes to a session")
    }
}

/// A snippet store whose reads always fail, for the load-error path.
private actor FailingSnippetStore: SnippetStoreProtocol {
    func loadSnippets() async throws(PersistenceError) -> [Snippet] {
        throw .operationFailed("the test store rejected the read")
    }

    func snippet(id: UUID) async throws(PersistenceError) -> Snippet? { nil }

    func snippets(connectionID: UUID) async throws(PersistenceError) -> [Snippet] {
        throw .operationFailed("the test store rejected the read")
    }

    func save(_ snippet: Snippet) async throws(PersistenceError) {}

    func deleteSnippet(id: UUID) async throws(PersistenceError) {}

    func deleteSnippets(connectionID: UUID) async throws(PersistenceError) {}
}
