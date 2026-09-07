import BicTermCore
import XCTest
@testable import BicTerm

final class CoderServerDraftTests: XCTestCase {
    func testHTTPSAccepted() {
        let draft = makeDraft(urlString: "https://coder.example.com")
        XCTAssertNotNil(draft.resolvedURL)
        XCTAssertNil(draft.urlError)
    }

    func testHostOnlyNormalizesToHTTPS() {
        let draft = makeDraft(urlString: "coder.example.com")
        XCTAssertEqual(draft.resolvedURL?.absoluteString, "https://coder.example.com")
        XCTAssertNil(draft.urlError)
    }

    func testHTTPRejected() {
        let draft = makeDraft(urlString: "http://coder.example.com")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertEqual(draft.urlError, "HTTP is not allowed. Use HTTPS.")
    }

    func testUnsupportedSchemeRejected() {
        let draft = makeDraft(urlString: "ftp://coder.example.com")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertEqual(draft.urlError, "Use HTTPS only.")
    }

    func testMissingHostRejected() {
        let draft = makeDraft(urlString: "https://")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertNotNil(draft.urlError)
    }

    func testEmbeddedCredentialsRejected() {
        let draft = makeDraft(urlString: "https://user:pass@coder.example.com")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertEqual(draft.urlError, "URL credentials are not allowed.")
    }

    func testUserWithoutPasswordRejected() {
        let draft = makeDraft(urlString: "https://user@coder.example.com")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertEqual(draft.urlError, "URL credentials are not allowed.")
    }

    func testInvalidPortRejected() {
        let draft = makeDraft(urlString: "https://coder.example.com:70000")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertEqual(draft.urlError, "Enter a valid port number.")
    }

    func testValidPortAccepted() {
        let draft = makeDraft(urlString: "https://coder.example.com:8080")
        XCTAssertEqual(draft.resolvedURL?.absoluteString, "https://coder.example.com:8080")
        XCTAssertNil(draft.urlError)
    }

    func testPathQueryRejected() {
        var draft = makeDraft(urlString: "https://coder.example.com/api")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertNotNil(draft.urlError)

        draft = makeDraft(urlString: "https://coder.example.com?q=1")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertNotNil(draft.urlError)

        draft = makeDraft(urlString: "https://coder.example.com#anchor")
        XCTAssertNil(draft.resolvedURL)
        XCTAssertNotNil(draft.urlError)
    }

    func testIPv4Accepted() {
        let draft = makeDraft(urlString: "https://192.168.1.1")
        XCTAssertNotNil(draft.resolvedURL)
        XCTAssertNil(draft.urlError)
    }

    func testIPv6Accepted() {
        let draft = makeDraft(urlString: "https://[::1]")
        XCTAssertEqual(draft.resolvedURL?.absoluteString, "https://[::1]")
        XCTAssertNil(draft.urlError)
    }

    func testKeychainTagUsesServerIDWhenEditing() throws {
        let server = try CoderServer(
            name: "Prod",
            baseURL: URL(string: "https://coder.example.com")!,
            tokenKeychainTag: "unused"
        )
        let draft = CoderServerDraft(server: server)
        XCTAssertEqual(draft.tokenKeychainTag, "com.bicterm.coder.server.\(server.id.uuidString)")
    }

    func testKeychainTagIsStableWithinDraft() {
        let draft = CoderServerDraft()
        XCTAssertEqual(draft.tokenKeychainTag, draft.tokenKeychainTag)
    }

    private func makeDraft(urlString: String) -> CoderServerDraft {
        var draft = CoderServerDraft()
        draft.urlString = urlString
        return draft
    }
}
