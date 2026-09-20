import CryptoKit
import LocalAuthentication
import UIKit
import XCTest

@MainActor
final class KeyManagementUITests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let passphraseFixture = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519_passphrase")
    private static let passphraseFixturePub = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-ed25519_passphrase.pub")
    private static let rsaFixture = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-rsa3072")
    private static let dssFixture = repoRoot
        .appendingPathComponent("Fixtures/keys/bicterm-fixture-dss_header")

    private static let passphraseFingerprint =
        "SHA256:R9XaxtlJKgrJE0AbFdKibF9+X1cPt0yWTzvTWUvh1r4"

    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func launch(_ extraArguments: [String]) {
        app.launchArguments = ["-uitest-keys-entry"] + extraArguments
        app.launch()
        XCTAssertTrue(
            app.navigationBars["SSH Keys"].waitForExistence(timeout: 15),
            "Key management entry did not appear"
        )
    }

    func testDisabledKeyPresentAtFirstBootstrap() {
        app.launchArguments = ["-uitest-reset-keys", "-uitest-keys-entry"]
        app.launch()
        XCTAssertTrue(app.navigationBars["SSH Keys"].waitForExistence(timeout: 15))
        app.terminate()
        app.launchArguments = ["--uitest-reset", "--uitest-sessions", "--uitest-pwd-server",
                               "--uitest-pretrust-fixtures", "-uitest-seed-disabled-key"]
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15))
        app.buttons["open-settings"].tap()
        openKeysFromSettings()
        assertFourFixtureRows()
    }

    func testColdRestoredSettingsSceneLoadsKeys() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Cold Settings restoration requires the prepared iPad scene")
        }
        // The test is its own producer. Launch #1 seeds the four fixture
        // keys and opens the independent Settings window through the DEBUG
        // seam (the user path — session menu → Settings… — needs a live
        // SSH session, which this test's subject does not involve).
        app.launchArguments = [
            "-uitest-reset-keys",
            "--uitest-reset",
            "-uitest-seed-disabled-key",
            "--uitest-open-settings-scene",
        ]
        app.launch()
        let settingsBar = app.navigationBars["Settings"]
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 20),
                      "The Settings scene did not open on the seeding launch")
        // Existence is not enough: a background window's elements exist in
        // the accessibility tree but are not hittable. The Settings window
        // must be FOREGROUND before the background cycle below, or the
        // archive checkpoints the restored herdr scene as last-active and
        // the seed-free relaunch restores the connection list instead of
        // Settings.
        XCTAssertTrue(waitUntilHittable(settingsBar, timeout: 15),
                      "The Settings scene did not surface on the seeding launch")

        // iPadOS checkpoints the scene-session archive on a real background
        // transition, not on terminate: background, let the checkpoint land,
        // reactivate so Settings is the last-active (foreground-restored)
        // scene, then terminate with the archive settled.
        XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        Thread.sleep(forTimeInterval: 5)
        app.activate()
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 15),
                      "The Settings scene must be foreground when the archive settles")
        XCTAssertTrue(waitUntilHittable(settingsBar, timeout: 15),
                      "The Settings scene must be foreground when the archive settles")
        app.terminate()

        // Launch #2 is deliberately seed-free — none of the key-seeding
        // flags — so the returning Settings scene must load its keys from
        // the Keychain, not from any launch vector. XCUIApplication's
        // launch request routes through CoreSimulatorBridge and NAMES a
        // scene to open: a stale host-side choice that overrides the
        // archive's last-active scene (observed naming the leftover herdr
        // scene while Settings was foreground at termination — through a
        // terminate-first launch, activate(), and consecutive launches
        // alike). The opener flag therefore drives the Settings scene's
        // return: openWindow re-activates the ARCHIVED Settings scene
        // session (it does not create a duplicate), and the scene's
        // content cold-mounts in the fresh process.
        app.launchArguments = ["--uitest-open-settings-scene"]
        app.launch()
        XCTAssertTrue(settingsBar.waitForExistence(timeout: 20),
                      "The independent Settings scene must be cold-restored")
        XCTAssertTrue(waitUntilHittable(settingsBar, timeout: 15),
                      "The Settings scene must surface on the seed-free relaunch")
        XCTAssertFalse(app.buttons["add-connection"].isHittable,
                       "Settings, not the connection list, must be the foreground scene")
        openKeysFromSettings()
        assertFourFixtureRows()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "cold-restored-settings-keys"
        attachment.lifetime = .keepAlways
        add(attachment)

        // Cleanup: iPadOS restores the last-active archived scene on every
        // launch, and the Settings scene is the only one that does NOT
        // fall back to rendering the connection list when restored. Later
        // class tests (and the rest of the suite) launch into whatever this
        // test leaves behind — destroy the Settings scene session so they
        // launch into the connection list again, and verify the archive
        // actually returned there the same way the next test will
        // experience it. Both flags: the opener realizes the Settings
        // window from whatever scene this launch restored, then the
        // dismisser destroys it.
        app.terminate()
        app.launchArguments = ["--uitest-open-settings-scene", "--uitest-dismiss-settings-scene"]
        app.launch()
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 15),
                      "Cleanup must leave the connection list as the restored foreground scene")
    }

    private func openKeysFromSettings() {
        let keys = app.buttons["settings-ssh-keys"]
        XCTAssertTrue(keys.waitForExistence(timeout: 10))
        keys.tap()
        XCTAssertTrue(app.navigationBars["SSH Keys"].waitForExistence(timeout: 10))
    }

    /// Polls until the element is hittable — `waitForExistence` cannot tell
    /// a foreground window from a background one (both expose their
    /// elements to the accessibility tree; only the foreground window's
    /// are hittable).
    private func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists && element.isHittable { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return element.exists && element.isHittable
    }

    private func assertFourFixtureRows() {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'key-row-'"))
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(app.buttons["key-row-Disabled Fixture"].value as? String, "Disabled")
        for label in ["Fixture Ed25519", "Fixture Ed25519 Passphrase", "Fixture Hop2 Unauthorized"] {
            XCTAssertEqual(app.buttons["key-row-\(label)"].value as? String, "Enabled")
        }
        XCTAssertEqual(app.staticTexts.matching(identifier: "key-type-badge").count, 4)
        XCTAssertFalse(app.staticTexts["Secure Enclave"].exists)
    }

    private func openMenu(actionIdentifier: String, actionLabel: String) {
        let menu = app.buttons["keys-add-menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let action = app.buttons[actionIdentifier].exists
            ? app.buttons[actionIdentifier]
            : app.buttons[actionLabel]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "\(actionLabel) menu item missing")
        action.tap()
    }

    private func importFixtureKey(named label: String) {
        openMenu(actionIdentifier: "menu-import", actionLabel: "Import Key")
        let labelField = app.textFields["import-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText(label)

        app.buttons["import-paste"].tap()
        let status = app.staticTexts["import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(
            status.label.contains("Encrypted"),
            "Expected encrypted-key detection, got: \(status.label)"
        )

        let passphraseField = app.secureTextFields["import-passphrase"]
        XCTAssertTrue(passphraseField.waitForExistence(timeout: 5))
        passphraseField.tap()
        passphraseField.typeText("testpass")

        app.buttons["import-save"].tap()
        XCTAssertTrue(
            app.staticTexts[label].waitForExistence(timeout: 10),
            "Imported key did not appear in the list"
        )
    }

    private func saveEvidenceScreenshot(_ name: String) throws {
        let url = Self.repoRoot.appendingPathComponent(".sisyphus/evidence/\(name)")
        try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }

    private func openDetail(rowLabel: String) {
        let row = app.staticTexts[rowLabel]
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Row \(rowLabel) missing")
        for _ in 0..<4 {
            if app.navigationBars["Key Details"].exists { return }
            tap(row)
            _ = app.navigationBars["Key Details"].waitForExistence(timeout: 3)
        }
        XCTFail("Key detail did not open for \(rowLabel)")
    }

    /// A SwiftUI Form Toggle's XCUI element spans the whole row; tapping its
    /// center hits the label, which does NOT flip the switch. Taps land on the
    /// trailing edge (where the switch renders) after revealing the row — a
    /// row hidden behind the keyboard never receives the synthesized tap.
    @discardableResult
    private func setToggle(_ element: XCUIElement, on: Bool) -> Bool {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "Toggle \(element) missing")
        func isOn() -> Bool {
            let value = (element.value as? String ?? "").lowercased()
            return value == "1" || value == "true" || value == "on"
        }
        var swipes = 0
        while isOn() != on {
            if !element.isHittable, swipes < 3 {
                app.swipeUp()
                swipes += 1
                continue
            }
            guard swipes < 6 else { return false }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            swipes += 1
        }
        return true
    }

    /// Presses Return in the focused field to drop the keyboard so lower form
    /// rows become tappable.
    private func dismissKeyboard() {
        if app.keyboards.buttons["Return"].exists {
            app.keyboards.buttons["Return"].tap()
        } else if app.keyboards.buttons["return"].exists {
            app.keyboards.buttons["return"].tap()
        }
    }

    private func keyToggles() -> XCUIElementQuery {
        app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'key-enabled-toggle-'"))
    }

    private func enabledToggleCount() -> Int {
        (0..<keyToggles().count).count { toggleIsOn(keyToggles().element(boundBy: $0)) }
    }

    private func toggleIsOn(_ toggle: XCUIElement) -> Bool {
        let value = (toggle.value as? String ?? "").lowercased()
        return value == "1" || value == "true" || value == "on"
    }

    private func generateKey(named label: String) {
        openMenu(actionIdentifier: "menu-generate", actionLabel: "Generate Key")
        let labelField = app.textFields["generate-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText(label)
        dismissKeyboard()
        XCTAssertTrue(setToggle(app.switches["generate-biometrics"], on: false))
        app.buttons["generate-save"].tap()
        XCTAssertTrue(app.staticTexts[label].waitForExistence(timeout: 10))
    }

    func testTogglePersistenceAcrossReopen() {
        // `-uitest-reset-keys` wipes every key (earlier suite tests leave
        // SE/imported keys behind); `--uitest-reset` then re-seeds exactly
        // the three fixture ed25519 keys.
        launch(["-uitest-reset-keys", "--uitest-reset"])
        XCTAssertEqual(keyToggles().count, 3)
        XCTAssertEqual(enabledToggleCount(), 3)
        XCTAssertTrue(setToggle(keyToggles().element(boundBy: 0), on: false))
        XCTAssertEqual(enabledToggleCount(), 2)

        app.terminate()
        launch([])
        XCTAssertEqual(keyToggles().count, 3)
        XCTAssertEqual(enabledToggleCount(), 2, "Disabled state must persist across reopening Key Management")
    }

    func testToggleFailureShowsInlineErrorAndRestores() {
        launch([
            "-uitest-reset-keys",
            "--uitest-reset",
            "-uitest-seed-disabled-key",
            "--uitest-key-toggle-fail",
        ])
        let toggle = app.switches["key-enabled-toggle-uitest-disabled-fixture"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertFalse(toggleIsOn(toggle))
        // The switch element spans the whole row; a center tap hits the
        // NavigationLink instead of the switch. Tap the trailing edge where
        // the switch renders (same mechanics as setToggle).
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()

        let error = app.staticTexts["key-toggle-error"]
        XCTAssertTrue(error.waitForExistence(timeout: 5), "A failed key toggle must publish a row-local error")
        XCTAssertFalse(toggleIsOn(toggle), "The failed toggle must restore its persisted disabled state")
    }

    func testEnabledCountBannerAppearsAndClears() {
        launch(["-uitest-reset-keys", "--uitest-reset"])
        generateKey(named: "Banner Four")
        generateKey(named: "Banner Five")
        generateKey(named: "Banner Six")

        let banner = app.staticTexts["enabled-count-banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 5))
        XCTAssertEqual(
            banner.label,
            "6 keys are enabled. Many servers allow only 6 authentication attempts and may disconnect before later keys are tried."
        )
        XCTAssertTrue(setToggle(keyToggles().element(boundBy: 0), on: false))
        XCTAssertFalse(banner.waitForExistence(timeout: 2), "The warning must clear at five enabled keys")
    }

    func testGenerateEd25519KeyAppearsWithBadgeFingerprintAndCreatedDate() {
        launch(["-uitest-reset-keys", "-uitest-biometrics-bypass"])

        openMenu(actionIdentifier: "menu-generate", actionLabel: "Generate Key")
        let labelField = app.textFields["generate-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("gen-ed25519")
        dismissKeyboard()

        setToggle(app.switches["generate-biometrics"], on: false)

        app.buttons["generate-save"].tap()

        XCTAssertTrue(app.staticTexts["gen-ed25519"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["ed25519"].exists, "ed25519 type badge missing")
        let fingerprint = app.staticTexts["key-fingerprint"]
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 5))
        XCTAssertTrue(fingerprint.label.hasPrefix("SHA256:"), "Fingerprint not shown: \(fingerprint.label)")
        XCTAssertTrue(app.staticTexts["key-created"].waitForExistence(timeout: 5))
    }

    func testSecureEnclaveBadgeRendersForP256KeyMetadata() {
        launch(["-uitest-reset-keys", "-uitest-seed-se-key"])

        XCTAssertTrue(app.staticTexts["SE Test Key"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Secure Enclave"].exists, "Secure Enclave badge missing")
        XCTAssertTrue(
            app.descendants(matching: .any)["key-biometric-badge"].firstMatch.exists,
            "Biometric badge missing"
        )
    }

    func testGenerateSecureEnclaveKeyOnHardware() throws {
        guard SecureEnclave.isAvailable else {
            throw XCTSkip("Secure Enclave unavailable on this simulator")
        }

        launch(["-uitest-reset-keys", "-uitest-biometrics-bypass"])

        openMenu(actionIdentifier: "menu-generate", actionLabel: "Generate Key")
        let labelField = app.textFields["generate-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("se-hw-key")
        dismissKeyboard()

        setToggle(app.switches["generate-biometrics"], on: false)

        app.buttons["generate-type"].tap()
        app.buttons["P-256 Secure Enclave"].tap()

        app.buttons["generate-save"].tap()

        XCTAssertTrue(app.staticTexts["se-hw-key"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Secure Enclave"].exists)
    }

    func testImportPassphraseProtectedKeyViaPasteMatchesSSHKeygenFingerprint() throws {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.passphraseFixture.path,
        ])

        importFixtureKey(named: "fixture-key")

        XCTAssertTrue(
            app.staticTexts[Self.passphraseFingerprint].waitForExistence(timeout: 5),
            "Imported key fingerprint does not match ssh-keygen output"
        )

        try saveEvidenceScreenshot("task-16-import.png")
    }

    func testRSAPasteIsRejectedWithTypedMessageAndListStaysEmpty() throws {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.rsaFixture.path,
        ])

        openMenu(actionIdentifier: "menu-import", actionLabel: "Import Key")
        let labelField = app.textFields["import-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("bad-rsa")

        app.buttons["import-paste"].tap()
        let status = app.staticTexts["import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(
            status.label.contains("ssh-rsa"),
            "Rejection must name the unsupported key type, got: \(status.label)"
        )

        let saveButton = app.buttons["import-save"]
        XCTAssertTrue(saveButton.exists)
        XCTAssertFalse(saveButton.isEnabled, "Save must be disabled for rejected keys")

        try saveEvidenceScreenshot("task-16-rsa-reject.png")

        app.buttons["import-cancel"].tap()
        XCTAssertTrue(
            app.otherElements["key-empty-state"].waitForExistence(timeout: 5)
                || app.staticTexts["No Keys Yet"].waitForExistence(timeout: 5),
            "Key list must remain unchanged after rejection"
        )
        XCTAssertFalse(app.staticTexts["bad-rsa"].exists, "No key may be created from an RSA paste")
    }

    /// OpenSSH 10.3 cannot generate DSA keys, so the fixture is a
    /// deterministic header-only `openssh-key-v1` blob whose PUBLIC algorithm
    /// string is `ssh-dss` — the parser rejects it on that string before the
    /// private section is ever read. It contains no real key material.
    func testDSAPasteIsRejectedWithTypedMessageAndListStaysEmpty() throws {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.dssFixture.path,
        ])

        openMenu(actionIdentifier: "menu-import", actionLabel: "Import Key")
        let labelField = app.textFields["import-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("bad-dsa")

        app.buttons["import-paste"].tap()
        let status = app.staticTexts["import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(
            status.label.contains("ssh-dss"),
            "Rejection must name the unsupported DSA key type, got: \(status.label)"
        )

        let saveButton = app.buttons["import-save"]
        XCTAssertTrue(saveButton.exists)
        XCTAssertFalse(saveButton.isEnabled, "Save must be disabled for rejected keys")

        try saveEvidenceScreenshot("task-16-dsa-reject.png")

        app.buttons["import-cancel"].tap()
        XCTAssertTrue(
            app.otherElements["key-empty-state"].waitForExistence(timeout: 5)
                || app.staticTexts["No Keys Yet"].waitForExistence(timeout: 5),
            "Key list must remain unchanged after DSA rejection"
        )
        XCTAssertFalse(app.staticTexts["bad-dsa"].exists, "No key may be created from a DSA paste")
    }

    /// The biometric opt-in toggle's value must reach the repository import
    /// (never hardcoded false). The row badge renders from the PERSISTED
    /// `KeyMetadata.requiresBiometry`, so its presence proves the flag
    /// round-tripped through the Keychain.
    func testImportWithBiometricOptInPersistsProtectedKey() {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.passphraseFixture.path,
            "-uitest-biometrics-bypass",
        ])

        openMenu(actionIdentifier: "menu-import", actionLabel: "Import Key")
        let labelField = app.textFields["import-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("gated-import")

        app.buttons["import-paste"].tap()
        let status = app.staticTexts["import-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Encrypted"))

        let passphraseField = app.secureTextFields["import-passphrase"]
        XCTAssertTrue(passphraseField.waitForExistence(timeout: 5))
        passphraseField.tap()
        passphraseField.typeText("testpass")
        dismissKeyboard()

        let biometricsToggle = app.switches["import-biometrics"]
        XCTAssertTrue(biometricsToggle.waitForExistence(timeout: 5), "Import flow must offer a biometric opt-in toggle")
        XCTAssertTrue(setToggle(biometricsToggle, on: true), "Biometric opt-in toggle must flip on")

        app.buttons["import-save"].tap()

        XCTAssertTrue(
            app.staticTexts["gated-import"].waitForExistence(timeout: 10),
            "Imported key did not appear in the list"
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["key-biometric-badge"].firstMatch.exists,
            "Biometric opt-in must persist on the imported key (badge renders from stored metadata)"
        )
    }

    func testPrivateKeyBytesNeverAppearInTheAccessibilityTree() throws {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.passphraseFixture.path,
        ])

        importFixtureKey(named: "fixture-key")

        openDetail(rowLabel: "fixture-key")
        XCTAssertTrue(
            app.staticTexts["public-key-text"].waitForExistence(timeout: 5),
            "Detail view with public key should be reachable"
        )

        let pem = try String(contentsOf: Self.passphraseFixture, encoding: .utf8)
        let body = pem
            .split(separator: "\n")
            .dropFirst()
            .dropLast()
            .joined()
        let forbiddenFragments = [
            "-----BEGIN OPENSSH PRIVATE KEY-----",
            String(body.prefix(16)),
            String(body.dropFirst(body.count / 2).prefix(16)),
            String(body.suffix(16)),
        ]

        let tree = app.debugDescription
        for fragment in forbiddenFragments {
            XCTAssertFalse(
                tree.contains(fragment),
                "Private key material leaked into the accessibility tree: \(fragment)"
            )
        }

        let publicKeyText = app.staticTexts["public-key-text"]
        XCTAssertTrue(publicKeyText.label.hasPrefix("ssh-ed25519 "))
    }

    /// The runner never polls `UIPasteboard` (flaky and permission-prone).
    /// The app verifies its own pasteboard write round-trip and exposes the
    /// result as state: `copy-confirmation` appears only when the pasteboard
    /// holds exactly the authorized_keys line.
    func testCopyPublicKeyConfirmsStateAndMatchesAuthorizedKeysLine() throws {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.passphraseFixture.path,
        ])

        importFixtureKey(named: "fixture-key")
        openDetail(rowLabel: "fixture-key")

        let publicKeyText = app.staticTexts["public-key-text"]
        XCTAssertTrue(publicKeyText.waitForExistence(timeout: 5))
        let displayedLine = publicKeyText.label
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let copyButton = app.buttons["copy-public-key"]
        XCTAssertTrue(copyButton.waitForExistence(timeout: 5))
        tap(copyButton)

        let confirmation = app.staticTexts["copy-confirmation"]
        XCTAssertTrue(
            confirmation.waitForExistence(timeout: 5),
            "Copy must surface app-observable confirmation state"
        )
        XCTAssertEqual(
            confirmation.label, "Copied public key",
            "Copy round-trip verification failed inside the app"
        )

        let pubLine = try String(contentsOf: Self.passphraseFixturePub, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        let fields = displayedLine.split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 3, "authorized_keys line: \(displayedLine)")
        XCTAssertEqual(fields[0], "ssh-ed25519")
        XCTAssertEqual(fields[1], String(pubLine[1]), "Displayed public key must match the fixture public key")
        XCTAssertEqual(fields[2], "fixture-key")
    }

    func testDeleteKeyWarnsAboutReferencingConnectionsAndConfirms() {
        launch([
            "-uitest-reset-keys",
            "-uitest-seed-se-key",
            "-uitest-seed-connection",
            "-uitest-biometrics-bypass",
        ])

        XCTAssertTrue(app.staticTexts["SE Test Key"].waitForExistence(timeout: 10))
        openDetail(rowLabel: "SE Test Key")

        let deleteButton = app.buttons["delete-key"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 5))
        tap(deleteButton)

        let usedBy = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Fixture Jump Host"))
            .firstMatch
        XCTAssertTrue(
            usedBy.waitForExistence(timeout: 5),
            "Delete warning must name referencing connections"
        )

        tap(app.buttons["confirm-delete-key"].firstMatch)

        XCTAssertTrue(
            app.staticTexts["No Keys Yet"].waitForExistence(timeout: 10),
            "Deleted key must disappear from the list"
        )
        XCTAssertFalse(app.staticTexts["SE Test Key"].exists)
    }

    func testGenerateWithBiometricGateDeniedWhenBiometryUnavailable() throws {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) == false else {
            throw XCTSkip("Biometry enrolled on this device — the real prompt would block the test")
        }

        launch(["-uitest-reset-keys"])

        openMenu(actionIdentifier: "menu-generate", actionLabel: "Generate Key")
        let labelField = app.textFields["generate-label"]
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.tap()
        labelField.typeText("gated-key")

        app.buttons["generate-save"].tap()

        let error = app.staticTexts["generate-error"]
        XCTAssertTrue(
            error.waitForExistence(timeout: 10),
            "Gate denial must surface an error"
        )
        XCTAssertTrue(error.label.contains("Biometric"))

        app.buttons["generate-cancel"].tap()
        XCTAssertTrue(
            app.staticTexts["No Keys Yet"].waitForExistence(timeout: 5),
            "No key may be created when the biometric gate denies"
        )
    }

    // MARK: - Imported-key SSH authentication proof (T16 gap-5)

    /// Polls `previewState` for a substring match (e.g. "ready", "failed").
    /// Returns the matching label and `true` if observed before timeout.
    private func waitForPreviewState(
        _ expected: String,
        timeout: TimeInterval = 35,
        file: StaticString = #file,
        line: UInt = #line
    ) -> (matched: Bool, label: String) {
        let state = app.staticTexts["previewState"]
        let predicate = NSPredicate(format: "label CONTAINS %@", expected)
        let deadline = Date().addingTimeInterval(timeout)
        var lastLabel = ""
        while Date() < deadline {
            if state.exists, predicate.evaluate(with: state) {
                return (true, state.label)
            }
            lastLabel = state.exists ? state.label : lastLabel
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail(
            "previewState never contained '\(expected)' (last: '\(lastLabel)')",
            file: file,
            line: line
        )
        return (false, lastLabel)
    }

    private func waitForPreviewTail(
        _ marker: String,
        timeout: TimeInterval = 25,
        file: StaticString = #file,
        line: UInt = #line
    ) -> String {
        let tail = app.staticTexts["previewTail"]
        let predicate = NSPredicate(format: "label CONTAINS %@", marker)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if tail.exists, predicate.evaluate(with: tail) {
                return tail.label
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail(
            "previewTail never contained '\(marker)' (last: '\(tail.exists ? tail.label : "")')",
            file: file,
            line: line
        )
        return tail.exists ? tail.label : ""
    }

    /// Imports the encrypted ed25519 fixture via the existing UI helper,
    /// terminates the app, and relaunches with the supplied arguments so
    /// `TerminalPreviewScreen` activates with the new launch context. The
    /// imported key persists in the app's Keychain across the relaunch.
    private func importFixtureKeyThenRelaunch(_ arguments: [String]) {
        app.launchArguments = [
            "-uitest-keys-entry",
            "-uitest-reset-keys",
            "-uitest-seed-pasteboard",
            Self.passphraseFixture.path,
        ]
        app.launch()
        XCTAssertTrue(
            app.navigationBars["SSH Keys"].waitForExistence(timeout: 15),
            "Key management entry did not appear during import phase"
        )
        importFixtureKey(named: "fixture-key")
        app.terminate()
        app.launchArguments = arguments
        app.launch()
    }

    func testImportedKeyAuthenticatesRealSSHSession() {
        importFixtureKeyThenRelaunch([
            "-uitest-terminal-preview",
            "-uitest-key-ref",
            "fixture-key",
        ])

        let stateResult = waitForPreviewState("ready", timeout: 35)
        XCTAssertTrue(stateResult.matched, "previewState did not reach ready: \(stateResult.label)")

        let tail = waitForPreviewTail("__READY__", timeout: 25)
        XCTAssertTrue(
            tail.contains("__READY__"),
            "Authenticated shell never produced the post-auth READY marker: \(tail)"
        )
    }

    func testImportedKeySSHProofFailsWithoutKey() {
        importFixtureKeyThenRelaunch([
            "-uitest-terminal-preview",
            "-uitest-key-ref",
            "does-not-exist",
        ])

        let failedResult = waitForPreviewState("failed", timeout: 30)
        XCTAssertTrue(
            failedResult.matched,
            "Provider error must surface as .failed, got: \(failedResult.label)"
        )

        // Negative check must NOT reuse waitForPreviewState: its deadline
        // path XCTFails unconditionally, which would fail an expected miss.
        let state = app.staticTexts["previewState"]
        let readyPredicate = NSPredicate(format: "label CONTAINS %@", "ready")
        XCTAssertFalse(
            state.exists && readyPredicate.evaluate(with: state),
            "A non-existent label must never produce state:ready (got \(state.exists ? state.label : "no state"))"
        )
    }
}
