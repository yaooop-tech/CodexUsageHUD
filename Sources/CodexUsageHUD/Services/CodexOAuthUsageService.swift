import Foundation

struct CodexOAuthUsageService {
    private struct Credentials: Sendable {
        let accessToken: String
        let accountID: String?
    }

    func fetchSnapshot(previous: UsageSnapshot?) async throws -> UsageSnapshot {
        let credentials = try readCredentials()
        let now = Date()
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.timeoutInterval = 8
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexUsageHUD/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let data = try await load(request, service: "Codex")
        let root = try OAuthJSON.dictionary(data)
        guard let rateLimit = Self.rateLimit(from: root) else {
            throw OAuthUsageError.invalidResponse("Codex OAuth response did not include rate limits.")
        }
        let resetCredits = await fetchResetCredits(credentials: credentials)

        return UsageSnapshot(
            provider: .codex,
            account: previous?.account,
            requiresOpenaiAuth: false,
            rateLimit: rateLimit,
            resetCredits: resetCredits ?? previous?.resetCredits,
            tokenUsage: previous?.tokenUsage,
            claudeSessionUsage: nil,
            source: .oauth,
            sourceUpdatedAt: now,
            sourceError: nil,
            fetchedAt: now
        )
    }

    private func readCredentials() throws -> Credentials {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw OAuthUsageError.credentialsUnavailable("Codex OAuth credentials are unavailable.")
        }
        let root = try OAuthJSON.dictionary(data)
        guard let tokens = root["tokens"] as? [String: Any],
              let accessToken = OAuthJSON.string(tokens, keys: ["access_token", "accessToken"]),
              !accessToken.isEmpty else {
            throw OAuthUsageError.invalidCredentials("Codex OAuth credentials do not contain an access token.")
        }
        return Credentials(
            accessToken: accessToken,
            accountID: OAuthJSON.string(tokens, keys: ["account_id", "accountId"])
        )
    }

    private func fetchResetCredits(credentials: Credentials) async -> Int64? {
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!)
        request.timeoutInterval = 5
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("CodexUsageHUD/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        guard let data = try? await load(request, service: "Codex"),
              let root = try? OAuthJSON.dictionary(data) else { return nil }
        let container = (root["rate_limit_reset_credits"] as? [String: Any])
            ?? (root["rateLimitResetCredits"] as? [String: Any])
            ?? root
        return OAuthJSON.double(container, keys: ["available_count", "availableCount", "count"]).map(Int64.init)
    }

    private func load(_ request: URLRequest, service: String) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthUsageError.invalidResponse("\(service) OAuth returned no HTTP response.")
        }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw OAuthUsageError.unauthorized(service)
        case 429: throw OAuthUsageError.rateLimited(OAuthJSON.retryDate(response: http))
        default: throw OAuthUsageError.http(http.statusCode)
        }
    }

    static func rateLimit(from root: [String: Any]) -> RateLimitSnapshot? {
        let container = (root["rate_limit"] as? [String: Any])
            ?? (root["rateLimit"] as? [String: Any])
            ?? root
        let primary = window(from: container, keys: ["primary_window", "primaryWindow", "primary"])
        let secondary = window(from: container, keys: ["secondary_window", "secondaryWindow", "secondary"])
        guard primary != nil || secondary != nil else { return nil }

        let creditsObject = (root["credits"] as? [String: Any]) ?? (container["credits"] as? [String: Any])
        let credits = creditsObject.map {
            CreditsSnapshot(
                hasCredits: OAuthJSON.bool($0, keys: ["has_credits", "hasCredits"]) ?? false,
                unlimited: OAuthJSON.bool($0, keys: ["unlimited"]) ?? false,
                balance: OAuthJSON.string($0, keys: ["balance"])
            )
        }
        return RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: primary,
            secondary: secondary,
            credits: credits,
            individualLimit: nil,
            planType: OAuthJSON.string(root, keys: ["plan_type", "planType"]),
            rateLimitReachedType: OAuthJSON.string(container, keys: ["rate_limit_reached_type", "rateLimitReachedType"])
        )
    }

    private static func window(from object: [String: Any], keys: [String]) -> RateLimitWindow? {
        var source: [String: Any]?
        for key in keys where source == nil { source = object[key] as? [String: Any] }
        guard let source,
              let used = OAuthJSON.double(source, keys: ["used_percent", "usedPercent", "utilization"]) else { return nil }
        let durationSeconds = OAuthJSON.double(source, keys: ["limit_window_seconds", "window_seconds", "windowDurationSeconds"])
        let durationMinutes = OAuthJSON.double(source, keys: ["window_duration_mins", "windowDurationMins"])
            ?? durationSeconds.map { $0 / 60 }
        let resetsAt = OAuthJSON.epoch(OAuthJSON.value(source, keys: ["reset_at", "resets_at", "resetsAt"]))
            ?? OAuthJSON.double(source, keys: ["reset_after_seconds", "resetAfterSeconds"]).map { Int64(Date().addingTimeInterval($0).timeIntervalSince1970) }
        return RateLimitWindow(
            usedPercent: max(0, min(100, used.rounded())),
            windowDurationMins: durationMinutes.map(Int64.init),
            resetsAt: resetsAt
        )
    }
}
