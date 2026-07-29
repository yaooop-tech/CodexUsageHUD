import Darwin
import Foundation
import SQLite3

enum KimiUsageError: LocalizedError, Equatable {
    case encryptedDesktopCookie
    case expiredDesktopSession
    case invalidDesktopSession
    case noCredentials
    case unauthorized
    case invalidResponse(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .encryptedDesktopCookie:
            return "Kimi now stores its desktop session in an encrypted cookie. Sign in again or reassess the data source."
        case .expiredDesktopSession, .unauthorized:
            return "Kimi authorization expired. Open Kimi and sign in again."
        case .invalidDesktopSession:
            return "Kimi desktop session is invalid. Open Kimi and sign in again."
        case .noCredentials:
            return "No Kimi desktop session or fresh Kimi Code CLI credential was found."
        case .invalidResponse(let message):
            return message
        case .http(let status):
            return "Kimi usage request failed with HTTP \(status)."
        }
    }
}

struct KimiDesktopCredential: Sendable {
    let accessToken: String
    let deviceID: String?
    let sessionID: String?
    let trafficID: String?
}

struct KimiCodeCredential: Sendable {
    let accessToken: String
    let deviceID: String
}

struct KimiCredentialStore: Sendable {
    let cookieDatabaseURL: URL
    let cliCredentialURL: URL
    let cliDeviceIDURL: URL

    init(
        cookieDatabaseURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/kimi-desktop/Cookies"),
        cliCredentialURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/credentials/kimi-code.json"),
        cliDeviceIDURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/device_id"))
    {
        self.cookieDatabaseURL = cookieDatabaseURL
        self.cliCredentialURL = cliCredentialURL
        self.cliDeviceIDURL = cliDeviceIDURL
    }

    func desktopCredential(now: Date = Date()) throws -> KimiDesktopCredential? {
        guard FileManager.default.fileExists(atPath: cookieDatabaseURL.path) else { return nil }

        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(cookieDatabaseURL.path, &database, flags, nil) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close(database) }
            throw KimiUsageError.invalidDesktopSession
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)

        let sql = """
        SELECT value, length(encrypted_value), expires_utc
        FROM cookies
        WHERE host_key IN ('www.kimi.com', '.kimi.com') AND name = 'kimi-auth'
        ORDER BY expires_utc DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw KimiUsageError.invalidDesktopSession
        }
        defer { sqlite3_finalize(statement) }

        var sawEncryptedCookie = false
        while sqlite3_step(statement) == SQLITE_ROW {
            let value = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
            let encryptedLength = sqlite3_column_int(statement, 1)
            let chromiumExpiry = sqlite3_column_double(statement, 2)
            guard !value.isEmpty else {
                sawEncryptedCookie = sawEncryptedCookie || encryptedLength > 0
                continue
            }
            if chromiumExpiry > 0 {
                let unixExpiry = chromiumExpiry / 1_000_000 - 11_644_473_600
                guard unixExpiry > now.timeIntervalSince1970 else { continue }
            }
            return try Self.desktopCredential(token: value, now: now)
        }

        if sawEncryptedCookie { throw KimiUsageError.encryptedDesktopCookie }
        return nil
    }

    func codeCredential(now: Date = Date()) -> KimiCodeCredential? {
        guard let data = try? Data(contentsOf: cliCredentialURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = Self.string(object["access_token"]), !token.isEmpty,
              let expiresAt = Self.number(object["expires_at"]),
              expiresAt > now.addingTimeInterval(60).timeIntervalSince1970
        else { return nil }

        let storedDeviceID = (try? String(contentsOf: cliDeviceIDURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return KimiCodeCredential(
            accessToken: token,
            deviceID: storedDeviceID?.isEmpty == false ? storedDeviceID! : UUID().uuidString.lowercased())
    }

    static func desktopCredential(token: String, now: Date) throws -> KimiDesktopCredential {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            return KimiDesktopCredential(accessToken: token, deviceID: nil, sessionID: nil, trafficID: nil)
        }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while encoded.count.isMultiple(of: 4) == false { encoded += "=" }
        guard let payload = Data(base64Encoded: encoded),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw KimiUsageError.invalidDesktopSession }
        if let expiry = number(claims["exp"]), expiry <= now.timeIntervalSince1970 {
            throw KimiUsageError.expiredDesktopSession
        }
        return KimiDesktopCredential(
            accessToken: token,
            deviceID: string(claims["device_id"]),
            sessionID: string(claims["ssid"]),
            trafficID: string(claims["sub"]))
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

protocol KimiHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct KimiURLSessionTransport: KimiHTTPTransport {
    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw KimiUsageError.invalidResponse("Kimi returned no HTTP response.")
        }
        return (data, http)
    }
}

private enum KimiCredentialSource: Sendable {
    case desktop
    case cli
}

private struct KimiWindowCandidate: Sendable {
    let kind: UsageWindowKind
    let window: UsageWindow
    let priority: Int
    let source: KimiCredentialSource
}

private struct KimiEndpointPayload: Sendable {
    let candidates: [KimiWindowCandidate]
    let planTitle: String?
}

private enum KimiEndpointOutcome: Sendable {
    case success(KimiEndpointPayload)
    case failure(label: String, message: String, unauthorized: Bool)
    case cancelled
}

struct KimiUsageService: Sendable {
    private static let webBase = "https://www.kimi.com/apiv2"
    private static let usagesURL = URL(string: "\(webBase)/kimi.gateway.billing.v1.BillingService/GetUsages")!
    private static let statsURL = URL(string: "\(webBase)/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats")!
    private static let subscriptionURL = URL(string: "\(webBase)/kimi.gateway.membership.v2.MembershipService/GetSubscription")!
    private static let codeURL = URL(string: "https://api.kimi.com/coding/v1/usages")!

    let credentials: KimiCredentialStore
    let transport: any KimiHTTPTransport

    init(
        credentials: KimiCredentialStore = KimiCredentialStore(),
        transport: any KimiHTTPTransport = KimiURLSessionTransport())
    {
        self.credentials = credentials
        self.transport = transport
    }

    func fetchSnapshot(previous: UsageSnapshot?) async throws -> UsageSnapshot {
        do {
            return try await fetchFreshSnapshot()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let previous { return previous.preservingData(sourceError: error.localizedDescription) }
            throw error
        }
    }

    private func fetchFreshSnapshot() async throws -> UsageSnapshot {
        try Task.checkCancellation()
        var discoveryWarnings: [String] = []
        let desktop: KimiDesktopCredential?
        do {
            desktop = try credentials.desktopCredential()
        } catch {
            desktop = nil
            discoveryWarnings.append(error.localizedDescription)
        }
        let cli = credentials.codeCredential()
        guard desktop != nil || cli != nil else {
            if let warning = discoveryWarnings.first {
                throw KimiUsageError.invalidResponse(warning)
            }
            throw KimiUsageError.noCredentials
        }

        let outcomes = await withTaskGroup(of: KimiEndpointOutcome.self, returning: [KimiEndpointOutcome].self) { group in
            if let desktop {
                group.addTask { await capture("Kimi Coding usage") { try await fetchWebUsage(desktop) } }
                group.addTask { await capture("Kimi subscription stats") { try await fetchSubscriptionStats(desktop) } }
                group.addTask { await capture("Kimi subscription") { try await fetchSubscription(desktop) } }
            }
            if let cli {
                group.addTask { await capture("Kimi Code CLI") { try await fetchCodeUsage(cli) } }
            }
            var values: [KimiEndpointOutcome] = []
            for await outcome in group { values.append(outcome) }
            return values
        }
        try Task.checkCancellation()

        var candidates: [KimiWindowCandidate] = []
        var planTitles: [String] = []
        var warnings = discoveryWarnings
        var unauthorized = false
        for outcome in outcomes {
            switch outcome {
            case .success(let payload):
                candidates.append(contentsOf: payload.candidates)
                if let plan = payload.planTitle, !plan.isEmpty { planTitles.append(plan) }
            case .failure(let label, let message, let isUnauthorized):
                unauthorized = unauthorized || isUnauthorized
                warnings.append("\(label): \(message)")
            case .cancelled:
                throw CancellationError()
            }
        }

        var selected: [KimiWindowCandidate] = []
        for kind in UsageWindowKind.allCases {
            if let best = candidates.filter({ $0.kind == kind }).max(by: { $0.priority < $1.priority }) {
                selected.append(best)
            }
        }
        guard !selected.isEmpty else {
            if unauthorized { throw KimiUsageError.unauthorized }
            throw KimiUsageError.invalidResponse("Kimi returned no usable usage windows.")
        }

        let usesDesktop = selected.contains(where: { $0.source == .desktop })
        let usesCLI = selected.contains(where: { $0.source == .cli })
        let source: UsageDataSource = usesDesktop && usesCLI ? .kimiCombined : (usesCLI ? .kimiCodeCLI : .kimiDesktop)
        let now = Date()
        let plan = planTitles.first
        return UsageSnapshot(
            provider: .kimi,
            account: AccountInfo(type: "kimi", email: nil, planType: plan),
            requiresOpenaiAuth: false,
            rateLimit: RateLimitSnapshot(
                limitId: "kimi",
                limitName: "Kimi",
                primary: nil,
                secondary: nil,
                credits: nil,
                individualLimit: nil,
                planType: plan,
                rateLimitReachedType: nil),
            resetCredits: nil,
            tokenUsage: nil,
            claudeSessionUsage: nil,
            source: source,
            sourceUpdatedAt: now,
            sourceError: warnings.isEmpty ? nil : warnings.joined(separator: " "),
            fetchedAt: now,
            supplementalWindows: selected
                .map { UsageDisplayWindow(kind: $0.kind, window: $0.window) }
                .sorted { $0.kind.sortOrder < $1.kind.sortOrder })
    }

    private func capture(
        _ label: String,
        operation: @escaping @Sendable () async throws -> KimiEndpointPayload) async -> KimiEndpointOutcome
    {
        do {
            return .success(try await operation())
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(
                label: label,
                message: error.localizedDescription,
                unauthorized: (error as? KimiUsageError) == .unauthorized)
        }
    }

    private func fetchWebUsage(_ credential: KimiDesktopCredential) async throws -> KimiEndpointPayload {
        var request = webRequest(url: Self.usagesURL, credential: credential)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])
        let root = try await loadJSON(request)
        guard let usages = root["usages"] as? [[String: Any]],
              let coding = usages.first(where: { Self.string($0["scope"]) == "FEATURE_CODING" })
        else { return KimiEndpointPayload(candidates: [], planTitle: nil) }

        var candidates: [KimiWindowCandidate] = []
        if let detail = coding["detail"] as? [String: Any],
           let window = Self.quotaWindow(detail, durationMinutes: 10_080)
        {
            candidates.append(KimiWindowCandidate(kind: .codeSevenDay, window: window, priority: 20, source: .desktop))
        }
        if let limits = coding["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let windowInfo = limit["window"] as? [String: Any],
                      Self.durationMinutes(windowInfo) == 300,
                      let detail = limit["detail"] as? [String: Any],
                      let window = Self.quotaWindow(detail, durationMinutes: 300)
                else { continue }
                candidates.append(KimiWindowCandidate(kind: .fiveHour, window: window, priority: 30, source: .desktop))
            }
        }
        return KimiEndpointPayload(candidates: candidates, planTitle: nil)
    }

    private func fetchSubscriptionStats(_ credential: KimiDesktopCredential) async throws -> KimiEndpointPayload {
        var request = webRequest(url: Self.statsURL, credential: credential)
        request.httpBody = Data("{}".utf8)
        let root = try await loadJSON(request)
        var candidates: [KimiWindowCandidate] = []
        if let limit = root["ratelimitCode5h"] as? [String: Any],
           Self.bool(limit["enabled"]) != false,
           let window = Self.ratioWindow(limit, durationMinutes: 300)
        {
            candidates.append(KimiWindowCandidate(kind: .fiveHour, window: window, priority: 100, source: .desktop))
        }
        if let limit = root["ratelimitCode7d"] as? [String: Any],
           Self.bool(limit["enabled"]) != false,
           let window = Self.ratioWindow(limit, durationMinutes: 10_080)
        {
            candidates.append(KimiWindowCandidate(kind: .codeSevenDay, window: window, priority: 100, source: .desktop))
        }
        if let balance = root["subscriptionBalance"] as? [String: Any],
           let window = Self.monthlyWindow(balance)
        {
            candidates.append(KimiWindowCandidate(kind: .monthly, window: window, priority: 100, source: .desktop))
        }
        return KimiEndpointPayload(candidates: candidates, planTitle: nil)
    }

    private func fetchSubscription(_ credential: KimiDesktopCredential) async throws -> KimiEndpointPayload {
        var request = webRequest(url: Self.subscriptionURL, credential: credential)
        request.httpBody = Data("{}".utf8)
        let root = try await loadJSON(request)
        let container = (root["subscription"] as? [String: Any]) ?? root
        let goods = container["goods"] as? [String: Any]
        let plan = Self.string(goods?["title"])
            ?? Self.string(container["goodsTitle"])
            ?? Self.string(root["goodsTitle"])
        var candidates: [KimiWindowCandidate] = []
        let balances = (container["balances"] as? [[String: Any]]) ?? (root["balances"] as? [[String: Any]]) ?? []
        if let balance = balances.first(where: { Self.isMonthlyBalance($0) }),
           let window = Self.monthlyWindow(balance)
        {
            candidates.append(KimiWindowCandidate(kind: .monthly, window: window, priority: 90, source: .desktop))
        }
        return KimiEndpointPayload(candidates: candidates, planTitle: plan)
    }

    private func fetchCodeUsage(_ credential: KimiCodeCredential) async throws -> KimiEndpointPayload {
        var request = URLRequest(url: Self.codeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in Self.codeIdentityHeaders(deviceID: credential.deviceID) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let root = try await loadJSON(request)
        var candidates: [KimiWindowCandidate] = []
        if let usage = root["usage"] as? [String: Any],
           let window = Self.quotaWindow(usage, durationMinutes: 10_080)
        {
            candidates.append(KimiWindowCandidate(kind: .codeSevenDay, window: window, priority: 40, source: .cli))
        }
        if let limits = root["limits"] as? [[String: Any]] {
            for limit in limits {
                guard let info = limit["window"] as? [String: Any],
                      Self.durationMinutes(info) == 300,
                      let detail = limit["detail"] as? [String: Any],
                      let window = Self.quotaWindow(detail, durationMinutes: 300)
                else { continue }
                candidates.append(KimiWindowCandidate(kind: .fiveHour, window: window, priority: 40, source: .cli))
            }
        }
        return KimiEndpointPayload(candidates: candidates, planTitle: nil)
    }

    private func webRequest(url: URL, credential: KimiDesktopCredential) -> URLRequest {
        precondition(url.host == "www.kimi.com")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(credential.accessToken)", forHTTPHeaderField: "Cookie")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.setValue(TimeZone.current.identifier, forHTTPHeaderField: "r-timezone")
        request.setValue("CodexUsageHUD/\(AppMetadata.version)", forHTTPHeaderField: "User-Agent")
        if let value = credential.deviceID { request.setValue(value, forHTTPHeaderField: "x-msh-device-id") }
        if let value = credential.sessionID { request.setValue(value, forHTTPHeaderField: "x-msh-session-id") }
        if let value = credential.trafficID { request.setValue(value, forHTTPHeaderField: "x-traffic-id") }
        return request
    }

    private func loadJSON(_ request: URLRequest) async throws -> [String: Any] {
        try Task.checkCancellation()
        let (data, response) = try await transport.response(for: request)
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw KimiUsageError.unauthorized
        default: throw KimiUsageError.http(response.statusCode)
        }
        try Task.checkCancellation()
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KimiUsageError.invalidResponse("Kimi response was not a JSON object.")
        }
        return root
    }

    private static func quotaWindow(_ detail: [String: Any], durationMinutes: Int64) -> UsageWindow? {
        guard let limit = number(detail["limit"]), limit > 0 else { return nil }
        let remaining = number(detail["remaining"])
        let used = number(detail["used"]) ?? remaining.map { max(0, limit - $0) }
        guard let used, used.isFinite else { return nil }
        return UsageWindow(
            usedPercent: max(0, min(100, used / limit * 100)),
            durationMinutes: durationMinutes,
            resetsAt: date(value(detail, keys: ["resetTime", "resetAt", "reset_time", "reset_at"])))
    }

    private static func ratioWindow(_ object: [String: Any], durationMinutes: Int64?) -> UsageWindow? {
        guard let ratio = number(object["ratio"]), ratio.isFinite, (0...1).contains(ratio) else { return nil }
        return UsageWindow(
            usedPercent: ratio * 100,
            durationMinutes: durationMinutes,
            resetsAt: date(value(object, keys: ["resetTime", "resetAt", "reset_time", "reset_at"])))
    }

    private static func monthlyWindow(_ object: [String: Any]) -> UsageWindow? {
        guard isMonthlyBalance(object),
              let ratio = number(value(object, keys: ["amountUsedRatio", "amount_used_ratio"])),
              ratio.isFinite, (0...1).contains(ratio)
        else { return nil }
        return UsageWindow(
            usedPercent: ratio * 100,
            durationMinutes: nil,
            resetsAt: date(value(object, keys: ["expireTime", "expiresAt", "expire_time", "expires_at"])))
    }

    private static func isMonthlyBalance(_ object: [String: Any]) -> Bool {
        let feature = string(object["feature"])
        let type = string(object["type"])
        return (feature == nil || feature == "FEATURE_OMNI") && (type == nil || type == "SUBSCRIPTION")
    }

    private static func durationMinutes(_ object: [String: Any]) -> Int64? {
        guard let duration = number(object["duration"]) else { return nil }
        switch string(value(object, keys: ["timeUnit", "time_unit"]))?.lowercased() {
        case "minute", "minutes", "m": return Int64(duration)
        case "hour", "hours", "h": return Int64(duration * 60)
        case "day", "days", "d": return Int64(duration * 1_440)
        default: return Int64(duration)
        }
    }

    private static func codeIdentityHeaders(deviceID: String) -> [String: String] {
        let version = AppMetadata.version
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return [
            "User-Agent": "CodexUsageHUD/\(version)",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": version,
            "X-Msh-Device-Name": ascii(ProcessInfo.processInfo.hostName),
            "X-Msh-Device-Model": "macOS \(osVersion) \(architecture)",
            "X-Msh-Os-Version": osVersion,
            "X-Msh-Device-Id": deviceID,
        ]
    }

    private static func value(_ object: [String: Any], keys: [String]) -> Any? {
        for key in keys where object[key] != nil { return object[key] }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return ["true", "1"].contains(value.lowercased()) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let number = number(value) {
            return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
        }
        guard let string = string(value) else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    private static func ascii(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter { (0x20...0x7e).contains($0.value) }
        let result = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return result.isEmpty ? "unknown" : result
    }
}
