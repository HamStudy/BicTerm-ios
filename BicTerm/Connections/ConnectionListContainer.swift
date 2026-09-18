import SwiftUI
import BicTermCore

struct ConnectionListContainer: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let store: SessionStore
    let herdConnect: HerdSessionCoordinator

    @State private var coverDescriptor: SessionStore.SessionDescriptor?
    @State private var herdrCoverSession: HerdrCoverSession?
    /// Cross-cover jump from the herdr chrome's session menu: the terminal
    /// cover is presented from the herdr cover's onDismiss — UIKit drops a
    /// presentation requested while the previous cover is still dismissing.
    @State private var pendingHerdrJump: SessionStore.SessionDescriptor?
    @State private var restorableSessions: [SessionStore.RestorableSession] = []
    @State private var switcherPresented = false

    private struct HerdrCoverSession: Identifiable {
        let id: UUID
    }

    var body: some View {
        VStack(spacing: 0) {
            if !restorableSessions.isEmpty {
                RestorableSessionsSection(
                    entries: restorableSessions,
                    onReconnect: { reconnectRestorable($0) },
                    onDismiss: { dismissRestorable($0) }
                )
            }

            ConnectionListView(
                fontModel: store.terminalFont,
                themeModel: store.theme,
                osc52Model: store.osc52Clipboard,
                onConnectRequested: handleConnect,
                onOpenSessions: { switcherPresented = true },
                onForgetHost: { connection in
                    Task { await forgetHostData(connection) }
                },
                onOpenHerd: openHerd
            )
        }
        .fullScreenCover(item: $coverDescriptor) { descriptor in
            Group {
                if let model = store.sceneModel(for: descriptor.id) {
                    SessionSceneView(
                        model: model,
                        store: store,
                        actions: SessionSceneActions(
                            onPickSession: { pickedID in
                                if let picked = store.descriptor(id: pickedID) {
                                    coverDescriptor = picked
                                }
                            },
                            onNewConnection: { coverDescriptor = nil },
                            onSessionClosed: {
                                if coverDescriptor?.id == descriptor.id {
                                    coverDescriptor = nil
                                }
                            }
                        )
                    )
                    // Session switches must REBUILD the scene (fresh
                    // representable identity) — otherwise SwiftUI updates
                    // the old placement in place and the terminal surface
                    // never swaps to the newly attached session.
                    .id(model.id)
                } else {
                    TerminalPlaceholderView(connectionName: descriptor.connection.name)
                }
            }
            .terminalStyle()
        }
        .sheet(isPresented: $switcherPresented) {
            SessionSwitcherView(
                store: store,
                currentSessionID: coverDescriptor?.id,
                onPick: { pickedID in
                    switcherPresented = false
                    if let picked = store.descriptor(id: pickedID) {
                        present(picked)
                    }
                },
                onNewConnection: { switcherPresented = false }
            )
            .terminalStyle()
        }
        .sheet(isPresented: mainWindowAgentSheetBinding) {
            if let request = store.agentPresenter.pendingRequest {
                AgentApprovalSheetView(
                    request: request,
                    sessionDisplayName: store.agentPresenter.routing?.sessionDisplayName ?? "Session",
                    onDecision: { store.agentPresenter.resolve($0) }
                )
            }
        }
        .fullScreenCover(item: $herdrCoverSession, onDismiss: {
            if let pending = pendingHerdrJump {
                pendingHerdrJump = nil
                coverDescriptor = pending
            }
        }) { cover in
            if let entry = HerdrWorkspaceCenter.shared.entry(id: cover.id) {
                herdrWorkspace(for: entry)
                    .id(entry.id)
                    // Herd machines connect only after this cover is up;
                    // their TOFU challenges must present ABOVE it (F3-B).
                    .modifier(HerdPromptPresenter(herdConnect: herdConnect))
                    .terminalStyle()
            }
        }
        // F3-B backstop: herd prompts present from the workspace cover
        // (or window); this one resolves any prompt left pending when the
        // workspace presentation is gone (e.g. the user closed it).
        .modifier(HerdPromptPresenter(herdConnect: herdConnect))
        .task {
            await reloadRestorableSessions()
            #if DEBUG
            // Cold launch starts the scene already .active, so the
            // onChange below never fires — replay the fixture here too
            // (didOpenHerdrFixture makes the call idempotent).
            if scenePhase == .active {
                openHerdrFixtureReplayOnce()
            }
            await SessionUITestDriver.run(store: store, present: present)
            #endif
        }
        // `initial: true`: a fast launch can reach .active BEFORE this view
        // subscribes, and a plain onChange then never fires — the herdr
        // fixture driver (and the restorable reload) would silently no-op.
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active {
                Task { await reloadRestorableSessions() }
                #if DEBUG
                openHerdrFixtureReplayOnce()
                #endif
            }
        }
        .sceneAppearance(coverDescriptor.map {
            store.effectiveTheme($0.registrySceneID)
        } ?? store.theme.preference)
    }

    private func handleConnect(_ connection: Connection) {
        if connection.herdrEnabled {
            // Embedded TUI (T5): the connection rides the workspace entry;
            // the embed runtime establishes the SSH bridge carrier (TOFU,
            // probe, per-machine bridge socket).
            presentHerdr(
                sessionID: HerdrWorkspaceCenter.shared.openEmbed(connection: connection)
            )
        } else {
            present(store.openSession(for: connection))
        }
    }

    private func openHerd(_ herd: Herd) {
        // T6: the herd entry carries its machines; the embed view resolves
        // one transport link per machine when it appears. Herd/connection
        // edits additionally re-seed the LIVE run's machine catalog on
        // each config reload (embed patch 0008), so attention-state
        // machines redial without reopening the workspace.
        Task { @MainActor in
            let lookup = HerdSessionCoordinator.liveLookup()
            var machines: [HerdMachineDescriptor] = []
            for machine in herd.machines {
                let connection = await lookup(machine.connectionID)
                machines.append(HerdMachineDescriptor(
                    endpointID: HerdDescriptor.endpointID(
                        herdID: herd.id, connectionID: machine.connectionID
                    ),
                    connectionID: machine.connectionID,
                    label: machine.label ?? connection?.name ?? "Missing connection",
                    sessionName: machine.sessionName
                ))
            }
            presentHerdr(sessionID: HerdrWorkspaceCenter.shared.openHerd(
                HerdDescriptor(herdID: herd.id, herdName: herd.name, machines: machines)
            ))
        }
    }

    @ViewBuilder
    private func herdrWorkspace(for entry: HerdrWorkspaceCenter.Entry) -> some View {
        HerdrEmbedWorkspaceView(
            endpointLabel: entry.label,
            onClose: {
                Task {
                    await HerdrWorkspaceCenter.shared.close(id: entry.id)
                }
                herdrCoverSession = nil
            },
            store: store,
            onPickSession: { pickedID in
                // iPhone jump: swap covers — dismiss this workspace, then
                // present the picked session's terminal cover (onDismiss).
                guard let picked = store.descriptor(id: pickedID) else { return }
                pendingHerdrJump = picked
                herdrCoverSession = nil
            },
            onNewConnection: { herdrCoverSession = nil },
            fontModel: store.terminalFont,
            embedConnection: entry.embedConnection,
            embedHerd: entry.herd,
            ownerID: entry.id,
            hostKeyVerifier: store.hostKeyVerifier,
            osc52Settings: Osc52ClipboardSettings()
        )
    }

    /// Herdr sessions present through the same path as SSH sessions: their
    /// own window on iPad (T12 user directive), a full-screen cover on
    /// iPhone. Mode-A connections carry the SSH bridge the embed runtime
    /// establishes; herds carry the machine catalog the embed view seeds.
    private func presentHerdr(sessionID: UUID) {
        if supportsMultipleWindows {
            openWindow(id: "herdr", value: SessionID(value: sessionID))
        } else {
            herdrCoverSession = HerdrCoverSession(id: sessionID)
        }
    }

    #if DEBUG
    @MainActor private static var didOpenHerdrFixture = false

    /// UI-test surface (`--uitest-herdr-embed`): the embedded TUI needs a
    /// workspace entry whose transport reads from the env-injected
    /// `HERDR_EMBED_SOCKET_PATH`; this fires the bare fixture entry from
    /// the first .active scene-phase transition (openWindow during scene
    /// startup creates windows that never surface on iPad).
    private func openHerdrFixtureReplayOnce() {
        guard !Self.didOpenHerdrFixture else { return }
        Self.didOpenHerdrFixture = true
        guard ProcessInfo.processInfo.arguments.contains("--uitest-herdr-embed") else { return }
        presentHerdr(sessionID: HerdrWorkspaceCenter.shared.open { _ in "Fixture" })
    }
    #endif

    private func reconnectRestorable(_ entry: SessionStore.RestorableSession) {
        restorableSessions.removeAll { $0.id == entry.id }
        present(store.openRestoredSession(
            snapshot: entry.snapshot,
            connection: entry.connection,
            initiatesReconnect: true
        ))
    }

    /// Permanently removes a stale restorable row: the persisted snapshot is
    /// deleted FIRST and the row leaves the list only when persistence
    /// confirms, so a failed deletion never fakes a disappearance that the
    /// next launch would undo.
    private func dismissRestorable(_ entry: SessionStore.RestorableSession) {
        Task {
            guard await store.dismissRestorableSession(entry) else { return }
            restorableSessions.removeAll { $0.id == entry.id }
        }
    }

    /// Per-host forget (T20): clears trust, stored passwords, restorable
    /// sessions, and herdr settings for one host through the same stores
    /// this container reads; the connection entry itself is kept.
    private func forgetHostData(_ connection: Connection) async {
        let service = HerdrHostForgetService(
            dependencies: .live(sessionStore: store)
        )
        _ = await service.forget(connection: connection)
        await reloadRestorableSessions()
    }

    /// Focus an existing host or reuse a dead one; live iPad sessions retain
    /// separate windows. iPhone keeps its connection-list cover.
    private func present(_ descriptor: SessionStore.SessionDescriptor) {
        if supportsMultipleWindows {
            let windowValue = store.hostingWindowValue(for: descriptor.id)
                ?? store.requestDeadWindowAttachment(for: descriptor.id)
                ?? descriptor.id
            openWindow(id: "terminal", value: SessionID(value: windowValue))
        } else {
            coverDescriptor = descriptor
        }
    }

    private func reloadRestorableSessions() async {
        restorableSessions = await store.loadRestorableSessions()
    }

    /// Fallback presentation surface for agent prompts whose originating
    /// scene no longer exists.
    private var mainWindowAgentSheetBinding: Binding<Bool> {
        Binding(
            get: { store.agentPresenter.routing?.target == .mainWindow },
            set: { presented in
                if !presented { store.agentPresenter.denyPendingIfMainWindow() }
            }
        )
    }
}
