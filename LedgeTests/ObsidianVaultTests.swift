import XCTest
@testable import Ledge

final class ObsidianVaultTests: XCTestCase {
    private let heading = "## 📥 Capture"

    func testReplacesEmptyPlaceholderBullet() {
        let content = """
        # Today

        ## 📥 Capture

        -

        ## 🌙 Plan
        """
        let result = ObsidianVault.appending(bullet: "- 09:00 hello", underHeading: heading, to: content)
        XCTAssertTrue(result.contains("- 09:00 hello"))
        // The lone placeholder "-" should be replaced, not duplicated.
        XCTAssertFalse(result.contains("\n-\n"))
        // Insertion stays inside the Capture section, above the next heading.
        let captureRange = result.range(of: heading)!
        let planRange = result.range(of: "## 🌙 Plan")!
        let bulletRange = result.range(of: "- 09:00 hello")!
        XCTAssertTrue(bulletRange.lowerBound > captureRange.upperBound)
        XCTAssertTrue(bulletRange.upperBound < planRange.lowerBound)
    }

    func testAppendsAfterExistingBullets() {
        let content = """
        ## 📥 Capture
        - first
        - second
        """
        let result = ObsidianVault.appending(bullet: "- third", underHeading: heading, to: content)
        let lines = result.components(separatedBy: "\n")
        XCTAssertEqual(lines.last, "- third")
        XCTAssertEqual(lines.firstIndex(of: "- second")! + 1, lines.firstIndex(of: "- third")!)
    }

    func testCreatesHeadingWhenMissing() {
        let content = "# Note\n\nSome text\n"
        let result = ObsidianVault.appending(bullet: "- captured", underHeading: heading, to: content)
        XCTAssertTrue(result.contains(heading))
        XCTAssertTrue(result.contains("- captured"))
        XCTAssertTrue(result.range(of: heading)!.lowerBound < result.range(of: "- captured")!.lowerBound)
    }

    func testCreatesHeadingInEmptyDocument() {
        let result = ObsidianVault.appending(bullet: "- captured", underHeading: heading, to: "")
        XCTAssertEqual(result, "## 📥 Capture\n\n- captured\n")
    }

    func testInsertsUnderHeadingWithNoBulletsYet() {
        let content = "## 📥 Capture\n\n## Next"
        let result = ObsidianVault.appending(bullet: "- x", underHeading: heading, to: content)
        let bullet = result.range(of: "- x")!
        let next = result.range(of: "## Next")!
        XCTAssertTrue(bullet.upperBound < next.lowerBound)
    }
}
