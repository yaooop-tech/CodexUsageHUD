import Foundation

private struct ClaudeUsageCache: Decodable {
    let schemaVersion: Int
    let capturedAt: Double
    let fiveHour: ClaudeRateLimitCache?
    let sevenDay: ClaudeRateLimitCache?
    let session: ClaudeSessionCache?
}

private struct ClaudeRateLimitCache: Decodable {
    let usedPercentage: Double?
    let resetsAt: Double?
}

private struct ClaudeSessionCache: Decodable {
    let inputTokens: Int64?
    let outputTokens: Int64?
    let contextRemainingPercentage: Double?
    let claudeVersion: String?
}

private struct ClaudeAuthStatus: Decodable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let email: String?
    let subscriptionType: String?
}

private struct ClaudeOAuthCredentials: Sendable {
    let accessToken: String
    let expiresAt: Date?
}

private actor ClaudeOAuthClient {
    static let shared = ClaudeOAuthClient()
    private var blockedUntil: Date?

    func fetch(credentials: ClaudeOAuthCredentials) async throws -> (RateLimitWindow?, RateLimitWindow?) {
        if let blockedUntil, blockedUntil > Date() {
            throw OAuthUsageError.rateLimited(blockedUntil)
        }
        if let expiresAt = credentials.expiresAt, expiresAt <= Date() {
            throw OAuthUsageError.unauthorized("Claude")
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.0 CodexUsageHUD/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OAuthUsageError.invalidResponse("Claude OAuth returned no HTTP response.")
        }
        switch http.statusCode {
        case 200..<300:
            blockedUntil = nil
        case 401, 403:
            throw OAuthUsageError.unauthorized("Claude")
        case 429:
            let retryDate = OAuthJSON.retryDate(response: http) ?? Date().addingTimeInterval(120)
            blockedUntil = retryDate
            throw OAuthUsageError.rateLimited(retryDate)
        default:
            throw OAuthUsageError.http(http.statusCode)
        }

        let root = try OAuthJSON.dictionary(data)
        let primary = ClaudeOAuthUsageParser.window(root["five_hour"])
        let secondary = ClaudeOAuthUsageParser.window(root["seven_day"])
        guard primary != nil || secondary != nil else {
            throw OAuthUsageError.invalidResponse("Claude OAuth response did not include usage windows.")
        }
        return (primary, secondary)
    }

}

enum ClaudeOAuthUsageParser {
    static func window(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any],
              let utilization = OAuthJSON.double(object, keys: ["utilization", "used_percentage", "usedPercentage"]) else {
            return nil
        }
        return RateLimitWindow(
            usedPercent: max(0, min(100, utilization.rounded())),
            windowDurationMins: nil,
            resetsAt: OAuthJSON.epoch(OAuthJSON.value(object, keys: ["resets_at", "resetsAt"]))
        )
    }
}

struct ClaudeUsageService {
    func fetchSnapshot(previous: UsageSnapshot?, oauthEnabled: Bool) async throws -> UsageSnapshot {
        let cache = readCache()
        let session = Self.session(from: cache) ?? previous?.claudeSessionUsage

        if !oauthEnabled {
            let account = previous?.source == .statusLine ? previous?.account : nil
            if let snapshot = statusLineSnapshot(cache: cache, account: account, session: session, error: nil) {
                return snapshot
            }
            return waitingSnapshot(account: account, session: session)
        }

        let auth = await Task.detached(priority: .utility) { Self.readAuthStatus() }.value
        let account = Self.account(from: auth) ?? previous?.account

        do {
            let credentials = try Self.readOAuthCredentials()
            let windows = try await ClaudeOAuthClient.shared.fetch(credentials: credentials)
            let now = Date()
            return UsageSnapshot(
                provider: .claude,
                account: account,
                requiresOpenaiAuth: false,
                rateLimit: RateLimitSnapshot(
                    limitId: "claude",
                    limitName: "Claude",
                    primary: windows.0,
                    secondary: windows.1,
                    credits: nil,
                    individualLimit: nil,
                    planType: auth?.subscriptionType ?? previous?.rateLimit?.planType,
                    rateLimitReachedType: nil
                ),
                resetCredits: nil,
                tokenUsage: nil,
                claudeSessionUsage: session,
                source: .oauth,
                sourceUpdatedAt: now,
                sourceError: nil,
                fetchedAt: now
            )
        } catch {
            let oauthError = error.localizedDescription
            if let fallback = statusLineSnapshot(cache: cache, account: account, session: session, error: oauthError) {
                return fallback
            }
            if let previous {
                return previous.preservingData(sourceError: oauthError)
            }
            throw error
        }
    }

    private func statusLineSnapshot(cache: ClaudeUsageCache?, account: AccountInfo?, session: ClaudeSessionUsage?, error: String?) -> UsageSnapshot? {
        guard let cache else { return nil }
        let primary = cache.fiveHour.flatMap(Self.rateLimitWindow)
        let secondary = cache.sevenDay.flatMap(Self.rateLimitWindow)
        guard primary != nil || secondary != nil else { return nil }
        return UsageSnapshot(
            provider: .claude,
            account: account,
            requiresOpenaiAuth: false,
            rateLimit: RateLimitSnapshot(
                limitId: "claude",
                limitName: "Claude",
                primary: primary,
                secondary: secondary,
                credits: nil,
                individualLimit: nil,
                planType: account?.planType,
                rateLimitReachedType: nil
            ),
            resetCredits: nil,
            tokenUsage: nil,
            claudeSessionUsage: session,
            source: .statusLine,
            sourceUpdatedAt: Date(timeIntervalSince1970: cache.capturedAt),
            sourceError: error,
            fetchedAt: Date()
        )
    }

    func waitingSnapshot(account: AccountInfo?, session: ClaudeSessionUsage?) -> UsageSnapshot {
        UsageSnapshot(
            provider: .claude,
            account: account,
            requiresOpenaiAuth: false,
            rateLimit: RateLimitSnapshot(
                limitId: "claude",
                limitName: "Claude",
                primary: nil,
                secondary: nil,
                credits: nil,
                individualLimit: nil,
                planType: account?.planType,
                rateLimitReachedType: nil
            ),
            resetCredits: nil,
            tokenUsage: nil,
            claudeSessionUsage: session,
            source: .statusLine,
            sourceUpdatedAt: nil,
            sourceError: nil,
            fetchedAt: Date()
        )
    }

    private func readCache() -> ClaudeUsageCache? {
        guard let data = try? Data(contentsOf: ClaudeBridgePaths.usageCache),
              let cache = try? JSONDecoder().decode(ClaudeUsageCache.self, from: data),
              cache.schemaVersion == 1 else { return nil }
        return cache
    }

    private static func readOAuthCredentials() throws -> ClaudeOAuthCredentials {
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let data: Data
        if let fileData = try? Data(contentsOf: fileURL) {
            data = fileData
        } else {
            data = try readKeychainCredentials()
        }

        let root = try OAuthJSON.dictionary(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            throw OAuthUsageError.invalidCredentials("Claude credentials contain no Claude account OAuth session.")
        }
        guard let accessToken = OAuthJSON.string(oauth, keys: ["accessToken", "access_token"]), !accessToken.isEmpty else {
            throw OAuthUsageError.invalidCredentials("Claude OAuth credentials do not contain an access token.")
        }
        let expiryValue = OAuthJSON.double(oauth, keys: ["expiresAt", "expires_at"])
        let expiry = expiryValue.map { Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1_000 : $0) }
        return ClaudeOAuthCredentials(accessToken: accessToken, expiresAt: expiry)
    }

    private static func readKeychainCredentials() throws -> Data {
        let process = Process()
        let output = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }

        do {
            try process.run()
            guard completion.wait(timeout: .now() + 3) == .success else {
                process.terminate()
                throw OAuthUsageError.credentialsUnavailable("Claude Keychain access timed out.")
            }
            guard process.terminationStatus == 0 else {
                throw OAuthUsageError.credentialsUnavailable("Claude OAuth credentials are unavailable.")
            }
            var data = output.fileHandleForReading.readDataToEndOfFile()
            while data.last == 0x0A || data.last == 0x0D { data.removeLast() }
            guard !data.isEmpty else {
                throw OAuthUsageError.invalidCredentials("Claude OAuth credentials are empty.")
            }
            return data
        } catch let error as OAuthUsageError {
            throw error
        } catch {
            throw OAuthUsageError.credentialsUnavailable("Claude Keychain access failed.")
        }
    }

    private static func account(from auth: ClaudeAuthStatus?) -> AccountInfo? {
        guard let auth, auth.loggedIn else { return nil }
        return AccountInfo(type: auth.authMethod ?? "claude.ai", email: auth.email, planType: auth.subscriptionType)
    }

    private static func session(from cache: ClaudeUsageCache?) -> ClaudeSessionUsage? {
        cache?.session.map {
            ClaudeSessionUsage(
                inputTokens: $0.inputTokens,
                outputTokens: $0.outputTokens,
                contextRemainingPercent: $0.contextRemainingPercentage.map { max(0, min(100, Int($0.rounded()))) },
                claudeVersion: $0.claudeVersion
            )
        }
    }

    private static func rateLimitWindow(_ cache: ClaudeRateLimitCache) -> RateLimitWindow? {
        guard let usedPercentage = cache.usedPercentage else { return nil }
        return RateLimitWindow(
            usedPercent: max(0, min(100, usedPercentage.rounded())),
            windowDurationMins: nil,
            resetsAt: cache.resetsAt.map(Int64.init)
        )
    }

    private static func readAuthStatus() -> ClaudeAuthStatus? {
        guard let executable = ClaudeConnectionService.executable() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["auth", "status", "--json"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            let completion = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in completion.signal() }
            try process.run()
            guard completion.wait(timeout: .now() + 3) == .success else {
                process.terminate()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return try JSONDecoder().decode(ClaudeAuthStatus.self, from: output.fileHandleForReading.readDataToEndOfFile())
        } catch {
            return nil
        }
    }

}
