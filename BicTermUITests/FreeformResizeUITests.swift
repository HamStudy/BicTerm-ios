import XCTest

/// Regression test for freeform window resizing on iPadOS 26 (project.yml
/// `info:` orientation declarations). If UISupportedInterfaceOrientations~
/// ipad ever stops declaring all four orientations, iPadOS 26 classifies the
/// app as non-continuously resizable: the corner grip disappears and windows
/// only snap between preset sizes. This test drags the bottom-right corner
/// grip and asserts the window lands at an arbitrary non-preset size.
///
/// The resize grip is system chrome owned by SpringBoard, so the drag is
/// routed through a SpringBoard XCUIApplication session; a drag synthesized
/// against the app session never reaches the system recognizer.
@MainActor
final class FreeformResizeUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCornerDragResizesWindowToNonPresetSize() {
        app.launch()
        sleep(2)

        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let screen = sb.frame
        func point(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
            sb.coordinate(
                withNormalizedOffset: CGVector(dx: x / screen.width, dy: y / screen.height)
            )
        }

        // iPadOS persists window sizes across launches; grow toward full
        // screen first so the shrink below always starts from a large
        // window regardless of what earlier runs left behind.
        let frame = app.windows.firstMatch.frame
        point(frame.maxX - 6, frame.maxY - 6)
            .press(forDuration: 1.0, thenDragTo: point(screen.width * 0.9, screen.height * 0.9))
        sleep(2)

        let before = app.windows.firstMatch.frame
        XCTAssertGreaterThan(before.width, 600, "expected a large window after the grow drag")
        attach("freeform-before")

        let corner = CGPoint(x: before.maxX, y: before.maxY)
        var after = before
        for inset: CGFloat in [6, 14, 26] {
            point(corner.x - inset, corner.y - inset)
                .press(forDuration: 1.0, thenDragTo: point(screen.width * 0.4, screen.height * 0.4))
            sleep(2)
            after = app.windows.firstMatch.frame
            if after.size != before.size { break }
        }
        attach("freeform-after")
        print("FREEFORM window \(before.size) -> \(after.size)")

        // A preset-snapping window cannot shrink below ~half in BOTH
        // dimensions (Split View presets keep most of one axis), and its
        // aspect ratio stays at the screen's 4:3. A freeform drag produces
        // a small window with an aspect far from the screen's.
        XCTAssertNotEqual(after.size, before.size, "corner drag did not resize the window")
        XCTAssertLessThan(after.width, before.width * 0.6)
        XCTAssertLessThan(after.height, before.height * 0.6)
        let windowAspect = after.width / after.height
        let screenAspect: CGFloat = 4.0 / 3.0
        XCTAssertGreaterThan(
            abs(windowAspect - screenAspect) / screenAspect,
            0.2,
            "resized aspect \(windowAspect) is too close to the screen preset 4:3"
        )
    }
}
