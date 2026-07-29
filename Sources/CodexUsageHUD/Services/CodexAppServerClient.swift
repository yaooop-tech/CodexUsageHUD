import Foundation
import OSLog

enum CodexClientError: LocalizedError {
    case codexExecutableNotFound
    case processNotRunning
    case invalidResponse
    case serverError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            return "Codex executable was not found."
        case .processNotRunning:
            return "Codex app-server is not running."
        case .invalidResponse:
            return "Codex app-server returned an unreadable response."
        case .serverError(let message):
            return message
        case .timeout:
            return "Codex app-server did not respond in time."
        }
    }
}

final class CodexAppServerClient: @unchecked Sendable {
    static let shared = CodexAppServerClient()

    private let queue = DispatchQueue(label: "CodexUsageHUD.CodexAppServerClient")
    private let logger = Logger(subsystem: AppMetadata.bundleIdentifier, category: "app-server")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputBuffer = Data()
    private var nextId = 1
    private var initialized = false
    private var pending: [Int: PendingRequest] = [:]

    private init() {}

    /// Starts and initializes the shared app-server before callers fan out
    /// independent requests. This avoids multiple cold-start requests racing to
    /// send `initialize` on the same stdio connection.
    func prepare() async throws {
        try await ensureInitialized(unless: false)
    }

    func request<T: Decodable>(_ method: String, params: Any? = nil, as type: T.Type = T.self) async throws -> T {
        try await ensureInitialized(unless: method == "initialize")
        let data = try await send(method: method, params: params)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func stop() {
        queue.sync {
            inputHandle?.closeFile()
            inputHandle = nil
            process?.terminate()
            process = nil
            initialized = false
            failAll(CodexClientError.processNotRunning)
        }
    }

    private func ensureInitialized(unless skip: Bool) async throws {
        try startIfNeeded()
        guard !skip else {
            return
        }

        let shouldInitialize = queue.sync { !initialized }
        guard shouldInitialize else {
            return
        }

        struct InitializeResponse: Decodable {
            let userAgent: String
            let codexHome: String
            let platformFamily: String
            let platformOs: String
        }

        let params: [String: Any] = [
            "clientInfo": [
                "name": "codex-usage-hud",
                "title": "Codex Usage HUD",
                "version": AppMetadata.version
            ],
            "capabilities": [
                "experimentalApi": true,
                "requestAttestation": false,
                "optOutNotificationMethods": []
            ]
        ]

        let _: Data = try await send(method: "initialize", params: params)
        queue.sync {
            initialized = true
        }
        _ = InitializeResponse.self
    }

    private func startIfNeeded() throws {
        try queue.sync {
            if let process, process.isRunning {
                return
            }

            guard let executable = findCodexExecutable() else {
                logger.error("Codex executable was not found")
                throw CodexClientError.codexExecutableNotFound
            }

            logger.info("Starting Codex app-server at \(executable.path, privacy: .public)")

            let process = Process()
            process.executableURL = executable
            process.arguments = ["-s", "read-only", "-a", "untrusted", "app-server", "--listen", "stdio://"]

            let input = Pipe()
            let output = Pipe()
            let error = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = error

            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                guard let client = self else {
                    return
                }
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                client.queue.async { [client] in
                    client.handleOutput(data)
                }
            }

            error.fileHandleForReading.readabilityHandler = { handle in
                _ = handle.availableData
            }

            process.terminationHandler = { [weak self] _ in
                guard let client = self else {
                    return
                }
                client.queue.async { [client] in
                    client.logger.error("Codex app-server process terminated")
                    client.initialized = false
                    client.failAll(CodexClientError.processNotRunning)
                }
            }

            try process.run()
            logger.info("Codex app-server started")
            self.process = process
            self.inputHandle = input.fileHandleForWriting
        }
    }

    private func send(method: String, params: Any?) async throws -> Data {
        try startIfNeeded()

        let id = queue.sync { () -> Int in
            let id = nextId
            nextId += 1
            return id
        }

        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        let requestData: Data = try { () throws -> Data in
            var data = try JSONSerialization.data(withJSONObject: payload, options: [])
            data.append(0x0A)
            return data
        }()

        let timeout: TimeInterval = method == "initialize" ? 8 : 3
        return try await withCheckedThrowingContinuation { continuation in
            let request = PendingRequest(continuation)

            queue.async {
                guard let inputHandle = self.inputHandle else {
                    request.complete(.failure(CodexClientError.processNotRunning))
                    return
                }

                self.pending[id] = request
                inputHandle.write(requestData)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self, request] in
                guard let client = self else {
                    return
                }
                client.queue.async { [client, request] in
                    guard let storedRequest = client.pending.removeValue(forKey: id), storedRequest === request else {
                        return
                    }
                    request.complete(.failure(CodexClientError.timeout))
                    client.terminateAfterFailure(CodexClientError.timeout)
                }
            }
        }
    }

    private func terminateAfterFailure(_ error: Error) {
        inputHandle?.closeFile()
        inputHandle = nil
        process?.terminate()
        process = nil
        initialized = false
        outputBuffer.removeAll(keepingCapacity: true)
        failAll(error)
    }

    private func handleOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newlineRange = outputBuffer.firstRange(of: Data([0x0A])) {
            let lineData = outputBuffer.subdata(in: outputBuffer.startIndex..<newlineRange.lowerBound)
            outputBuffer.removeSubrange(outputBuffer.startIndex...newlineRange.lowerBound)
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? Int else {
            return
        }

        let request = pending.removeValue(forKey: id)
        guard let request else {
            return
        }

        if let error = object["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Codex app-server returned an error."
            request.complete(.failure(CodexClientError.serverError(message)))
            return
        }

        guard let result = object["result"],
              JSONSerialization.isValidJSONObject(result),
              let resultData = try? JSONSerialization.data(withJSONObject: result, options: []) else {
            request.complete(.failure(CodexClientError.invalidResponse))
            return
        }

        request.complete(.success(resultData))
    }

    private func failAll(_ error: Error) {
        let requests = Array(pending.values)
        pending.removeAll()
        for request in requests {
            request.complete(.failure(error))
        }
    }

    private func findCodexExecutable() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ]

        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private final class PendingRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, Error>?
        private var completed = false

        init(_ continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func complete(_ result: Result<Data, Error>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            let continuation = continuation
            self.continuation = nil
            lock.unlock()

            continuation?.resume(with: result)
        }
    }
}
