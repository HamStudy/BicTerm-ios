import Foundation
import SwiftTerm
import SwiftUI
import UIKit
import UserNotifications

// MARK: - Payload parsing

/// App-side OSC 777 payload parser. The registered handler REPLACES
/// SwiftTerm's built-in `case 777` dispatch (registered handlers run
/// first in `EscapeSequenceParser.dispatchOsc`), so the app owns the
/// parse semantics — kept identical to the fork's `oscNotification`:
/// `notify;title;body...`, where the body rejoins every remaining
/// semicolon-separated part, preserving semicolons verbatim. Malformed
/// payloads (invalid UTF-8, fewer than three parts, or a non-`notify`
/// prefix) are ignored.
enum TerminalNotificationParser {
    static func parse(_ payload: ArraySlice<UInt8>) -> (title: String, body: String)? {
        guard let text = String(bytes: payload, encoding: .utf8) else { return nil }
        let parts = text.components(separatedBy: ";")
        guard parts.count >= 3, parts[0] == "notify" else { return nil }
        return (title: parts[1], body: parts[2...].joined(separator: ";"))
    }
}

// MARK: - Local-notification sanitization

/// Sanitizes remote-controlled text before it reaches
/// UNUserNotificationCenter. Order matters: line breaks become spaces
/// FIRST (they are Cc and would otherwise be dropped, losing word
/// separation), then the remaining control (Cc) and format (Cf) scalars
/// are dropped, whitespace runs collapse to single spaces, and the
/// result is truncated by grapheme clusters.
enum TerminalNotificationSanitizer {
    static let titleLimit = 60
    static let bodyLimit = 120

    private static let lineBreakScalars: Set<Unicode.Scalar> = [
        "\r", "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    static func sanitize(_ text: String, limit: Int) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if lineBreakScalars.contains(scalar) {
                kept.append(" ")
            } else if scalar.properties.generalCategory == .control
                || scalar.properties.generalCategory == .format {
                continue
            } else {
                kept.append(scalar)
            }
        }
        var collapsed = ""
        var pendingSpace = false
        for character in String(kept) {
            if character.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace, !collapsed.isEmpty {
                    collapsed.append(" ")
                }
                pendingSpace = false
                collapsed.append(character)
            }
        }
        return collapsed.count > limit ? String(collapsed.prefix(limit)) : collapsed
    }
}

// MARK: - Banner model

/// One OSC 777 notify event as the foreground scene renders it.
struct TerminalNotificationBanner: Equatable, Sendable {
    let title: String
    let body: String
}

// MARK: - System notification posting

@MainActor
protocol TerminalNotificationPosting: AnyObject {
    func post(_ request: UNNotificationRequest)
}

/// Production poster: an opportunistic `UNUserNotificationCenter.add`.
/// Delivery is NEVER promised — the app does not request notification
/// authorization, and `SessionRegistry.didEnterBackground` eagerly
/// closes SSH transports, so no event arrives once backgrounded. This
/// path only serves events that fire while the app is inactive but
/// still alive (for example a non-key window state); without
/// authorization the system silently drops the request.
@MainActor
final class SystemNotificationPoster: TerminalNotificationPosting {
    func post(_ request: UNNotificationRequest) {
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}

// MARK: - Coordinator

/// Routes OSC 777 notify events per window-scene identity. Foreground
/// events publish a dismissible per-scene banner (replacement only
/// within the same scene; two scenes never clobber each other; expiry
/// is ~5 s and generation-checked so a stale timer can never clear a
/// newer banner). Events while the app is not active post at most ONE
/// sanitized local notification per session per cooldown window.
@MainActor
@Observable
final class TerminalNotificationCoordinator {
    private let poster: TerminalNotificationPosting
    private let isAppActive: @MainActor () -> Bool
    private let bannerLifetime: TimeInterval
    private let localPostCooldown: TimeInterval

    private(set) var banners: [String: TerminalNotificationBanner] = [:]
    private var generations: [String: UInt64] = [:]
    private var dismissTasks: [String: Task<Void, Never>] = [:]
    private var lastLocalPost: [String: Date] = [:]

    init(
        poster: TerminalNotificationPosting = SystemNotificationPoster(),
        isAppActive: (@MainActor () -> Bool)? = nil,
        bannerLifetime: TimeInterval = 5,
        localPostCooldown: TimeInterval = 5
    ) {
        self.poster = poster
        // The banner renders whenever the app is VISIBLE — .active or the
        // transient .inactive (app switcher, notification shade) — so only
        // a truly backgrounded app routes to the opportunistic local
        // notification. `applicationState == .active` is the wrong gate:
        // it is nondeterministically .inactive for long stretches under
        // UI-test automation (and during real scene transitions), which
        // would silently drop banners the user can still see.
        self.isAppActive = isAppActive ?? { UIApplication.shared.applicationState != .background }
        self.bannerLifetime = bannerLifetime
        self.localPostCooldown = localPostCooldown
    }

    /// Entry point for the OSC 777 handler registered on each SSH
    /// terminal. Malformed and non-`notify` payloads are ignored.
    func handle(payload: ArraySlice<UInt8>, sceneID: String) {
        guard let parsed = TerminalNotificationParser.parse(payload) else { return }
        if isAppActive() {
            publishBanner(
                TerminalNotificationBanner(title: parsed.title, body: parsed.body),
                for: sceneID
            )
        } else {
            postLocalNotification(parsed: parsed, sceneID: sceneID)
        }
    }

    func banner(for sceneID: String) -> TerminalNotificationBanner? {
        banners[sceneID]
    }

    /// Manual dismiss (the banner's × button). Bumps the generation so
    /// an in-flight auto-dismiss timer cannot clear a later banner.
    func dismissBanner(for sceneID: String) {
        generations[sceneID] = (generations[sceneID] ?? 0) &+ 1
        dismissTasks[sceneID]?.cancel()
        dismissTasks[sceneID] = nil
        banners[sceneID] = nil
    }

    /// Generation-guarded clear: only the CURRENT generation's clear
    /// takes effect. Internal for the coordinator's focused tests.
    func clearBannerIfCurrent(sceneID: String, generation: UInt64) {
        guard generations[sceneID] == generation else { return }
        banners[sceneID] = nil
        dismissTasks[sceneID] = nil
    }

    private func publishBanner(_ banner: TerminalNotificationBanner, for sceneID: String) {
        banners[sceneID] = banner
        let generation = (generations[sceneID] ?? 0) &+ 1
        generations[sceneID] = generation
        dismissTasks[sceneID]?.cancel()
        let lifetime = bannerLifetime
        dismissTasks[sceneID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.clearBannerIfCurrent(sceneID: sceneID, generation: generation)
        }
    }

    private func postLocalNotification(parsed: (title: String, body: String), sceneID: String) {
        let now = Date()
        if let last = lastLocalPost[sceneID], now.timeIntervalSince(last) < localPostCooldown {
            return
        }
        lastLocalPost[sceneID] = now
        let content = UNMutableNotificationContent()
        content.title = TerminalNotificationSanitizer.sanitize(
            parsed.title,
            limit: TerminalNotificationSanitizer.titleLimit
        )
        content.body = TerminalNotificationSanitizer.sanitize(
            parsed.body,
            limit: TerminalNotificationSanitizer.bodyLimit
        )
        // Stable per-scene identifier: a later post replaces the
        // previous one in Notification Center instead of stacking.
        poster.post(
            UNNotificationRequest(
                identifier: "bicterm.osc777.\(sceneID)",
                content: content,
                trigger: nil
            )
        )
    }
}

// MARK: - Surface configuration

/// SSH-surface notification configuration, applied at BOTH terminal
/// creation sites (the session cache's `TerminalSurface` and the
/// standalone `TerminalRepresentable`):
/// - `bellStyle = .soundAndVisual` — the CALayer flash makes BEL visible
///   even with the device muted. The flash is not XCUI-observable, so
///   this is asserted at the factory level.
/// - OSC 777 registration through SwiftTerm's public
///   `registerOscHandler(code: 777)`; the registered handler replaces
///   the built-in dispatch, so the app owns parsing.
///
/// The handler closure lives in the terminal's parser for the view's
/// lifetime and captures only Sendable values plus a WEAK coordinator
/// reference — it must never retain the (possibly evicted) surface or
/// its view.
enum TerminalNotificationRouting {
    @MainActor
    static func apply(
        to view: TerminalContainerView,
        coordinator: TerminalNotificationCoordinator?,
        sceneID: String
    ) {
        view.bellStyle = .soundAndVisual
        guard let coordinator else { return }
        view.getTerminal().registerOscHandler(code: 777) { [weak coordinator] payload in
            // SwiftTerm's feed path runs on the main thread (the surface
            // feed tasks hop to the main actor), so the synchronous
            // bridge is safe — the same contract as the OSC 52 delegate.
            MainActor.assumeIsolated {
                coordinator?.handle(payload: payload, sceneID: sceneID)
            }
        }
    }
}

// MARK: - Banner view

/// Dismissible in-scene banner for one OSC 777 notify event, rendered at
/// the top of the session scene next to the OSC 52 toast slot. Styling
/// reads the injected palette/typography/spacing parameters (NOT the
/// environment) for the same propagation reason as `Osc52ToastView`.
struct TerminalNotificationBannerView: View {
    let banner: TerminalNotificationBanner
    let palette: TerminalColors
    let typography: TerminalTypography
    let spacing: TerminalSpacing
    let onDismiss: () -> Void
    var sceneID: String = ""

    var body: some View {
        HStack(spacing: spacing.xs) {
            Image(systemName: "bell.badge.fill")
                .foregroundColor(palette.accent)
            VStack(alignment: .leading, spacing: spacing.xxxs) {
                Text(banner.title)
                    .font(typography.headline)
                    .foregroundColor(palette.foreground)
                    .lineLimit(1)
                    .accessibilityIdentifier("terminal-notification-title-\(sceneID)")
                Text(banner.body)
                    .font(typography.caption)
                    .foregroundColor(palette.foreground)
                    .lineLimit(2)
                    .accessibilityIdentifier("terminal-notification-body-\(sceneID)")
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(typography.caption)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel("Dismiss notification")
            .accessibilityIdentifier("terminal-notification-dismiss-\(sceneID)")
            .foregroundColor(palette.dimmed)
        }
        .padding(.horizontal, spacing.sm)
        .padding(.vertical, spacing.xs)
        .background(palette.selection.opacity(TerminalMetric.bannerFill))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("terminal-notification-banner-\(sceneID)")
    }
}
