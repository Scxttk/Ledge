import Foundation

/// Pure helpers that keep captured text safe across the two write paths
/// (direct file append and `obsidian://` URLs) and the AppleScript used for
/// browser capture. Kept free of I/O so it is unit-testable.
enum CaptureEscaping {

    /// Percent-encode a value for use as an `obsidian://` query parameter.
    /// Encodes everything outside the RFC 3986 unreserved set so `&`, `#`, `/`
    /// and spaces in user text can't break out of the parameter.
    static func urlEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    /// Escape a string for embedding inside an AppleScript double-quoted literal.
    static func appleScriptEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Collapse a capture into a single markdown line: strip newlines (so it
    /// stays one bullet) and trim surrounding whitespace.
    static func sanitizeLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Sanitize a link title so it can't break the `[title](url)` markdown.
    static func sanitizeLinkTitle(_ text: String) -> String {
        sanitizeLine(text)
            .replacingOccurrences(of: "[", with: "(")
            .replacingOccurrences(of: "]", with: ")")
    }

    /// Wrap a URL for use as the destination in `[title](url)` markdown. Angle
    /// brackets let Obsidian/CommonMark keep spaces and `)` inside the URL
    /// instead of terminating the link early; any literal `>` is stripped so it
    /// can't close the wrapper.
    static func sanitizeLinkDestination(_ url: String) -> String {
        let cleaned = sanitizeLine(url).replacingOccurrences(of: ">", with: "")
        return "<\(cleaned)>"
    }

    /// True only if `target` resolves to a location inside `root` — blocks
    /// `../` traversal so capture can never write outside the chosen vault.
    static func isInside(_ target: URL, root: URL) -> Bool {
        let t = canonicalPath(target)
        let r = canonicalPath(root)
        let prefix = r.hasSuffix("/") ? r : r + "/"
        return t == r || t.hasPrefix(prefix)
    }

    /// Canonicalize a file path for containment checks. Standardizes (`..`/`.`),
    /// resolves symlinks, and strips the macOS `/private` firmlink prefix —
    /// `resolvingSymlinksInPath()` does *not* reconcile `/var` with
    /// `/private/var`, and a bookmark-resolved URL standardizes differently from
    /// a freshly-built one, so without this two paths to the same file can
    /// disagree.
    private static func canonicalPath(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        for firmlink in ["/private/var", "/private/tmp", "/private/etc"] where path.hasPrefix(firmlink) {
            path = String(path.dropFirst("/private".count))
            break
        }
        return path
    }

    /// Translate the common Obsidian/moment date tokens to `DateFormatter`
    /// syntax so a user who types `YYYY-MM-DD` (Obsidian's default) still gets
    /// the right filename.
    static func normalizedDateFormat(_ pattern: String) -> String {
        pattern
            .replacingOccurrences(of: "YYYY", with: "yyyy")
            .replacingOccurrences(of: "DD", with: "dd")
    }
}
