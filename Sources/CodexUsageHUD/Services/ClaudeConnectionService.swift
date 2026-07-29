import Foundation

enum ClaudeConnectionState: Equatable {
    case idle
    case connecting
    case connected
    case cliMissing
    case failed(String)
}

enum ClaudeConnectionError: LocalizedError {
    case cliMissing
    case alreadyConnecting
    case timedOut
    case failed

    var errorDescription: String? {
        switch self {
        case .cliMissing: return "Claude CLI is not installed."
        case .alreadyConnecting: return "Claude authorization is already in progress."
        case .timedOut: return "Claude authorization timed out."
        case .failed: return "Claude authorization was not completed."
        }
    }
}

final class ClaudeConnectionService: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var timeoutTask: Task<Void, Never>?

    func connect(completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        guard let executable = Self.executable() else {
            throw ClaudeConnectionError.cliMissing
        }

        lock.lock()
        guard process == nil else {
            lock.unlock()
            throw ClaudeConnectionError.alreadyConnecting
        }

        let process = Process()
        let output = Pipe()
        let input = Pipe()
        process.executableURL = executable
        process.arguments = ["auth", "login"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        process.terminationHandler = { [weak self] process in
            output.fileHandleForReading.readabilityHandler = nil
            let result: Result<Void, Error> = process.terminationStatus == 0
                ? .success(())
                : .failure(ClaudeConnectionError.failed)
            self?.finish(process: process, result: result, completion: completion)
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            if self.process === process { self.process = nil }
            lock.unlock()
            throw error
        }

        let task = Task { [weak self, weak process] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled, let self, let process else { return }
            self.finish(process: process, result: .failure(ClaudeConnectionError.timedOut), completion: completion)
        }
        lock.lock()
        if self.process === process {
            timeoutTask = task
        } else {
            task.cancel()
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let process = process
        self.process = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func finish(process: Process, result: Result<Void, Error>, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        lock.lock()
        guard self.process === process else {
            lock.unlock()
            return
        }
        self.process = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        lock.unlock()
        if process.isRunning { process.terminate() }
        completion(result)
    }

    static func executable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }
}
