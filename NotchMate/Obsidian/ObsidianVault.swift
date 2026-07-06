import AppKit

/// Reads/writes an Obsidian vault directly on the filesystem. The vault is just
/// a folder of `.md` files, so capture appends to today's daily note under a
/// configured heading — silent, no plugin, works even when Obsidian is closed.
struct ObsidianVault {

    enum CaptureError: Error {
        case noVault            // no vault folder configured / bookmark unresolvable
        case outsideVault       // computed note path escaped the vault root
        case writeFailed(Error)
        case noBrowserPage      // no frontmost Safari/Chrome tab available
    }

    /// Append a plain capture line. `asLink == false` adds a `- ` bullet around
    /// `text`; for pre-formatted markdown (e.g. a `[title](url)` link) pass the
    /// content and `asLink == true` to skip the timestamp/escaping of the body.
    func append(text: String, asLink: Bool, settings: UserSettings) throws -> URL {
        guard let bookmark = settings.vaultBookmark,
              let root = Persistence.resolveBookmark(bookmark) else {
            throw CaptureError.noVault
        }

        let dateString = dailyFormatter(settings.dailyFormat).string(from: Date())
        let noteURL = root
            .appendingPathComponent(settings.dailyFolder, isDirectory: true)
            .appendingPathComponent(dateString + ".md")

        guard CaptureEscaping.isInside(noteURL, root: root) else {
            throw CaptureError.outsideVault
        }

        let bullet = formatBullet(text, asLink: asLink, settings: settings)
        let existing = (try? String(contentsOf: noteURL, encoding: .utf8)) ?? ""
        let updated = Self.appending(bullet: bullet, underHeading: settings.captureHeading, to: existing)

        do {
            try FileManager.default.createDirectory(
                at: noteURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(updated.utf8).write(to: noteURL, options: .atomic)
        } catch {
            throw CaptureError.writeFailed(error)
        }

        if settings.captureMode == .openInObsidian {
            openInObsidian(folder: settings.dailyFolder, file: dateString, root: root, settings: settings)
        }
        return noteURL
    }

    /// Capture the frontmost browser tab as a markdown link.
    @discardableResult
    func appendCurrentBrowserPage(settings: UserSettings) throws -> URL {
        guard let page = Self.frontmostBrowserPage() else { throw CaptureError.noBrowserPage }
        let title = CaptureEscaping.sanitizeLinkTitle(page.title)
        let destination = CaptureEscaping.sanitizeLinkDestination(page.url)
        return try append(text: "[\(title)](\(destination))", asLink: true, settings: settings)
    }

    // MARK: - Pure insertion logic (unit-tested)

    /// Insert `bullet` under the markdown line equal to `heading`, at the end of
    /// that heading's section (just before the next heading or EOF). Creates the
    /// heading at the end of the document if it's missing, and replaces a lone
    /// empty `- ` placeholder bullet (as produced by the daily-note template).
    static func appending(bullet: String, underHeading heading: String, to content: String) -> String {
        let target = heading.trimmingCharacters(in: .whitespaces)
        var lines = content.components(separatedBy: "\n")

        guard let headingIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == target
        }) else {
            var result = content
            if !result.isEmpty {
                result += result.hasSuffix("\n") ? "\n" : "\n\n"
            }
            result += "\(heading)\n\n\(bullet)\n"
            return result
        }

        // End of section = next heading line after the target, else EOF.
        var sectionEnd = lines.count
        if headingIdx + 1 < lines.count {
            for i in (headingIdx + 1)..<lines.count where lines[i].hasPrefix("#") {
                sectionEnd = i
                break
            }
        }

        // Insert after the last non-empty line in the section.
        var lastNonEmpty = headingIdx
        if headingIdx + 1 < sectionEnd {
            for i in (headingIdx + 1)..<sectionEnd
            where !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                lastNonEmpty = i
            }
        }

        if lastNonEmpty != headingIdx,
           lines[lastNonEmpty].trimmingCharacters(in: .whitespaces) == "-" {
            // Reuse the template's empty placeholder bullet.
            lines[lastNonEmpty] = bullet
        } else {
            lines.insert(bullet, at: lastNonEmpty + 1)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func formatBullet(_ text: String, asLink: Bool, settings: UserSettings) -> String {
        let body = asLink ? text : CaptureEscaping.sanitizeLine(text)
        guard settings.captureTimestamp else { return "- \(body)" }
        let time = Self.timeFormatter.string(from: Date())
        return "- \(time) \(body)"
    }

    private func dailyFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = CaptureEscaping.normalizedDateFormat(pattern)
        return formatter
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func openInObsidian(folder: String, file: String, root: URL, settings: UserSettings) {
        let vault = settings.vaultName.isEmpty ? root.lastPathComponent : settings.vaultName
        let path = folder.isEmpty ? file : "\(folder)/\(file)"
        let urlString = "obsidian://open?vault=\(CaptureEscaping.urlEncoded(vault))&file=\(CaptureEscaping.urlEncoded(path))"
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Browser scripting

    private static func frontmostBrowserPage() -> (title: String, url: String)? {
        // Prefer whichever browser is frontmost; otherwise try Safari then Chrome.
        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let order: [Browser]
        switch bundle {
        case "com.apple.Safari": order = [.safari, .chrome]
        case "com.google.Chrome": order = [.chrome, .safari]
        default: order = [.safari, .chrome]
        }
        for browser in order {
            if let page = browser.currentPage() { return page }
        }
        return nil
    }

    private enum Browser {
        case safari, chrome

        var appName: String { self == .safari ? "Safari" : "Google Chrome" }

        var script: String {
            switch self {
            case .safari:
                return """
                if application "Safari" is running then
                    tell application "Safari"
                        if (count of windows) is 0 then return ""
                        set theURL to URL of current tab of front window
                        set theTitle to name of current tab of front window
                        return theTitle & "|||" & theURL
                    end tell
                else
                    return ""
                end if
                """
            case .chrome:
                return """
                if application "Google Chrome" is running then
                    tell application "Google Chrome"
                        if (count of windows) is 0 then return ""
                        set theURL to URL of active tab of front window
                        set theTitle to title of active tab of front window
                        return theTitle & "|||" & theURL
                    end tell
                else
                    return ""
                end if
                """
            }
        }

        func currentPage() -> (title: String, url: String)? {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: script) else { return nil }
            let output = script.executeAndReturnError(&error).stringValue ?? ""
            if let error {
                NSLog("NotchMate: \(appName) browser-capture error: \(error)")
                return nil
            }
            let parts = output.components(separatedBy: "|||")
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            return (parts[0], parts[1])
        }
    }
}
