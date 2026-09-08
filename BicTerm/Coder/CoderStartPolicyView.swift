import BicTermCore
import SwiftUI

/// Editor control for the start-stopped policy (spec §6.1): OFF by default;
/// turning it on requires confirming a dialog that names the cost
/// implication of provisioning runs.
struct CoderStartPolicyRow: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    @Binding var isOn: Bool
    @State private var confirmEnable = false

    var body: some View {
        Toggle(isOn: Binding(
            get: { isOn },
            set: { wantsOn in
                if wantsOn {
                    confirmEnable = true
                } else {
                    isOn = false
                }
            }
        )) {
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text("Start Stopped Workspaces")
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
                Text("When you connect, send one start request (reason: ssh_connection) and follow the build until the workspace is ready.")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
            }
        }
        .tint(colors.accent)
        .accessibilityIdentifier("coder-start-policy-toggle")
        .confirmationDialog(
            "Allow starting stopped workspaces?",
            isPresented: $confirmEnable,
            titleVisibility: .visible
        ) {
            Button("Allow Starts") {
                isOn = true
            }
            .accessibilityIdentifier("coder-start-policy-confirm")
            Button("Keep Off", role: .cancel) {}
        } message: {
            Text("Starting a workspace can incur infrastructure cost and runs provisioning code. BicTerm sends exactly one start request per connection attempt and never answers template parameters for you.")
        }
    }
}

/// Connect-time execution of the Coder start policy: resolves the
/// workspace fresh (dormancy and parameter gates never mutate anything),
/// starts stopped workspaces only when the policy is explicitly ON, follows
/// the build with the layered readiness display, and hands the connection
/// to the session layer once the workspace is ready.
struct CoderStartFlowView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing

    let connection: Connection
    let onComplete: () -> Void
    let onCancel: () -> Void

    enum Screen {
        case resolving
        case progress
        case notice(String)
        case notConnectable(state: String)
        case actionRequired(title: String, message: String, candidates: [CoderWorkspaceAgent])
        case failed(CoderStartFailure)
    }

    @State private var starter = CoderWorkspaceStarter()
    @State private var screen: Screen = .resolving
    @State private var ranOnce = false

    var body: some View {
        NavigationStack {
            content
                .padding(spacing.lg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colors.background)
                .navigationTitle(connection.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") { onCancel() }
                            .accessibilityIdentifier("coder-start-close")
                    }
                }
        }
        .interactiveDismissDisabled(screenIsProgress)
        .task {
            guard !ranOnce else { return }
            ranOnce = true
            await run()
        }
    }

    private var screenIsProgress: Bool {
        if case .progress = screen { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        switch screen {
        case .resolving:
            VStack(spacing: spacing.sm) {
                ProgressView()
                    .tint(colors.accent)
                Text("Resolving workspace…")
                    .font(typography.body)
                    .foregroundColor(colors.foreground)
            }
        case .progress:
            progressScreen
        case .notice(let message):
            noticeScreen(message)
        case .notConnectable(let state):
            notConnectableScreen(state)
        case .actionRequired(let title, let message, let candidates):
            actionRequiredScreen(title: title, message: message, candidates: candidates)
        case .failed(let failure):
            failureScreen(failure)
        }
    }

    private var progressScreen: some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            HStack(spacing: spacing.sm) {
                ProgressView()
                    .tint(colors.accent)
                Text("Starting workspace")
                    .font(typography.headline)
                    .foregroundColor(colors.foreground)
            }

            Grid(alignment: .leading, horizontalSpacing: spacing.sm, verticalSpacing: spacing.xs) {
                layerRow(label: "Build", value: buildPhaseText)
                layerRow(label: "Agent connection", value: agentPhaseText)
                layerRow(label: "Agent lifecycle", value: lifecyclePhaseText)
            }

            Text("Following the build for up to 10 minutes. Starting can incur cost — you confirmed this connection's start policy.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)

            Spacer()
            fixtureCountLabel
        }
    }

    private var buildPhaseText: String {
        switch starter.phase {
        case .idle, .checkingParameters: "not started"
        case .starting: "requesting start"
        case .waitingForBuild(let status): status
        case .waitingForAgent: "running"
        case .ready: "running"
        case .failed: "failed"
        }
    }

    private var agentPhaseText: String {
        switch starter.phase {
        case .idle, .checkingParameters, .starting: "waiting for build"
        case .waitingForBuild: "waiting for build"
        case .waitingForAgent(let status): status.components(separatedBy: " · ").first ?? status
        case .ready: "connected"
        case .failed: "unknown"
        }
    }

    private var lifecyclePhaseText: String {
        switch starter.phase {
        case .idle, .checkingParameters, .starting, .waitingForBuild:
            "waiting for build"
        case .waitingForAgent(let status):
            status.components(separatedBy: " · ").dropFirst().first ?? "unknown"
        case .ready:
            "ready"
        case .failed:
            "failed"
        }
    }

    private func layerRow(label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
            Text(value)
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .accessibilityIdentifier("coder-start-layer-\(label.replacingOccurrences(of: " ", with: "-").lowercased())")
        }
    }

    private func noticeScreen(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            header(icon: "arrow.triangle.2.circlepath", title: "Workspace build changed", tint: colors.accent)
            Text(message)
                .font(typography.body)
                .foregroundColor(colors.foreground)
            Button {
                onComplete()
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.accent)
            .accessibilityIdentifier("coder-start-continue")
            Spacer()
            fixtureCountLabel
        }
    }

    private func notConnectableScreen(_ state: String) -> some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            header(icon: "lock.fill", title: "Workspace not connectable", tint: colors.error)
            Text("The workspace is currently “\(state)”. This connection's start policy is off, so BicTerm did not start it and no start request was sent.")
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .accessibilityIdentifier("coder-not-connectable-message")
            Text("Turn on “Start Stopped Workspaces” in the connection editor if you want connecting to start it explicitly.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
            Button {
                onCancel()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(colors.accent)
            .accessibilityIdentifier("coder-not-connectable-close")
            Spacer()
            fixtureCountLabel
        }
    }

    private func actionRequiredScreen(
        title: String,
        message: String,
        candidates: [CoderWorkspaceAgent]
    ) -> some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            header(icon: "exclamationmark.triangle.fill", title: title, tint: colors.error)
            Text(message)
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .accessibilityIdentifier("coder-action-required-message")
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: spacing.xs) {
                    Text("Connected agents")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                    ForEach(candidates) { agent in
                        VStack(alignment: .leading, spacing: spacing.xxxs) {
                            Text(agent.name)
                                .font(typography.body)
                                .foregroundColor(colors.foreground)
                            Text(agent.id.uuidString)
                                .font(typography.caption)
                                .foregroundColor(colors.dimmed)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("coder-agent-candidate-\(agent.id.uuidString)")
                    }
                }
                .accessibilityIdentifier("coder-agent-candidates")
            }
            Text("BicTerm never changes workspace lifecycle state, answers template parameters, or reactivates dormant workspaces on its own.")
                .font(typography.caption)
                .foregroundColor(colors.dimmed)
            Button {
                onCancel()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(colors.accent)
            .accessibilityIdentifier("coder-action-required-close")
            Spacer()
            fixtureCountLabel
        }
    }

    private func failureScreen(_ failure: CoderStartFailure) -> some View {
        VStack(alignment: .leading, spacing: spacing.md) {
            header(icon: "xmark.octagon.fill", title: failure.title, tint: colors.error)
            Text(failure.message)
                .font(typography.body)
                .foregroundColor(colors.foreground)
                .accessibilityIdentifier("coder-start-error-message")

            if !starter.logTrail.isEmpty {
                VStack(alignment: .leading, spacing: spacing.xxxs) {
                    Text("Start activity")
                        .font(typography.caption)
                        .foregroundColor(colors.dimmed)
                    ScrollView {
                        VStack(alignment: .leading, spacing: spacing.xxxs) {
                            ForEach(Array(starter.logTrail.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(typography.caption)
                                    .foregroundColor(colors.dimmed)
                            }
                        }
                    }
                    .frame(maxHeight: spacing.xxl * 3)
                }
            }

            Button {
                Task { await run() }
            } label: {
                Text("Retry Start")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(colors.accent)
            .accessibilityIdentifier("coder-retry-start")

            Button {
                onCancel()
            } label: {
                Text("Close")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(colors.dimmed)
            .accessibilityIdentifier("coder-start-error-close")
            Spacer()
            fixtureCountLabel
        }
    }

    private func header(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: spacing.sm) {
            Image(systemName: icon)
                .font(typography.headline)
                .foregroundColor(tint)
                .accessibilityHidden(true)
            Text(title)
                .font(typography.headline)
                .foregroundColor(colors.foreground)
        }
    }

    private var fixtureCountLabel: some View {
        #if DEBUG
        Group {
            if ProcessInfo.processInfo.arguments.contains("--uitest-coder-fake-validation") {
                Text("start-posts: \(UITestCoderFixtureState.shared.startPostCount)")
                    .font(typography.caption)
                    .foregroundColor(colors.dimmed)
                    .accessibilityIdentifier("coder-start-post-count")
            }
        }
        #else
        EmptyView()
        #endif
    }

    // MARK: - Flow

    private func run() async {
        screen = .resolving
        guard let reference = connection.coderRef else {
            screen = .actionRequired(
                title: "Incomplete Coder connection",
                message: "This connection has no server/workspace reference. Re-select them in the connection editor.",
                candidates: []
            )
            return
        }

        let services = AppServices.shared
        guard let server = try? await services.coderServerStore.coderServer(id: reference.serverID) else {
            let knownServers = (try? await services.coderServerStore.loadCoderServers()) ?? []
            let knownList = knownServers.map { "\($0.id.uuidString.prefix(8)):\($0.name)" }.joined(separator: ", ")
            let suffix = knownServers.isEmpty ? "store empty" : "store has [\(knownList)]"
            screen = .actionRequired(
                title: "Coder server removed",
                message: "The server this connection was created against is no longer configured (\(suffix)). Re-add it or edit the connection.",
                candidates: []
            )
            return
        }
        guard let token = try? await services.coderTokenStore.token(for: server.tokenKeychainTag),
              !token.isEmpty else {
            screen = .actionRequired(
                title: "Authentication required",
                message: "No Coder session token is stored for this server. Reauthenticate it in Settings.",
                candidates: []
            )
            return
        }

        let detail: CoderWorkspaceDetail
        do {
            detail = try await starter.fetchWorkspace(
                server: server,
                token: token,
                workspaceID: reference.workspaceID
            )
        } catch let failure {
            screen = .failed(failure)
            return
        }

        if detail.isDormant {
            screen = .actionRequired(
                title: "Workspace is dormant",
                message: "The server marked “\(detail.name)” dormant. Reactivate it in the Coder dashboard, then connect again.",
                candidates: []
            )
            return
        }

        if detail.isRunning {
            switch agentReResolution(detail: detail) {
            case .proceed(let notice):
                if let notice {
                    screen = .notice(notice)
                } else {
                    onComplete()
                }
            case .actionRequired(let title, let message, let candidates):
                screen = .actionRequired(title: title, message: message, candidates: candidates)
            }
            return
        }

        guard connection.protocolOptions["coder.startPolicy"]?.boolValue == true else {
            screen = .notConnectable(state: detail.latestBuild.status)
            return
        }

        screen = .progress
        if let failure = await starter.start(
            server: server,
            token: token,
            workspaceID: reference.workspaceID,
            agentID: connection.protocolOptions["coder.agentID"]?.stringValue.flatMap(UUID.init(uuidString:))
        ) {
            if failure == .parameterMismatch {
                screen = .actionRequired(title: failure.title, message: failure.message, candidates: [])
            } else {
                screen = .failed(failure)
            }
            return
        }
        if let fresh = try? await starter.fetchWorkspace(
            server: server,
            token: token,
            workspaceID: reference.workspaceID
        ) {
            switch agentReResolution(detail: fresh) {
            case .proceed(let notice):
                if let notice {
                    screen = .notice(notice)
                } else {
                    onComplete()
                }
            case .actionRequired(let title, let message, let candidates):
                screen = .actionRequired(title: title, message: message, candidates: candidates)
            }
        } else {
            onComplete()
        }
    }

    enum AgentReResolution {
        case proceed(notice: String?)
        case actionRequired(title: String, message: String, candidates: [CoderWorkspaceAgent])
    }

    /// Spec §5.2 stale-build rule at connect time: a saved explicit agent
    /// pick that vanished from the current build always comes back to the user.
    /// Continuing with a different UUID would leave the immutable persisted
    /// connection pointing at the stale agent.
    private func agentReResolution(detail: CoderWorkspaceDetail) -> AgentReResolution {
        let connected = detail.latestBuild.agents.filter(\.isConnected)
        let savedID = connection.protocolOptions["coder.agentID"]?.stringValue.flatMap(UUID.init(uuidString:))
        return Self.agentReResolution(savedAgentID: savedID, connectedAgents: connected)
    }

    static func agentReResolution(
        savedAgentID: UUID?,
        connectedAgents: [CoderWorkspaceAgent]
    ) -> AgentReResolution {
        if let savedAgentID,
           connectedAgents.contains(where: { $0.id == savedAgentID }) {
            return .proceed(notice: nil)
        }
        guard savedAgentID != nil || connectedAgents.count > 1 else {
            return .proceed(notice: nil)
        }
        return .actionRequired(
            title: "Agent selection required",
            message: "Open this connection in the editor and explicitly pick an agent from the current build.",
            candidates: connectedAgents
        )
    }
}
