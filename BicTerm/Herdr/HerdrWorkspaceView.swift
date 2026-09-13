import HerdrClientCore
import OSLog
import PhotosUI
import SwiftUI
import UIKit

/// Native herdr workspace chrome (integration doc §7 Option A): endpoint
/// header + phase badge, tab bar for the focused workspace, pane area
/// (committed surface cells when available, snapshot pane tree otherwise),
/// informational notification strip, and the version-gate diagnostic screen.
///
/// All rendering consumes immutable model state — snapshots and surfaces
/// applied inside the Rust core; no VT re-parse, no ANSI re-encode.
struct HerdrWorkspaceView: View {
    @Environment(\.terminalColors) private var colors
    @Environment(\.terminalTypography) private var typography
    @Environment(\.terminalSpacing) private var spacing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase

    let model: HerdrSessionModel
    let endpointLabel: String
    let onClose: () -> Void
    /// Global terminal font model: the pane surface renders at its live
    /// size, exactly like a terminal session without a per-window override.
    var fontModel: TerminalFontModel? = nil

    @State private var photoSelection: PhotosPickerItem?
    @State private var textPasteConfirmation: TextPasteConfirmation?
    @State private var imagePaste: PendingImagePaste?
    @State private var imagePasteError: String?

    private static let logger = Logger(
        subsystem: "com.bicterm.app.herdr",
        category: "workspace-chrome"
    )

    private var state: HerdrEndpointState? {
        guard let id = model.selectedEndpointID else { return nil }
        return model.endpoints[id]
    }

    var body: some View {
        ZStack {
            inputField
            VStack(spacing: 0) {
                header
                if let state {
                    if let probe = state.probe, !probe.isCompatible {
                        HerdrProbeDiagnosticView(
                            probe: probe,
                            onDismiss: onClose
                        )
                    } else if state.phase == .reconnecting {
                        reconnectingView(state: state)
                    } else if state.phase == .failed || state.phase == .disconnected,
                        let diagnostic = state.diagnostic {
                        HerdrDiagnosticView(
                            diagnostic: diagnostic,
                            endpointLabel: endpointLabel,
                            onReattach: reattachAction(for: diagnostic),
                            onDismiss: onClose
                        )
                    } else {
                        workspaceBody
                    }
                } else {
                    workspaceBody
                }
            }
        }
        .background(colors.background.ignoresSafeArea())
        // DEBUG evidence strip rides the ROOT overlay so input/lifecycle
        // echo stays visible in the diagnostic and reconnecting states too.
        .overlay(alignment: .bottom) {
            inputFeedbackStrip
                .allowsHitTesting(false)
        }
        // The remote owns the grid: the soft keyboard overlays instead of
        // compressing the pane area, so keyboard appearance never reads as
        // a geometry change (rotation and window resize still do).
        .ignoresSafeArea(.keyboard)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                model.sceneBecameActive()
                model.resumeFromSceneForeground()
            case .inactive:
                model.sceneResignedActive()
            case .background:
                beginBackgroundDetach()
            @unknown default:
                break
            }
        }
        .onAppear {
            // Informational (plan T16): record the chrome's Dynamic Type
            // context; survival itself is asserted by the UI test's
            // accessibility-size relaunch.
            Self.logger.info(
                "herdr chrome rendered at dynamic type size \(String(describing: dynamicTypeSize), privacy: .public)"
            )
        }
        .alert(
            "Large Paste",
            isPresented: textPasteConfirmationPresented,
            presenting: textPasteConfirmation
        ) { confirmation in
            Button("Paste") {
                sendTextPaste(
                    confirmation.text,
                    endpoint: confirmation.endpoint,
                    capturedPane: confirmation.capturedPane,
                    capturedBoot: confirmation.capturedBoot
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(
                "Paste \(confirmation.byteCount, format: .number.grouping(.never)) bytes into pane \(confirmation.capturedPane) on \(endpointLabel)?"
            )
        }
        .sheet(item: $imagePaste) { pending in
            HerdrImagePasteSheet(
                sourceBytes: pending.source.count,
                pixelWidth: pending.pixelWidth,
                pixelHeight: pending.pixelHeight,
                needsDownscale: pending.needsDownscale,
                destinationPane: pending.capturedPane,
                onSend: { preserve, factor in
                    imagePaste = nil
                    sendImagePaste(pending, preserveMetadata: preserve, downscaleFactor: factor)
                },
                onCancel: { imagePaste = nil }
            )
        }
        .alert(
            "Image Not Sent",
            isPresented: imagePasteErrorPresented,
            presenting: imagePasteError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private var textPasteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { textPasteConfirmation != nil },
            set: { if !$0 { textPasteConfirmation = nil } }
        )
    }

    private var imagePasteErrorPresented: Binding<Bool> {
        Binding(
            get: { imagePasteError != nil },
            set: { if !$0 { imagePasteError = nil } }
        )
    }

    /// Invisible first responder behind the chrome: hardware presses, soft
    /// keyboard text, and IME commits all land here and route into the
    /// model's ordered input lane. Consumed taps (pane overlays, buttons)
    /// belong to the views stacked above it.
    private var inputField: some View {
        HerdrInputFieldHost(
            onText: { text in
                guard let id = model.selectedEndpointID else { return }
                model.sendText(text, endpoint: id)
            },
            onKey: { key in
                guard let id = model.selectedEndpointID else { return }
                model.sendKey(key, endpoint: id)
            },
            onNavigate: { direction in
                guard let id = model.selectedEndpointID else { return }
                model.moveInputTarget(direction, endpoint: id)
            },
            onPasteRequest: beginPaste
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: spacing.sm) {
            VStack(alignment: .leading, spacing: spacing.xxs) {
                Text("Herdr — \(endpointLabel)")
                    .font(typography.headline)
                    .foregroundStyle(colors.foreground)
                    .accessibilityIdentifier("herdr-endpoint-label")
                if let state {
                    Text(phaseText(state.phase))
                        .font(typography.caption)
                        .foregroundStyle(phaseColor(state.phase))
                        .accessibilityIdentifier("herdr-status-badge")
                }
            }
            Spacer()
            if state?.phase == .online {
                Button("Detach", action: detach)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("herdr-detach")
                // A plain gesture button, not UIPasteControl: the system
                // control neither delivers responder-chain `paste(_:)` nor
                // dispatches added actions for synthesized taps on the
                // simulator, so its "consented read" cannot be exercised —
                // or trusted — here. The read stays gesture-mediated (doc
                // §8.2); hardware cmd+v keeps the consented `paste(_:)`
                // path in the input field.
                Button("Paste", action: beginPaste)
                    .font(typography.body)
                    .buttonStyle(.bordered)
                    .frame(width: 88, height: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("herdr-paste-control")
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    Image(systemName: "photo")
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Insert Photo")
                .accessibilityIdentifier("herdr-insert-photo")
                .onChange(of: photoSelection) { _, item in
                    guard let item else { return }
                    photoSelection = nil
                    beginPhotoPaste(item)
                }
            }
            Button("Disconnect", action: disconnect)
                .font(typography.body)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("herdr-disconnect")
        }
        // Clearance replaces the leading padding; trailing stays spacing.sm.
        .windowControlsClearance()
        .padding([.trailing, .top], spacing.sm)
        .padding(.bottom, spacing.xs)
    }

    // MARK: - Workspace body

    private var workspaceBody: some View {
        let snapshot = state?.snapshot
        let surface = state?.surface
        return VStack(spacing: 0) {
            if let snapshot {
                notificationStrip(snapshot: snapshot)
                tabBar(snapshot: snapshot)
                paneArea(snapshot: snapshot, surface: surface)
            } else {
                connectingIndicator
            }
            if state?.surfaceUnavailable == true {
                surfaceUnavailableNote
            }
        }
    }

    private var connectingIndicator: some View {
        VStack(spacing: spacing.sm) {
            ProgressView()
            Text("Connecting to Herdr")
                .font(typography.body)
                .foregroundStyle(colors.dimmed)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("herdr-connecting")
    }

    /// Global terminal font size — the same value a terminal session
    /// without a per-window override renders at. The pane surface draws
    /// its glyphs at this size (fit-clamped to the committed grid).
    private var effectiveFontSize: Double {
        fontModel?.size ?? TerminalFontSettings.defaultSize
    }

    /// Doc §6.3 visible reconnect state: bounded jittered backoff in
    /// progress, with the attempt count and a manual cancel. No retry
    /// continues past the bound.
    private func reconnectingView(state: HerdrEndpointState) -> some View {
        VStack(spacing: spacing.sm) {
            ProgressView()
            Text("Reconnecting to Herdr")
                .font(typography.body)
                .foregroundStyle(colors.foreground)
                .accessibilityIdentifier("herdr-reconnecting")
            if let attempt = state.reconnectAttempt {
                Text("Attempt \(attempt) of \(model.reconnectBackoff.maxAttempts)")
                    .font(typography.caption)
                    .foregroundStyle(colors.dimmed)
                    .accessibilityIdentifier("herdr-reconnecting-attempt")
            }
            Text("The workspace keeps running on the host while reconnecting.")
                .font(typography.caption)
                .foregroundStyle(colors.dimmed)
            Button("Cancel") {
                guard let id = model.selectedEndpointID else { return }
                model.cancelReconnect(endpoint: id)
            }
            .font(typography.body)
            .buttonStyle(.bordered)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityIdentifier("herdr-reconnect-cancel")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notificationStrip(snapshot: HerdrShellSnapshot) -> some View {
        let notes = Self.notifications(from: snapshot)
        return Group {
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: spacing.xxs) {
                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        Label(note, systemImage: "info.circle")
                            .font(typography.caption)
                            .foregroundStyle(colors.dimmed)
                            .lineLimit(2)
                            .accessibilityIdentifier("herdr-notification-\(index)")
                    }
                }
                .padding(.horizontal, spacing.sm)
                .padding(.vertical, spacing.xxs)
                .background(colors.selection.opacity(0.25))
            }
        }
    }

    /// Informational only (integration doc §11): remote announcements are
    /// never actionable here — no install/update commands are surfaced.
    static func notifications(from snapshot: HerdrShellSnapshot) -> [String] {
        var notes: [String] = []
        if let diagnostic = snapshot.configDiagnostic {
            notes.append("Server configuration: \(diagnostic)")
        }
        if let announcement = snapshot.productAnnouncement {
            notes.append(announcement.title)
        }
        if let update = snapshot.updateAvailable {
            notes.append("Update available on the host: \(update)")
        }
        return notes
    }

    private func tabBar(snapshot: HerdrShellSnapshot) -> some View {
        let workspaceID = snapshot.focusedWorkspaceID
            ?? snapshot.workspaces.first?.workspaceID
        let tabs = snapshot.tabs.filter { $0.workspaceID == workspaceID }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: spacing.xs) {
                ForEach(tabs, id: \.tabID) { tab in
                    // Read-only state, not a control: neither the herdr
                    // protocol core (HerdrClient exposes input/resize/
                    // clipboard only — no tab activation message) nor the
                    // session model offers tab activation, so a button here
                    // could only ever be a dead control.
                    TerminalBadge(
                        tab.label,
                        tint: tab.focused ? colors.foreground : colors.dimmed,
                        fill: tab.focused ? colors.selection : colors.background,
                        stroke: tab.focused ? colors.accent : colors.dimmed,
                        size: .tab,
                        shape: .rounded
                    )
                    .accessibilityLabel("Tab \(tab.number): \(tab.label)\(tab.focused ? ", selected" : "")")
                    .accessibilityIdentifier("herdr-tab-\(tab.number)")
                    .accessibilityAddTraits(tab.focused ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, spacing.sm)
            .padding(.bottom, spacing.xs)
        }
        .accessibilityIdentifier("herdr-tab-bar")
    }

    @ViewBuilder
    private func paneArea(
        snapshot: HerdrShellSnapshot,
        surface: HerdrPaneSurface?
    ) -> some View {
        Group {
            if let surface {
                HerdrPaneSurfaceView(
                    surface: surface,
                    paneMetadata: paneMetadata(from: snapshot),
                    inputTargetID: state?.inputTargetPaneID,
                    onPaneTap: { paneID in
                        guard let id = model.selectedEndpointID else { return }
                        model.setInputTarget(paneID: paneID, endpoint: id)
                    },
                    onGridChange: { cols, rows in
                        model.resize(cols: cols, rows: rows)
                    },
                    fontSize: effectiveFontSize
                )
            } else {
                snapshotPaneGrid(snapshot: snapshot)
            }
        }
        // The remote-copy banner needs tappable buttons, so it sits in its
        // own overlay rather than the hit-transparent feedback strip; as an
        // overlay it never compresses the pane grid into a phantom resize.
        .overlay(alignment: .top) {
            remoteClipboardBanner
        }
    }

    /// Doc §8.3: server clipboard bytes never touch the system pasteboard
    /// without this explicit action or the per-host opt-in. The wire
    /// message carries no pane id, so attribution is endpoint-level.
    @ViewBuilder
    private var remoteClipboardBanner: some View {
        if let pending = state?.pendingRemoteClipboard {
            HStack(spacing: spacing.xs) {
                Label(
                    "Clipboard from \(endpointLabel) — \(pending.byteCount) bytes",
                    systemImage: "doc.on.clipboard"
                )
                .font(typography.caption)
                .foregroundStyle(colors.foreground)
                .lineLimit(1)
                Spacer()
                Button("Copy") {
                    guard let id = model.selectedEndpointID else { return }
                    model.copyRemoteClipboardToPasteboard(endpoint: id)
                }
                .font(typography.caption)
                .buttonStyle(.bordered)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("herdr-copy-remote")
                Button("Always for This Host") {
                    guard let id = model.selectedEndpointID else { return }
                    model.setAutoCopyRemoteClipboard(true, endpoint: id)
                }
                .font(typography.caption)
                .buttonStyle(.bordered)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityIdentifier("herdr-autocopy-remote")
                Button {
                    guard let id = model.selectedEndpointID else { return }
                    model.dismissRemoteClipboard(endpoint: id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Dismiss clipboard banner")
                .accessibilityIdentifier("herdr-dismiss-remote-clipboard")
                .foregroundStyle(colors.dimmed)
            }
            .padding(.horizontal, spacing.sm)
            .padding(.vertical, spacing.xs)
            .background(colors.selection.opacity(TerminalMetric.bannerFill))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("herdr-remote-clipboard-banner")
        }
    }

    /// Transient input feedback overlaid on the canvas: strips in the
    /// layout flow would compress the pane area, and every compression
    /// reads as a grid change (a resize the remote never asked for).
    private var inputFeedbackStrip: some View {
        VStack(spacing: 0) {
            if let note = state?.inputNote {
                Text(note.message)
                    .font(typography.caption)
                    .foregroundStyle(colors.dimmed)
                    .padding(.horizontal, spacing.sm)
                    .padding(.vertical, spacing.xxs)
                    .accessibilityIdentifier("herdr-input-note")
            }
            #if DEBUG
            if HerdrWorkspaceUITest.isEnabled {
                Text("pasteboard r:\(HerdrPasteboard.readCount) w:\(HerdrPasteboard.writeCount)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(colors.dimmed)
                    .accessibilityIdentifier("herdr-pasteboard-stats")
                Text(model.debugInputEcho.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(colors.dimmed)
                    .frame(maxWidth: .infinity, maxHeight: 72, alignment: .leading)
                    .padding(.horizontal, spacing.sm)
                    .accessibilityIdentifier("herdr-input-echo")
                    .onChange(of: model.debugInputEcho, initial: true) {
                        HerdrWorkspaceUITest.currentInputEcho = model.debugInputEcho.joined(separator: "\n")
                    }
                Text(model.debugLifecycleLog.joined(separator: "\n"))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(colors.dimmed)
                    .frame(maxWidth: .infinity, maxHeight: 72, alignment: .leading)
                    .padding(.horizontal, spacing.sm)
                    .accessibilityIdentifier("herdr-lifecycle-echo")
                if model.debugAppliedChunks >= HerdrWorkspaceUITest.currentScriptChunkCount ?? .max {
                    Text("ready")
                        .font(typography.caption)
                        .accessibilityIdentifier("herdr-replay-ready")
                        .onAppear {
                            TestHardwareKeyInjector.herdrInputField?.becomeFirstResponder()
                            HerdrWorkspaceUITest.keyInjector?.startNow()
                        }
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.background.opacity(0.9))
    }

    /// Snapshot-driven pane tree (identity, focus, cwd): the committed
    /// FFI cannot hand over cell surfaces yet (probe evidence), so until a
    /// surface commits the pane tree renders from the authoritative
    /// snapshot metadata. The layout is presentation-only — the remote
    /// owns the real geometry, which arrives with the surface.
    private func snapshotPaneGrid(snapshot: HerdrShellSnapshot) -> some View {
        let columns = [GridItem(.flexible()), GridItem(.flexible())]
        return ScrollView {
            LazyVGrid(columns: columns, spacing: spacing.xs) {
                ForEach(snapshot.panes, id: \.paneID) { pane in
                    VStack(alignment: .leading, spacing: spacing.xxs) {
                        HStack(spacing: spacing.xxs) {
                            if pane.focused {
                                Image(systemName: "rectangle.inset.filled")
                                    .foregroundStyle(colors.accent)
                            }
                            Text(pane.label ?? pane.paneID)
                                .font(typography.caption.weight(.semibold))
                                .foregroundStyle(colors.foreground)
                        }
                        if let cwd = pane.cwd {
                            Text(cwd)
                                .font(typography.caption)
                                // dimmed on the focused pane's selection@0.6
                                // fill measures ~4.0:1 — below WCAG AA; a
                                // 0.7-weight foreground keeps the secondary
                                // hierarchy at ~6:1. Unfocused panes (0.25
                                // fill) keep dimmed at ~5.3:1.
                                .foregroundStyle(pane.focused ? colors.foreground.opacity(0.7) : colors.dimmed)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(spacing.xs)
                    .background(colors.selection.opacity(pane.focused ? 0.6 : 0.25), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(pane.focused ? colors.accent : colors.dimmed.opacity(0.5), lineWidth: pane.focused ? 2 : 1)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(paneAccessibilityLabel(pane))
                    .accessibilityIdentifier("herdr-pane-\(pane.paneID)")
                    .accessibilityAddTraits(pane.focused ? [.isSelected] : [])
                }
            }
            .padding(spacing.sm)
        }
    }

    private var surfaceUnavailableNote: some View {
        Text("Live pane surfaces are unavailable in this build; showing the workspace pane tree.")
            .font(typography.caption)
            .foregroundStyle(colors.dimmed)
            .padding(.horizontal, spacing.sm)
            .padding(.vertical, spacing.xxs)
            .accessibilityIdentifier("herdr-surface-unavailable")
    }

    // MARK: - Paste flow (doc §8.2/§8.4)

    private struct TextPasteConfirmation: Identifiable {
        let id = UUID()
        let text: String
        let endpoint: HerdrEndpointID
        let capturedPane: String
        let capturedBoot: String
        var byteCount: Int { text.utf8.count }
    }

    private struct PendingImagePaste: Identifiable {
        let id = UUID()
        let source: Data
        let endpoint: HerdrEndpointID
        let capturedPane: String
        let capturedBoot: String
        let pixelWidth: Int
        let pixelHeight: Int
        let needsDownscale: Bool
    }

    /// Entry point for every paste gesture (paste button, cmd+v). The
    /// destination pane and endpoint boot are captured BEFORE the
    /// pasteboard read, and the send revalidates both — a paste never
    /// lands wherever focus happens to sit later.
    private func beginPaste() {
        guard let id = model.selectedEndpointID,
              let current = model.endpoints[id],
              let pane = current.inputTargetPaneID,
              let boot = current.snapshot?.bootID else { return }
        if HerdrPasteboard.hasStrings, let text = HerdrPasteboard.readText() {
            handleTextPaste(text, endpoint: id, capturedPane: pane, capturedBoot: boot)
        } else if HerdrPasteboard.hasImages, let data = HerdrPasteboard.readImageData() {
            handleImagePaste(data, endpoint: id, capturedPane: pane, capturedBoot: boot)
        }
    }

    private func handleTextPaste(
        _ text: String, endpoint: HerdrEndpointID, capturedPane: String, capturedBoot: String
    ) {
        switch HerdrClipboard.classifyTextPaste(text) {
        case .empty:
            break
        case .ready(let approved):
            sendTextPaste(
                approved, endpoint: endpoint, capturedPane: capturedPane, capturedBoot: capturedBoot
            )
        case .needsConfirmation(let approved):
            textPasteConfirmation = TextPasteConfirmation(
                text: approved, endpoint: endpoint,
                capturedPane: capturedPane, capturedBoot: capturedBoot
            )
        case .tooLarge:
            // The model gate records the typed note; nothing is sent.
            model.pasteText(text, endpoint: endpoint)
        }
    }

    private func sendTextPaste(
        _ text: String, endpoint: HerdrEndpointID, capturedPane: String, capturedBoot: String
    ) {
        guard let current = model.endpoints[endpoint],
              current.inputTargetPaneID == capturedPane,
              current.snapshot?.bootID == capturedBoot else {
            model.notePasteTargetChanged(endpoint: endpoint)
            return
        }
        model.pasteText(text, endpoint: endpoint)
    }

    private func handleImagePaste(
        _ data: Data, endpoint: HerdrEndpointID, capturedPane: String, capturedBoot: String
    ) {
        guard data.count <= HerdrClipboard.maxImagePayloadBytes else {
            imagePasteError = HerdrClipboard.ImagePasteError.exceedsCap.userMessage
            return
        }
        guard let dimensions = HerdrClipboard.imageDimensions(of: data) else {
            imagePasteError = HerdrClipboard.ImagePasteError.undecodable.userMessage
            return
        }
        let needsDownscale: Bool
        switch HerdrClipboard.prepareImage(from: data) {
        case .success:
            needsDownscale = false
        case .failure(.needsDownscale):
            needsDownscale = true
        case .failure(let error):
            imagePasteError = error.userMessage
            return
        }
        imagePaste = PendingImagePaste(
            source: data, endpoint: endpoint, capturedPane: capturedPane,
            capturedBoot: capturedBoot, pixelWidth: dimensions.width,
            pixelHeight: dimensions.height, needsDownscale: needsDownscale
        )
    }

    private func beginPhotoPaste(_ item: PhotosPickerItem) {
        guard let id = model.selectedEndpointID,
              let current = model.endpoints[id],
              let pane = current.inputTargetPaneID,
              let boot = current.snapshot?.bootID else { return }
        Task {
            do {
                guard let streamed = try await item.loadTransferable(type: StreamedImage.self)
                else { return }
                handleImagePaste(streamed.data, endpoint: id, capturedPane: pane, capturedBoot: boot)
            } catch let error as HerdrClipboard.ImagePasteError {
                imagePasteError = error.userMessage
            } catch {
                imagePasteError = "The photo could not be loaded."
            }
        }
    }

    private func sendImagePaste(
        _ pending: PendingImagePaste, preserveMetadata: Bool, downscaleFactor: Double
    ) {
        let prepared: Result<HerdrClipboard.PreparedImage, HerdrClipboard.ImagePasteError>
        if pending.needsDownscale {
            let maxPixel = max(
                1,
                Int(Double(max(pending.pixelWidth, pending.pixelHeight)) * downscaleFactor)
            )
            prepared = HerdrClipboard.prepareImage(
                from: pending.source, maxPixelSize: maxPixel, preserveMetadata: preserveMetadata
            )
        } else {
            prepared = HerdrClipboard.prepareImage(
                from: pending.source, preserveMetadata: preserveMetadata
            )
        }
        guard case .success(let image) = prepared else {
            imagePasteError = "The image could not be prepared at the chosen size."
            return
        }
        guard let current = model.endpoints[pending.endpoint],
              current.inputTargetPaneID == pending.capturedPane,
              current.snapshot?.bootID == pending.capturedBoot else {
            model.notePasteTargetChanged(endpoint: pending.endpoint)
            return
        }
        model.sendClipboardImage(image, endpoint: pending.endpoint)
    }

    // MARK: - Actions

    private func detach() {
        guard let id = model.selectedEndpointID else { return }
        Task {
            await model.detach(endpoint: id, reason: .user)
        }
    }

    private func reattachAction(for diagnostic: HerdrDiagnostic) -> (() -> Void)? {
        guard diagnostic.reattachOffered, let id = model.selectedEndpointID,
              model.reconnectSources[id] != nil else { return nil }
        return { model.reconnect(endpoint: id) }
    }

    /// Doc §10 background policy: the finite detach runs inside the system's
    /// granted background window; the expiration handler only ends the task
    /// (the detach itself is sub-second — the bound is the safety net).
    private func beginBackgroundDetach() {
        var taskID = UIBackgroundTaskIdentifier.invalid
        taskID = UIApplication.shared.beginBackgroundTask(
            withName: "herdr detach",
            expirationHandler: {
                let expired = taskID
                Task { @MainActor in
                    UIApplication.shared.endBackgroundTask(expired)
                }
            }
        )
        let granted = taskID
        Task { @MainActor in
            await model.suspendForSceneBackground()
            if granted != .invalid {
                UIApplication.shared.endBackgroundTask(granted)
            }
        }
    }

    private func disconnect() {
        Task {
            await model.disconnectAll()
            onClose()
        }
    }

    // MARK: - Helpers

    private func paneMetadata(from snapshot: HerdrShellSnapshot) -> [String: String] {
        var metadata: [String: String] = [:]
        for pane in snapshot.panes where pane.paneID == snapshot.focusedPaneID {
            metadata[pane.paneID] = pane.cwd ?? pane.label ?? ""
        }
        for pane in snapshot.panes where pane.paneID != snapshot.focusedPaneID {
            metadata[pane.paneID] = pane.label ?? ""
        }
        return metadata
    }

    private func paneAccessibilityLabel(_ pane: HerdrPane) -> String {
        var parts = ["Pane \(pane.paneID)"]
        parts.append(pane.focused ? "focused" : "background")
        if let label = pane.label {
            parts.append(label)
        }
        if let cwd = pane.cwd {
            parts.append(cwd)
        }
        return parts.joined(separator: ", ")
    }

    private func phaseText(_ phase: HerdrEndpointPhase) -> String {
        switch phase {
        case .connecting: "Connecting"
        case .online: "Online"
        case .reconnecting: "Reconnecting"
        case .disconnected: "Disconnected"
        case .failed: "Failed"
        }
    }

    private func phaseColor(_ phase: HerdrEndpointPhase) -> Color {
        switch phase {
        case .connecting: colors.dimmed
        case .online: colors.success
        case .reconnecting: colors.accent
        case .disconnected: colors.dimmed
        case .failed: colors.error
        }
    }
}

/// Streams a picked photo into memory through a file representation so the
/// 16 MiB cap is enforced DURING the load (doc §8.4), before the whole
/// object is ever retained.
private struct StreamedImage: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { file in
            switch HerdrClipboard.readCapped(url: file.file) {
            case .success(let data):
                return StreamedImage(data: data)
            case .failure(let error):
                throw error
            }
        }
    }
}

private extension HerdrClipboard.ImagePasteError {
    var userMessage: String {
        switch self {
        case .exceedsCap: "The image exceeds the 16 MB clipboard limit."
        case .undecodable: "The image could not be decoded."
        case .encodeFailed: "The image could not be re-encoded."
        case .needsDownscale: "The image must be downscaled first."
        }
    }
}
