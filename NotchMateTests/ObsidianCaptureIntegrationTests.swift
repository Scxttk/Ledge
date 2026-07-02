import XCTest
@testable import NotchMate

/// End-to-end: write a capture through the real file path into a throwaway
/// vault folder and read it back. Exercises bookmark resolution, path
/// validation, daily-note creation and the atomic write.
final class ObsidianCaptureIntegrationTests: XCTestCase {
    private var vaultRoot: URL!
    private var settings: UserSettings!

    override func setUpWithError() throws {
        vaultRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NotchMateVault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)

        let defaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        settings = UserSettings(defaults: defaults)
        settings.vaultBookmark = Persistence.bookmarkData(for: vaultRoot)
        settings.dailyFolder = "daily"
        settings.dailyFormat = "yyyy-MM-dd"
        settings.captureTimestamp = false
        settings.captureMode = .silentAppend
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: vaultRoot)
    }

    private func todayNoteURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return vaultRoot
            .appendingPathComponent("daily")
            .appendingPathComponent(formatter.string(from: Date()) + ".md")
    }

    func testCaptureCreatesDailyNoteWithBullet() throws {
        let url = try ObsidianVault().append(text: "buy milk", asLink: false, settings: settings)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("## 📥 Capture"))
        XCTAssertTrue(content.contains("- buy milk"))
        // Compare by relative location; /var vs /private/var firmlink makes the
        // raw URLs differ even though they point at the same file.
        XCTAssertTrue(url.path.hasSuffix("/daily/\(todayNoteURL().lastPathComponent)"))
    }

    func testSecondCaptureAppendsBelowFirst() throws {
        _ = try ObsidianVault().append(text: "first", asLink: false, settings: settings)
        _ = try ObsidianVault().append(text: "second", asLink: false, settings: settings)
        let content = try String(contentsOf: todayNoteURL(), encoding: .utf8)
        let firstRange = try XCTUnwrap(content.range(of: "- first"))
        let secondRange = try XCTUnwrap(content.range(of: "- second"))
        XCTAssertTrue(firstRange.lowerBound < secondRange.lowerBound)
    }

    func testCapturePreservesExistingTemplateSection() throws {
        // Seed a note that mirrors the user's daily template, with the empty
        // placeholder bullet, and verify capture slots in without clobbering.
        let note = todayNoteURL()
        try FileManager.default.createDirectory(at: note.deletingLastPathComponent(), withIntermediateDirectories: true)
        let template = """
        # 2026-06-30 — Dienstag

        ## 🎯 Fokus heute

        - Arbeiten

        ## 📥 Capture

        -

        ## 🌙 Plan für morgen

        -
        """
        try Data(template.utf8).write(to: note)

        _ = try ObsidianVault().append(text: "idea", asLink: false, settings: settings)
        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(content.contains("## 🎯 Fokus heute"))
        XCTAssertTrue(content.contains("- Arbeiten"))
        XCTAssertTrue(content.contains("- idea"))
        XCTAssertTrue(content.contains("## 🌙 Plan für morgen"))
        // "idea" sits inside the Capture section.
        let capture = try XCTUnwrap(content.range(of: "## 📥 Capture"))
        let plan = try XCTUnwrap(content.range(of: "## 🌙 Plan für morgen"))
        let idea = try XCTUnwrap(content.range(of: "- idea"))
        XCTAssertTrue(idea.lowerBound > capture.upperBound)
        XCTAssertTrue(idea.upperBound < plan.lowerBound)
    }

    func testTimestampPrefixWhenEnabled() throws {
        settings.captureTimestamp = true
        let url = try ObsidianVault().append(text: "stamped", asLink: false, settings: settings)
        let content = try String(contentsOf: url, encoding: .utf8)
        // "- HH:mm stamped"
        let pattern = #"- \d{2}:\d{2} stamped"#
        XCTAssertNotNil(content.range(of: pattern, options: .regularExpression))
    }
}
