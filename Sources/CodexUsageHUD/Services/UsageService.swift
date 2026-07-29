import Foundation

struct UsageService {
    private let client = CodexAppServerClient.shared
    private let oauth = CodexOAuthUsageService()

    func fetchSnapshot(previous: UsageSnapshot?) async throws -> UsageSnapshot {
        // The app-server accepts concurrent component requests, but its
        // initialize handshake must happen exactly once on a cold connection.
        try await client.prepare()

        async let limitsRequest: ComponentFetch<AccountRateLimitsResponse> = capture {
            try await client.request("account/rateLimits/read")
        }
        async let accountRequest: ComponentFetch<AccountReadResponse> = capture {
            try await client.request(
                    "account/read",
                    params: ["refreshToken": false]
                )
        }
        async let tokenRequest: ComponentFetch<AccountTokenUsageResponse> = capture {
            try await client.request("account/usage/read")
        }

        let (limitsResult, accountResult, tokenResult) = await (
            limitsRequest,
            accountRequest,
            tokenRequest)
        let now = Date()
        var warnings: [String] = []

        let accountResponse = accountResult.value
        if let error = accountResult.error {
            warnings.append("Account details: \(error)")
        }
        if let error = tokenResult.error {
            warnings.append("Token usage: \(error)")
        }

        let quotaSnapshot: UsageSnapshot
        if let limits = limitsResult.value {
            let codexLimit = limits.rateLimitsByLimitId?["codex"] ?? limits.rateLimits
            quotaSnapshot = UsageSnapshot(
                provider: .codex,
                account: accountResponse?.account ?? previous?.account,
                requiresOpenaiAuth: accountResponse?.requiresOpenaiAuth
                    ?? previous?.requiresOpenaiAuth
                    ?? false,
                rateLimit: codexLimit,
                resetCredits: limits.rateLimitResetCredits?.availableCount ?? previous?.resetCredits,
                tokenUsage: tokenResult.value ?? previous?.tokenUsage,
                claudeSessionUsage: nil,
                source: .appServer,
                sourceUpdatedAt: now,
                sourceError: nil,
                fetchedAt: now
            )
        } else {
            let rateLimitError = limitsResult.error ?? "Codex rate limits are unavailable."
            warnings.insert("Rate limits: \(rateLimitError)", at: 0)
            do {
                quotaSnapshot = try await oauth.fetchSnapshot(previous: previous)
            } catch {
                warnings.append("OAuth fallback: \(error.localizedDescription)")
                guard let previous, previous.rateLimit != nil else {
                    throw OAuthUsageError.invalidResponse(warnings.joined(separator: " "))
                }
                quotaSnapshot = previous
            }
        }

        return Self.merge(
            quota: quotaSnapshot,
            account: accountResponse,
            tokenUsage: tokenResult.value,
            previous: previous,
            warnings: warnings,
            fetchedAt: now)
    }

    static func merge(
        quota: UsageSnapshot,
        account: AccountReadResponse?,
        tokenUsage: AccountTokenUsageResponse?,
        previous: UsageSnapshot?,
        warnings: [String],
        fetchedAt: Date
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: .codex,
            account: account?.account ?? quota.account ?? previous?.account,
            requiresOpenaiAuth: account?.requiresOpenaiAuth
                ?? quota.requiresOpenaiAuth,
            rateLimit: quota.rateLimit ?? previous?.rateLimit,
            resetCredits: quota.resetCredits ?? previous?.resetCredits,
            tokenUsage: tokenUsage ?? quota.tokenUsage ?? previous?.tokenUsage,
            claudeSessionUsage: nil,
            source: quota.source,
            sourceUpdatedAt: quota.sourceUpdatedAt,
            sourceError: warnings.isEmpty ? quota.sourceError : warnings.joined(separator: " "),
            fetchedAt: fetchedAt,
            supplementalWindows: quota.supplementalWindows)
    }

    private func capture<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> ComponentFetch<Value> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}

private enum ComponentFetch<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)

    var value: Value? {
        if case let .success(value) = self { return value }
        return nil
    }

    var error: String? {
        if case let .failure(message) = self { return message }
        return nil
    }
}
