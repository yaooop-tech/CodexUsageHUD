import Darwin
import Foundation

@MainActor
final class AgentActivityMonitor {
    typealias Handler = @MainActor ([UsageProvider: [AgentTaskActivity]]) -> Void

    private let startedAt: Date
    private var handler: Handler?
    private var sources: [DispatchSourceFileSystemObject] = []
    private var descriptors: [Int32] = []
    private var debounceTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?
    private var reloadTask: Task<Void, Never>?
    private(set) var isRunning = false

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func start(handler: @escaping Handler) {
        self.handler = handler
        guard !isRunning else { return }
        isRunning = true
        scheduleReload(delay: .zero)
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                self?.scheduleReload(delay: .zero)
            }
        }
    }

    func stop() {
        isRunning = false
        debounceTask?.cancel()
        debounceTask = nil
        fallbackTask?.cancel()
        fallbackTask = nil
        reloadTask?.cancel()
        reloadTask = nil
        removeSources()
    }

    private func scheduleReload(delay: Duration = .milliseconds(650)) {
        guard isRunning else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            self?.reload()
        }
    }

    private func reload() {
        guard isRunning, reloadTask == nil else { return }
        let startedAt = startedAt
        reloadTask = Task { [weak self] in
            let readings = await Task.detached(priority: .utility) {
                AgentActivityReader.readAll(startedAt: startedAt)
            }.value
            guard let self, self.isRunning, !Task.isCancelled else { return }
            self.handler?(readings)
            self.configureSources()
            self.reloadTask = nil
        }
    }

    private func configureSources() {
        let urls = AgentActivityReader.monitoredURLs()
        let expectedPaths = Set(urls.map(\.standardizedFileURL.path))
        let currentPaths: Set<String> = Set(descriptors.compactMap { descriptor -> String? in
            guard let path = fcntlPath(descriptor) else { return nil }
            return URL(fileURLWithPath: path).standardizedFileURL.path
        })
        guard expectedPaths != currentPaths else { return }

        removeSources()
        for url in urls {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .attrib, .rename, .delete],
                queue: .main)
            source.setEventHandler { [weak self] in
                self?.scheduleReload()
            }
            source.setCancelHandler {
                close(descriptor)
            }
            descriptors.append(descriptor)
            sources.append(source)
            source.resume()
        }
    }

    private func removeSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll(keepingCapacity: true)
        descriptors.removeAll(keepingCapacity: true)
    }

    private func fcntlPath(_ descriptor: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}
