import AppKit

@MainActor
final class ApplicationPowerCoordinator {
    enum SuspensionReason: Hashable {
        case systemSleep
        case screenSleep
        case sessionInactive
    }

    private var observers: [NSObjectProtocol] = []
    private var reasons = Set<SuspensionReason>()
    private var onSuspend: (@MainActor () -> Void)?
    private var onResume: (@MainActor () -> Void)?

    var permitsActiveWork: Bool {
        reasons.isEmpty
    }

    func start(
        onSuspend: @escaping @MainActor () -> Void,
        onResume: @escaping @MainActor () -> Void
    ) {
        stop()
        self.onSuspend = onSuspend
        self.onResume = onResume
        let center = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.willSleepNotification, reason: .systemSleep, suspended: true, center: center)
        observe(NSWorkspace.didWakeNotification, reason: .systemSleep, suspended: false, center: center)
        observe(NSWorkspace.screensDidSleepNotification, reason: .screenSleep, suspended: true, center: center)
        observe(NSWorkspace.screensDidWakeNotification, reason: .screenSleep, suspended: false, center: center)
        observe(NSWorkspace.sessionDidResignActiveNotification, reason: .sessionInactive, suspended: true, center: center)
        observe(NSWorkspace.sessionDidBecomeActiveNotification, reason: .sessionInactive, suspended: false, center: center)
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        reasons.removeAll()
        onSuspend = nil
        onResume = nil
    }

    private func observe(
        _ name: Notification.Name,
        reason: SuspensionReason,
        suspended: Bool,
        center: NotificationCenter
    ) {
        observers.append(center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.update(reason: reason, suspended: suspended)
            }
        })
    }

    private func update(reason: SuspensionReason, suspended: Bool) {
        let wasPermitted = permitsActiveWork
        if suspended {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        let isPermitted = permitsActiveWork
        guard wasPermitted != isPermitted else { return }
        if isPermitted {
            onResume?()
        } else {
            onSuspend?()
        }
    }
}
