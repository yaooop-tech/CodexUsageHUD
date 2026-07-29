import Foundation

enum OAuthUsageError: LocalizedError {
    case credentialsUnavailable(String)
    case invalidCredentials(String)
    case unauthorized(String)
    case rateLimited(Date?)
    case invalidResponse(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .credentialsUnavailable(let message), .invalidCredentials(let message), .invalidResponse(let message):
            return message
        case .unauthorized(let service):
            return "\(service) authorization expired. Sign in again."
        case .rateLimited(let until):
            if let until {
                return "OAuth usage is rate limited until \(until.formatted(date: .omitted, time: .shortened))."
            }
            return "OAuth usage is temporarily rate limited."
        case .http(let status):
            return "OAuth usage request failed with HTTP \(status)."
        }
    }
}

enum OAuthJSON {
    static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthUsageError.invalidResponse("Usage response was not a JSON object.")
        }
        return value
    }

    static func dictionary(_ value: Any?, keys: [String]) -> [String: Any]? {
        guard let object = value as? [String: Any] else { return nil }
        for key in keys {
            if let nested = object[key] as? [String: Any] { return nested }
        }
        return nil
    }

    static func value(_ object: [String: Any], keys: [String]) -> Any? {
        for key in keys where object[key] != nil { return object[key] }
        return nil
    }

    static func string(_ object: [String: Any], keys: [String]) -> String? {
        value(object, keys: keys) as? String
    }

    static func double(_ object: [String: Any], keys: [String]) -> Double? {
        if let number = value(object, keys: keys) as? NSNumber { return number.doubleValue }
        if let string = value(object, keys: keys) as? String { return Double(string) }
        return nil
    }

    static func bool(_ object: [String: Any], keys: [String]) -> Bool? {
        (value(object, keys: keys) as? NSNumber)?.boolValue
    }

    static func epoch(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String {
            if let number = Double(string) { return Int64(number) }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: string) { return Int64(date.timeIntervalSince1970) }
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: string).map { Int64($0.timeIntervalSince1970) }
        }
        return nil
    }

    static func retryDate(response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(raw) { return now.addingTimeInterval(seconds) }
        return HTTPDateFormatter.shared.date(from: raw)
    }
}

private final class HTTPDateFormatter: @unchecked Sendable {
    static let shared = HTTPDateFormatter()
    private let formatter: DateFormatter
    private let lock = NSLock()

    private init() {
        formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
    }

    func date(from value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: value)
    }
}
