import Foundation

/// One rate-limit window from the OAuth usage endpoint (5h, week, per-model …).
struct ClaudeUsageWindow: Identifiable, Equatable {
    /// The raw bucket key from the API, e.g. `five_hour`, `seven_day`,
    /// `seven_day_sonnet`.
    let id: String
    /// 0…1 share of the window already used.
    let utilization: Double
    let resetsAt: Date?

    var localizedLabel: String {
        switch id {
        case "five_hour", "session":
            return String(localized: "claude.window.fiveHour", defaultValue: "5 Std.")
        case "seven_day", "weekly_all":
            return String(localized: "claude.window.week", defaultValue: "Woche")
        default:
            // Model-scoped weekly entries: "weekly_scoped_fable" (or legacy
            // "seven_day_sonnet") → "Woche · Fable". Decoded dynamically so
            // entries can come and go with the plan without a code change.
            let model = id
                .replacingOccurrences(of: "weekly_scoped_", with: "")
                .replacingOccurrences(of: "seven_day_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
            return String(localized: "claude.window.weekModel", defaultValue: "Woche · \(model)")
        }
    }
}

/// Reads the Claude Code OAuth credential and fetches the account's usage
/// windows.
///
/// The credential is Claude Code's own (Keychain generic password, service
/// "Claude Code-credentials"; file fallback). Since Scott mostly works in the
/// Claude *desktop app*, the CLI rarely refreshes its token — so an expired
/// access token is the common case, and this model refreshes it itself with
/// the stored refresh token and **writes the rotated pair back** where Claude
/// Code expects it (user-approved; a botched write means one `/login` in the
/// CLI, nothing worse).
///
/// The usage endpoint rate-limits aggressively (429), so fetches are gated:
/// only on demand (tab in front), at most every `minRefreshInterval`, with a
/// longer backoff after a 429.
final class ClaudeUsageModel: ObservableObject {
    enum Status: Equatable {
        case idle
        case loading
        case loaded
        case noCredentials
        case tokenExpired
        case rateLimited
        case failed
    }

    @Published private(set) var windows: [ClaudeUsageWindow] = []
    @Published private(set) var status: Status = .idle
    @Published private(set) var lastUpdated: Date?

    /// True while any weekly bucket for Fable is present — drives the extra
    /// shifter lane, which thereby disappears on its own when the plan drops it.
    var hasFableBucket: Bool { windows.contains { $0.id.contains("fable") } }

    private let minRefreshInterval: TimeInterval = 5 * 60
    private let rateLimitBackoff: TimeInterval = 15 * 60
    private var nextAllowedFetch = Date.distantPast
    private var inFlight = false

    private static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Anthropic's official OAuth client id (the one Claude Code itself uses).
    private static let oauthClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Token endpoint moved from console.anthropic.com to platform.claude.com;
    /// try the new host first and fall back to the old one.
    private static let tokenEndpoints = [
        URL(string: "https://platform.claude.com/v1/oauth/token")!,
        URL(string: "https://console.anthropic.com/v1/oauth/token")!,
    ]

    /// Fetch if the gate allows it. Called from the Claude tab whenever it
    /// becomes the front page — deliberately no background timer (no-polling
    /// rule).
    func refreshIfStale() {
        ClaudeDebugLog.write("refreshIfStale (inFlight=\(inFlight))")
        guard !inFlight, Date() >= nextAllowedFetch else { return }
        inFlight = true
        if windows.isEmpty { status = .loading }
        nextAllowedFetch = Date().addingTimeInterval(minRefreshInterval)

        Task.detached(priority: .utility) { [weak self] in
            let outcome = await Self.loadUsage()
            ClaudeDebugLog.write("usage outcome=\(outcome.status) windows=\(outcome.windows?.count ?? -1)")
            guard let self else { return }
            await MainActor.run {
                self.inFlight = false
                self.status = outcome.status
                if let windows = outcome.windows {
                    self.windows = windows
                    self.lastUpdated = Date()
                }
                if outcome.status == .rateLimited {
                    self.nextAllowedFetch = Date().addingTimeInterval(self.rateLimitBackoff)
                }
            }
        }
    }

    // MARK: - Fetch pipeline

    private static func loadUsage() async -> (status: Status, windows: [ClaudeUsageWindow]?) {
        guard var credentials = Credentials.load() else { return (.noCredentials, nil) }

        // Proactively renew a token that is already (or almost) expired.
        if credentials.isExpired {
            guard await refresh(&credentials) else { return (.tokenExpired, nil) }
        }

        switch await fetchUsage(token: credentials.accessToken) {
        case .success(let windows):
            return (.loaded, windows)
        case .unauthorized:
            // Server disagrees with our expiry math — refresh once and retry.
            guard await refresh(&credentials) else { return (.tokenExpired, nil) }
            if case .success(let windows) = await fetchUsage(token: credentials.accessToken) {
                return (.loaded, windows)
            }
            return (.tokenExpired, nil)
        case .rateLimited:
            return (.rateLimited, nil)
        case .failed:
            return (.failed, nil)
        }
    }

    private enum FetchResult {
        case success([ClaudeUsageWindow])
        case unauthorized
        case rateLimited
        case failed
    }

    private static func fetchUsage(token: String) async -> FetchResult {
        var request = URLRequest(url: usageEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return .failed }
        switch http.statusCode {
        case 200:
            guard let windows = parse(data) else { return .failed }
            return .success(windows)
        case 401: return .unauthorized
        case 429: return .rateLimited
        default:  return .failed
        }
    }

    /// Exchange the refresh token for a new access/refresh pair and persist it
    /// back to Claude Code's credential store (Keychain and/or file — whichever
    /// the credential came from), so the CLI keeps working with the rotated pair.
    private static func refresh(_ credentials: inout Credentials) async -> Bool {
        guard let refreshToken = credentials.refreshToken else { return false }
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": oauthClientID,
        ]
        for endpoint in tokenEndpoints {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let accessToken = root["access_token"] as? String else { continue }
            let expiresIn = (root["expires_in"] as? Double) ?? 3600
            credentials.update(
                accessToken: accessToken,
                refreshToken: root["refresh_token"] as? String,
                expiresAt: Date().addingTimeInterval(expiresIn)
            )
            credentials.persist()
            return true
        }
        return false
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> [ClaudeUsageWindow]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Modern schema: the `limits` array is authoritative — session (5h),
        // weekly_all, and model-scoped weekly entries whose scope carries the
        // model's display name ("Fable"). Entries come and go with the plan,
        // so everything is decoded dynamically; when Anthropic drops Fable on
        // 19.7. its entry (and the shifter lane keyed off it) just disappears.
        if let limits = root["limits"] as? [[String: Any]] {
            let windows: [ClaudeUsageWindow] = limits.compactMap { entry in
                guard let kind = entry["kind"] as? String,
                      let percent = entry["percent"] as? Double else { return nil }
                var id = kind
                if let scope = entry["scope"] as? [String: Any],
                   let model = scope["model"] as? [String: Any],
                   let name = model["display_name"] as? String {
                    id = "\(kind)_\(name.lowercased())"
                }
                return ClaudeUsageWindow(
                    id: id,
                    utilization: min(max(percent / 100, 0), 1),
                    resetsAt: parseDate(entry["resets_at"])
                )
            }
            if !windows.isEmpty { return windows }
        }
        return parseLegacyBuckets(root)
    }

    /// Older schema: top-level objects carrying a `utilization` field
    /// (`five_hour`, `seven_day`, `seven_day_sonnet`, …). `utilization`
    /// arrives either as a 0–1 fraction or as a percent; normalise to 0–1.
    private static func parseLegacyBuckets(_ root: [String: Any]) -> [ClaudeUsageWindow]? {
        var result: [ClaudeUsageWindow] = []
        for (key, value) in root {
            guard let bucket = value as? [String: Any],
                  let rawUtil = bucket["utilization"] as? Double else { continue }
            let utilization = rawUtil > 1.5 ? rawUtil / 100 : rawUtil
            result.append(ClaudeUsageWindow(
                id: key,
                utilization: min(max(utilization, 0), 1),
                resetsAt: parseDate(bucket["resets_at"])
            ))
        }
        guard !result.isEmpty else { return nil }
        // Stable, human order: 5h first, overall week second, model buckets after.
        let rank: (String) -> Int = { id in
            if id == "five_hour" { return 0 }
            if id == "seven_day" { return 1 }
            return 2
        }
        return result.sorted { (rank($0.id), $0.id) < (rank($1.id), $1.id) }
    }

    private static func parseDate(_ value: Any?) -> Date? {
        if let epoch = value as? Double { return Date(timeIntervalSince1970: epoch) }
        guard let string = value as? String else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}

// MARK: - Claude Code's credential store

/// The full credential JSON plus where it came from, so a refreshed token can
/// be written back to the same place(s) without disturbing sibling fields.
private struct Credentials {
    private var root: [String: Any]
    private var fromKeychain: Bool
    private var fileURL: URL?

    private static let keychainService = "Claude Code-credentials"
    private static var credentialsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.claude/.credentials.json")
    }

    private var oauth: [String: Any] { root["claudeAiOauth"] as? [String: Any] ?? [:] }

    var accessToken: String { oauth["accessToken"] as? String ?? "" }
    var refreshToken: String? { oauth["refreshToken"] as? String }

    /// Expired (or expiring within the next minute — don't race the request).
    var isExpired: Bool {
        guard let ms = oauth["expiresAt"] as? Double else { return false }
        return Date(timeIntervalSince1970: ms / 1000) < Date().addingTimeInterval(60)
    }

    static func load() -> Credentials? {
        if let data = keychainData(),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (root["claudeAiOauth"] as? [String: Any])?["accessToken"] is String {
            var credentials = Credentials(root: root, fromKeychain: true, fileURL: nil)
            if FileManager.default.fileExists(atPath: credentialsFile.path) {
                credentials.fileURL = credentialsFile
            }
            return credentials
        }
        if let data = try? Data(contentsOf: credentialsFile),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (root["claudeAiOauth"] as? [String: Any])?["accessToken"] is String {
            return Credentials(root: root, fromKeychain: false, fileURL: credentialsFile)
        }
        return nil
    }

    mutating func update(accessToken: String, refreshToken: String?, expiresAt: Date) {
        var oauth = self.oauth
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        oauth["expiresAt"] = expiresAt.timeIntervalSince1970 * 1000
        root["claudeAiOauth"] = oauth
    }

    /// Write the rotated credential back everywhere it was found. Best effort:
    /// a failed write only means the CLI needs one `/login`.
    func persist() {
        guard let data = try? JSONSerialization.data(withJSONObject: root) else { return }
        if fromKeychain {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.keychainService,
            ]
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        if let fileURL {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
