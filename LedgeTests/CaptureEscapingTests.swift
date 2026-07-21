import XCTest
@testable import Ledge

final class CaptureEscapingTests: XCTestCase {

    func testURLEncodingEscapesReservedCharacters() {
        XCTAssertEqual(CaptureEscaping.urlEncoded("a b&c#d/e"), "a%20b%26c%23d%2Fe")
        XCTAssertEqual(CaptureEscaping.urlEncoded("wiki-os"), "wiki-os")
    }

    func testAppleScriptEscaping() {
        XCTAssertEqual(CaptureEscaping.appleScriptEscaped("say \"hi\""), "say \\\"hi\\\"")
        XCTAssertEqual(CaptureEscaping.appleScriptEscaped("back\\slash"), "back\\\\slash")
    }

    func testSanitizeLineCollapsesNewlines() {
        XCTAssertEqual(CaptureEscaping.sanitizeLine("  line one\nline two\r\nthree  "),
                       "line one line two three")
    }

    func testSanitizeLinkTitleNeutralizesBrackets() {
        XCTAssertEqual(CaptureEscaping.sanitizeLinkTitle("Foo [bar] baz"), "Foo (bar) baz")
    }

    func testIsInsideBlocksTraversal() {
        let root = URL(fileURLWithPath: "/Users/x/Vault")
        XCTAssertTrue(CaptureEscaping.isInside(root.appendingPathComponent("01-daily/2026-06-30.md"), root: root))
        XCTAssertTrue(CaptureEscaping.isInside(root, root: root))
        XCTAssertFalse(CaptureEscaping.isInside(URL(fileURLWithPath: "/Users/x/Other/secret.md"), root: root))
        XCTAssertFalse(CaptureEscaping.isInside(root.appendingPathComponent("../escape.md"), root: root))
    }

    func testNormalizedDateFormatTranslatesMomentTokens() {
        XCTAssertEqual(CaptureEscaping.normalizedDateFormat("YYYY-MM-DD"), "yyyy-MM-dd")
        XCTAssertEqual(CaptureEscaping.normalizedDateFormat("yyyy-MM-dd"), "yyyy-MM-dd")
    }
}
