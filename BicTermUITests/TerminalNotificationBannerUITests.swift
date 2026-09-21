import XCTest

/// OSC 777 notify banners on the REAL SSH session surface: the fixture
/// session (hop1 sshd on 12222, pretrusted) runs a `printf` that emits
/// `ESC ] 777 ; notify ; Build finished ; done BEL` through the live
/// transport, and the session scene must surface the dismissible banner
/// with the exact parsed title and body. The banner auto-dismisses after
/// ~5 s, so the assertions run as soon as the AX tree surfaces it (the
/// same AX-tree receipt discipline as `Osc52ToastUITests`).
///
/// The fixture shell sources the host user's zshrc, whose network
/// lookups can delay the first prompt — and therefore the driver-sent
/// command's execution — by tens of seconds under parallel-suite load.
/// Every command-driven assertion is therefore gated on the payload
/// reaching the scene's raw tail (`scene-tail-Alpha`) FIRST, then on
/// the banner itself.
///
/// The malformed case pins the failure QA: a payload without the
/// `notify;title;body` shape produces no banner and no crash, and the
/// session keeps processing output afterwards.
@MainActor
final class TerminalNotificationBannerUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launchSession(command: String) {
        app.launchArguments = [
            "--uitest-reset",
            "--uitest-seed-keys",
            "--uitest-sessions",
            "--uitest-pretrust-fixtures",
            "--uitest-open-session", "Alpha",
            "--uitest-session-command", command,
        ]
        app.launch()

        let sceneTitle = app.descendants(matching: .any)["scene-title-Alpha"]
        XCTAssertTrue(
            sceneTitle.waitForExistence(timeout: 30),
            "the Alpha session scene must open before the command can run"
        )
        // The UITest driver sends the command only once the registry
        // reports the session active — under fixture contention that
        // can trail the scene by many seconds, so gate every
        // command-driven assertion on the active state, not on scene
        // appearance.
        let status = app.staticTexts["scene-status-Alpha"]
        XCTAssertTrue(
            waitForLabel(status, contains: "status:active", timeout: 45),
            "the Alpha session must reach active before its command runs"
        )
    }

    private func waitForLabel(
        _ element: XCUIElement,
        contains fragment: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", fragment)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private var tail: XCUIElement {
        app.staticTexts["scene-tail-Alpha"]
    }

    private var banner: XCUIElement {
        app.descendants(matching: .any)["terminal-notification-banner-Alpha"]
    }

    func testOsc777BannerShowsExactTitleAndBody() {
        // zsh-safe, quote-free form of:
        //   printf '\e]777;notify;Build finished;done\a'
        // (launch-argument marshalling strips quotes; `\\033` survives the
        // shell as `\033` for printf, `\\073` is the OSC semicolon, and
        // `\ ` keeps "Build finished" one word).
        launchSession(command: #"printf \\033]777\\073notify\\073Build\ finished\\073done\\a"#)

        // Gate on the OSC payload reaching the raw tail: the banner
        // publishes only once these bytes arrive, and the fixture
        // shell's startup can delay that well past the session going
        // active.
        XCTAssertTrue(
            waitForLabel(tail, contains: "]777;notify;Build finished;done", timeout: 45),
            "the OSC 777 payload must reach the session's raw tail — current tail: \(tail.label.suffix(300))"
        )

        XCTAssertTrue(
            banner.waitForExistence(timeout: 10),
            "the OSC 777 notify event must surface the scene banner — absence means the banner is genuinely missing from the AX tree"
        )
        XCTAssertEqual(
            app.staticTexts["terminal-notification-title-Alpha"].label,
            "Build finished",
            "the banner title must be the exact parsed OSC 777 title"
        )
        XCTAssertEqual(
            app.staticTexts["terminal-notification-body-Alpha"].label,
            "done",
            "the banner body must be the exact parsed OSC 777 body"
        )

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "osc777-banner-ax"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMalformedOsc777ProducesNoBannerAndKeepsSessionAlive() {
        // `notify` alone is malformed (fewer than three parts): no banner,
        // no crash. The trailing printf proves the session still processes
        // output after the malformed sequence.
        launchSession(command: #"printf \\033]777\\073notify\\a; printf OSC777_ALIVE_MARKER\\n"#)

        XCTAssertTrue(
            waitForLabel(tail, contains: "]777;notify", timeout: 45),
            "the malformed OSC 777 payload must reach the session's raw tail — current tail: \(tail.label.suffix(300))"
        )

        // The no-banner window starts AFTER the bytes arrived, so a
        // malformed payload that was merely slow cannot pass vacuously.
        XCTAssertFalse(
            banner.waitForExistence(timeout: 7),
            "a malformed OSC 777 payload must not surface a banner"
        )

        XCTAssertTrue(
            waitForLabel(tail, contains: "OSC777_ALIVE_MARKER", timeout: 20),
            "the session must keep processing output after a malformed OSC 777 — tail: \(tail.label.suffix(300))"
        )
    }
}
