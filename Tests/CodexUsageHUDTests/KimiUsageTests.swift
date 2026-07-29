import Foundation
import SQLite3
import Testing
@testable import CodexUsageHUD

private struct KimiHTTPStub: Sendable {
    let status: Int
    let body: String
}

private struct KimiRequestRecord: Sendable {
    let host: String?
    let endpoint: String
    let hasCookie: Bool
    let hasAuthorization: Bool
}

private actor KimiMockTransport: KimiHTTPTransport {
    private let stubs: [String: KimiHTTPStub]
    private var records: [KimiRequestRecord] = []

    init(stubs: [String: KimiHTTPStub]) {
        self.stubs = stubs
    }

    func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let endpoint = request.url?.lastPathComponent ?? ""
        records.append(KimiRequestRecord(
            host: request.url?.host,
            endpoint: endpoint,
            hasCookie: request.value(forHTTPHeaderField: "Cookie") != nil,
            hasAuthorization: request.value(forHTTPHeaderField: "Authorization") != nil))
        let stub = stubs[endpoint] ?? KimiHTTPStub(status: 500, body: "{}")
        if stub.status == -1 { throw CancellationError() }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: nil)!
        return (Data(stub.body.utf8), response)
    }

    func capturedRequests() -> [KimiRequestRecord] { records }
}

struct KimiCredentialTests {
    @Test func missingDesktopCookieReturnsNil() throws {
        let fixture = try KimiFixture()
        #expect(try fixture.store.desktopCredential() == nil)
    }

    @Test func readsPlainDesktopCookieWithoutWritingDatabase() throws {
        let fixture = try KimiFixture()
        let token = Self.jwt(expiry: Date().addingTimeInterval(3_600), deviceID: "device-a")
        try fixture.writeCookie(value: token)
        let before = try Data(contentsOf: fixture.cookieURL)

        let discovered = try fixture.store.desktopCredential()
        let credential = try #require(discovered)

        #expect(credential.accessToken == token)
        #expect(credential.deviceID == "device-a")
        #expect(try Data(contentsOf: fixture.cookieURL) == before)
    }

    @Test func reportsEncryptedCookieInsteadOfDecryptingIt() throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "", encrypted: Data([1, 2, 3]))

        #expect(throws: KimiUsageError.encryptedDesktopCookie) {
            try fixture.store.desktopCredential()
        }
    }

    @Test func rejectsExpiredJWT() {
        let token = Self.jwt(expiry: Date().addingTimeInterval(-1), deviceID: nil)
        #expect(throws: KimiUsageError.expiredDesktopSession) {
            try KimiCredentialStore.desktopCredential(token: token, now: Date())
        }
    }

    @Test func acceptsOnlyFreshCLIcredentialAndDoesNotRewriteIt() throws {
        let fixture = try KimiFixture()
        let fresh = #"{"access_token":"cli-token","refresh_token":"must-not-be-used","expires_at":"4102444800"}"#
        try FileManager.default.createDirectory(at: fixture.cliURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fresh.utf8).write(to: fixture.cliURL)
        let before = try Data(contentsOf: fixture.cliURL)

        let credential = try #require(fixture.store.codeCredential(now: Date(timeIntervalSince1970: 2_000_000_000)))

        #expect(credential.accessToken == "cli-token")
        #expect(try Data(contentsOf: fixture.cliURL) == before)
    }

    @Test func rejectsCLIcredentialInsideSafetyWindow() throws {
        let fixture = try KimiFixture()
        try fixture.writeCLI(token: "cli-token", expiresAt: Date().addingTimeInterval(30))
        #expect(fixture.store.codeCredential() == nil)
    }

    private static func jwt(expiry: Date, deviceID: String?) -> String {
        var claims: [String: Any] = ["exp": Int(expiry.timeIntervalSince1970), "ssid": "session-a", "sub": "traffic-a"]
        claims["device_id"] = deviceID
        let data = try! JSONSerialization.data(withJSONObject: claims)
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "header.\(payload).signature"
    }
}

struct KimiUsageServiceTests {
    @Test func cancellationDoesNotContinueWithSuccessfulFallbacks() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        var stubs = Self.monthlyStubs()
        stubs["GetUsages"] = KimiHTTPStub(status: -1, body: "{}")

        await #expect(throws: CancellationError.self) {
            try await KimiUsageService(
                credentials: fixture.store,
                transport: KimiMockTransport(stubs: stubs)).fetchSnapshot(previous: nil)
        }
    }

    @Test func ignoresInvalidRatiosAndRequiresAtLeastOneValidWindow() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        let stubs = [
            "GetUsages": KimiHTTPStub(status: 200, body: #"{"usages":[]}"#),
            "GetSubscriptionStats": KimiHTTPStub(status: 200, body: #"{"subscriptionBalance":{"amountUsedRatio":1.5}}"#),
            "GetSubscription": KimiHTTPStub(status: 200, body: #"{"goodsTitle":"Adagio","balances":[]}"#),
        ]

        await #expect(throws: KimiUsageError.invalidResponse("Kimi returned no usable usage windows.")) {
            try await KimiUsageService(
                credentials: fixture.store,
                transport: KimiMockTransport(stubs: stubs)).fetchSnapshot(previous: nil)
        }
    }

    @Test func acceptsMonthlyOnlySnapshotWithFractionalPrecisionAndPlan() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        let transport = KimiMockTransport(stubs: Self.monthlyStubs())
        let snapshot = try await KimiUsageService(credentials: fixture.store, transport: transport).fetchSnapshot(previous: nil)

        #expect(snapshot.provider == .kimi)
        #expect(snapshot.displayWindows.map(\.kind) == [.monthly])
        #expect(snapshot.collapsedDisplayWindows.count == 1)
        #expect(UsagePercentFormatter.string(snapshot.displayWindows[0].window.remainingPercent) == "99.6")
        #expect(snapshot.planLabel == "Adagio")
        #expect(snapshot.source == .kimiDesktop)

        let requests = await transport.capturedRequests()
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.host == "www.kimi.com" && $0.hasCookie && $0.hasAuthorization })
    }

    @Test func displaysAllThreeWindowsInPriorityOrder() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        var stubs = Self.monthlyStubs()
        stubs["GetSubscriptionStats"] = KimiHTTPStub(status: 200, body: #"""
        {
          "ratelimitCode5h":{"ratio":"0.1","enabled":true,"reset_at":"2026-07-18T01:00:00Z"},
          "ratelimitCode7d":{"ratio":0.2,"enabled":true,"resetTime":"2026-07-24T01:00:00Z"},
          "subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":"0.0036","expireTime":"2026-08-17T04:45:55.725391Z"}
        }
        """#)

        let snapshot = try await KimiUsageService(
            credentials: fixture.store,
            transport: KimiMockTransport(stubs: stubs)).fetchSnapshot(previous: nil)

        #expect(snapshot.displayWindows.map(\.kind) == [.fiveHour, .codeSevenDay, .monthly])
        #expect(snapshot.displayWindows.map(\.window.remainingPercent) == [90, 80, 99.64])
        #expect(snapshot.collapsedDisplayWindows.map(\.kind) == [.fiveHour, .codeSevenDay])
    }

    @Test func mergesCLIAndDesktopWithoutSendingTokensAcrossHosts() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        try fixture.writeCLI(token: "cli-token", expiresAt: Date().addingTimeInterval(3_600))
        var stubs = Self.monthlyStubs()
        stubs["GetSubscriptionStats"] = KimiHTTPStub(status: 200, body: #"""
        {
          "ratelimitCode5h":{"ratio":0.1,"enabled":true},
          "subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.0036}
        }
        """#)
        stubs["usages"] = KimiHTTPStub(status: 200, body: #"""
        {
          "usage":{"limit":"1000","used":"250","reset_time":"2026-07-24T00:00:00Z"},
          "limits":[{"window":{"duration":300,"timeUnit":"MINUTE"},"detail":{"limit":100,"remaining":50}}]
        }
        """#)
        let transport = KimiMockTransport(stubs: stubs)

        let snapshot = try await KimiUsageService(credentials: fixture.store, transport: transport).fetchSnapshot(previous: nil)

        #expect(snapshot.source == .kimiCombined)
        #expect(snapshot.displayWindows.map(\.kind) == [.fiveHour, .codeSevenDay, .monthly])
        #expect(snapshot.displayWindows.first?.window.remainingPercent == 90)
        let requests = await transport.capturedRequests()
        #expect(requests.filter { $0.host == "www.kimi.com" }.allSatisfy { $0.hasCookie })
        #expect(requests.filter { $0.host == "api.kimi.com" }.allSatisfy { !$0.hasCookie && $0.hasAuthorization })
    }

    @Test func keepsSuccessfulMonthlyWindowWhenOtherEndpointsFail() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        var stubs = Self.monthlyStubs()
        stubs["GetUsages"] = KimiHTTPStub(status: 500, body: "{}")
        stubs["GetSubscription"] = KimiHTTPStub(status: 500, body: "{}")

        let snapshot = try await KimiUsageService(
            credentials: fixture.store,
            transport: KimiMockTransport(stubs: stubs)).fetchSnapshot(previous: nil)

        #expect(snapshot.displayWindows.map(\.kind) == [.monthly])
        #expect(snapshot.sourceError?.contains("HTTP 500") == true)
    }

    @Test func unauthorizedRefreshPreservesLastSuccessfulSnapshot() async throws {
        let fixture = try KimiFixture()
        try fixture.writeCookie(value: "desktop-token")
        let good = try await KimiUsageService(
            credentials: fixture.store,
            transport: KimiMockTransport(stubs: Self.monthlyStubs())).fetchSnapshot(previous: nil)
        let unauthorized = Dictionary(uniqueKeysWithValues: ["GetUsages", "GetSubscriptionStats", "GetSubscription"].map {
            ($0, KimiHTTPStub(status: 401, body: "{}"))
        })

        let preserved = try await KimiUsageService(
            credentials: fixture.store,
            transport: KimiMockTransport(stubs: unauthorized)).fetchSnapshot(previous: good)

        #expect(preserved.sourceUpdatedAt == good.sourceUpdatedAt)
        #expect(preserved.displayWindows.map(\.kind) == [.monthly])
        #expect(preserved.sourceError?.contains("sign in again") == true)
    }

    private static func monthlyStubs() -> [String: KimiHTTPStub] {
        [
            "GetUsages": KimiHTTPStub(status: 200, body: #"{"usages":[]}"#),
            "GetSubscriptionStats": KimiHTTPStub(status: 200, body: #"""
            {
              "subscriptionBalance":{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.0036,"expireTime":"2026-08-17T04:45:55.725391Z"}
            }
            """#),
            "GetSubscription": KimiHTTPStub(status: 200, body: #"""
            {
              "subscription":{"goods":{"title":"Adagio","membershipLevel":"LEVEL_FREE"}},
              "balances":[{"feature":"FEATURE_OMNI","type":"SUBSCRIPTION","amountUsedRatio":0.0036,"expireTime":"2026-08-17T04:45:55.725391Z"}]
            }
            """#),
        ]
    }
}

private final class KimiFixture {
    let directory: URL
    let cookieURL: URL
    let cliURL: URL
    let deviceURL: URL

    var store: KimiCredentialStore {
        KimiCredentialStore(cookieDatabaseURL: cookieURL, cliCredentialURL: cliURL, cliDeviceIDURL: deviceURL)
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsageHUD-Kimi-\(UUID().uuidString)")
        cookieURL = directory.appendingPathComponent("Cookies")
        cliURL = directory.appendingPathComponent(".kimi-code/credentials/kimi-code.json")
        deviceURL = directory.appendingPathComponent(".kimi-code/device_id")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open(cookieURL.path, &database) == SQLITE_OK, let database else {
            throw KimiUsageError.invalidDesktopSession
        }
        defer { sqlite3_close(database) }
        let sql = "CREATE TABLE cookies (host_key TEXT, name TEXT, value TEXT, encrypted_value BLOB, expires_utc INTEGER)"
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw KimiUsageError.invalidDesktopSession
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    func writeCookie(value: String, encrypted: Data = Data()) throws {
        var database: OpaquePointer?
        guard sqlite3_open(cookieURL.path, &database) == SQLITE_OK, let database else { throw KimiUsageError.invalidDesktopSession }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = "INSERT INTO cookies VALUES ('www.kimi.com', 'kimi-auth', ?, ?, ?)"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw KimiUsageError.invalidDesktopSession
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        _ = encrypted.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 2, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        let chromiumExpiry = Int64((Date().addingTimeInterval(86_400).timeIntervalSince1970 + 11_644_473_600) * 1_000_000)
        sqlite3_bind_int64(statement, 3, chromiumExpiry)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw KimiUsageError.invalidDesktopSession }
    }

    func writeCLI(token: String, expiresAt: Date) throws {
        try FileManager.default.createDirectory(at: cliURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let object: [String: Any] = [
            "access_token": token,
            "refresh_token": "unused-refresh-token",
            "expires_at": expiresAt.timeIntervalSince1970,
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: cliURL)
        try Data("existing-device-id".utf8).write(to: deviceURL)
    }
}
