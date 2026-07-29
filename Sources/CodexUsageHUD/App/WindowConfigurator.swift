import AppKit
import QuartzCore
import SwiftUI

struct FloatingWindowConfigurator: NSViewRepresentable {
    let desiredSize: CGSize
    let contentInsets: NSEdgeInsets
    let isCollapsed: Bool
    let cornerRadius: CGFloat
    let theme: AppTheme
    let systemColorScheme: ColorScheme
    let reducesMotion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.configure(window, desiredSize: desiredSize, contentInsets: contentInsets, isCollapsed: isCollapsed, cornerRadius: cornerRadius, theme: theme, systemColorScheme: systemColorScheme, reducesMotion: reducesMotion)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.configure(window, desiredSize: desiredSize, contentInsets: contentInsets, isCollapsed: isCollapsed, cornerRadius: cornerRadius, theme: theme, systemColorScheme: systemColorScheme, reducesMotion: reducesMotion)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private var configuredWindow: NSWindow?
        private var lastSize: CGSize = .zero
        private var lastCollapsed = false
        private var pendingSnapTask: Task<Void, Never>?
        private var isSnapping = false
        private var contentInsets = NSEdgeInsets()
        private var reducesMotion = false

        func configure(_ window: NSWindow, desiredSize: CGSize, contentInsets: NSEdgeInsets, isCollapsed: Bool, cornerRadius: CGFloat, theme: AppTheme, systemColorScheme: ColorScheme, reducesMotion: Bool) {
            self.contentInsets = contentInsets
            self.reducesMotion = reducesMotion
            if configuredWindow !== window {
                configuredWindow = window
                window.delegate = self
                window.title = "Codex Usage HUD"
                window.level = .floating
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false
                window.animationBehavior = .utilityWindow
                window.isMovableByWindowBackground = true
                window.acceptsMouseMovedEvents = true
                window.styleMask = [.borderless]
                window.contentView?.wantsLayer = true
                configureRoundedContentLayer(window, cornerRadius: cornerRadius)
                window.standardWindowButton(.closeButton)?.isHidden = true
                window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                window.standardWindowButton(.zoomButton)?.isHidden = true
                restorePlacement(for: window, desiredSize: desiredSize, isCollapsed: isCollapsed)
                lastSize = desiredSize
                lastCollapsed = isCollapsed
            }

            configureRoundedContentLayer(window, cornerRadius: cornerRadius)
            applyAppearance(to: window, theme: theme, systemColorScheme: systemColorScheme)
            if !isCollapsed {
                pendingSnapTask?.cancel()
                pendingSnapTask = nil
            }
            resize(window, to: desiredSize, isCollapsed: isCollapsed, reducesMotion: reducesMotion)
        }

        func windowDidMove(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else {
                return
            }
            if lastCollapsed {
                scheduleSnap(for: window)
            } else {
                saveExpandedPlacement(window)
            }
        }

        func windowDidResize(_ notification: Notification) {
            guard let window = notification.object as? NSWindow, !lastCollapsed else {
                return
            }
            saveExpandedPlacement(window)
        }

        private func restorePlacement(for window: NSWindow, desiredSize: CGSize, isCollapsed: Bool) {
            let defaults = UserDefaults.standard
            let savedX = defaults.double(forKey: DefaultsKey.windowX)
            let savedY = defaults.double(forKey: DefaultsKey.windowY)

            if isCollapsed {
                window.setFrame(railFrame(size: desiredSize, for: window), display: true)
                return
            }

            if savedX != 0 || savedY != 0 {
                let frame = clampedFrame(NSRect(origin: CGPoint(x: savedX, y: savedY), size: desiredSize), for: window)
                window.setFrame(frame, display: true)
                return
            }

            if let screen = NSScreen.main {
                let visible = screen.visibleFrame
                let origin = CGPoint(
                    x: visible.maxX - desiredSize.width + contentInsets.right - 24,
                    y: visible.maxY - desiredSize.height - 24
                )
                window.setFrame(NSRect(origin: origin, size: desiredSize), display: true)
            }
        }

        private func resize(_ window: NSWindow, to desiredSize: CGSize, isCollapsed: Bool, reducesMotion: Bool) {
            guard abs(lastSize.width - desiredSize.width) > 0.5 || abs(lastSize.height - desiredSize.height) > 0.5 || lastCollapsed != isCollapsed else {
                return
            }
            lastSize = desiredSize
            lastCollapsed = isCollapsed

            let frame = targetFrame(for: window, desiredSize: desiredSize, isCollapsed: isCollapsed)

            let duration = HUDWindowMotion.duration(
                isCollapsed: isCollapsed,
                reducesMotion: reducesMotion)
            guard duration > 0 else {
                isSnapping = false
                window.setFrame(frame, display: true)
                if isCollapsed {
                    saveRailPlacement(frame: frame, edge: storedEdge())
                }
                return
            }

            isSnapping = true
            let transitionStartFrame = HUDWindowPlacement.widthOnlyTransitionStart(
                currentFrame: window.frame,
                targetFrame: frame,
                edge: storedEdge())
            window.setFrame(transitionStartFrame, display: true)

            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.isSnapping = false
                    if isCollapsed {
                        self?.saveRailPlacement(frame: frame, edge: self?.storedEdge() ?? .right)
                    }
                }
            }
        }

        private func saveExpandedPlacement(_ window: NSWindow) {
            UserDefaults.standard.set(window.frame.origin.x, forKey: DefaultsKey.windowX)
            UserDefaults.standard.set(window.frame.origin.y, forKey: DefaultsKey.windowY)
        }

        private func clampedFrame(_ frame: NSRect, for window: NSWindow) -> NSRect {
            guard let screen = window.screen ?? NSScreen.main else {
                return frame
            }

            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            var clamped = frame
            clamped.origin.x = min(max(clamped.origin.x, visible.minX), visible.maxX - clamped.width)
            clamped.origin.y = min(max(clamped.origin.y, visible.minY), visible.maxY - clamped.height)
            return clamped
        }

        private func targetFrame(for window: NSWindow, desiredSize: CGSize, isCollapsed: Bool) -> NSRect {
            if isCollapsed {
                let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 0, dy: 8)
                let edge = visible.map { nearestEdge(for: window, visible: $0) } ?? storedEdge()
                let savedRailMidY = UserDefaults.standard.double(forKey: DefaultsKey.railMidY)
                let preservedMidY = visible.map {
                    HUDWindowPlacement.collapsedRailMidY(
                        savedRailMidY: savedRailMidY,
                        currentWindowMidY: window.frame.midY,
                        visibleFrame: $0,
                        railHeight: desiredSize.height)
                } ?? window.frame.midY
                let frame = railFrame(
                    size: desiredSize,
                    for: window,
                    edge: edge,
                    midY: preservedMidY)
                saveRailPlacement(frame: frame, edge: edge)
                return frame
            }

            guard let screen = window.screen ?? NSScreen.main else {
                return NSRect(origin: window.frame.origin, size: desiredSize)
            }

            let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            let edge = storedEdge()
            let midY = currentRailMidY(preferred: window.frame.midY, visible: visible, railHeight: window.frame.height)
            let x = HUDWindowPlacement.anchoredX(
                edge: edge,
                width: desiredSize.width,
                visibleFrame: visible,
                contentInsets: contentInsets)
            let y = clampedY(midY - desiredSize.height / 2, height: desiredSize.height, visible: visible)
            return NSRect(x: x, y: y, width: desiredSize.width, height: desiredSize.height)
        }

        private func railFrame(size: CGSize, for window: NSWindow, edge: HUDSnapEdge? = nil, midY: CGFloat? = nil) -> NSRect {
            guard let screen = window.screen ?? NSScreen.main else {
                return NSRect(origin: window.frame.origin, size: size)
            }

            let visible = screen.visibleFrame.insetBy(dx: 0, dy: 8)
            let resolvedEdge = edge ?? storedEdge()
            let resolvedMidY = currentRailMidY(preferred: midY, visible: visible, railHeight: size.height)
            let x = HUDWindowPlacement.anchoredX(
                edge: resolvedEdge,
                width: size.width,
                visibleFrame: visible,
                contentInsets: contentInsets)
            let y = clampedY(resolvedMidY - size.height / 2, height: size.height, visible: visible)
            return NSRect(x: x, y: y, width: size.width, height: size.height)
        }

        private func scheduleSnap(for window: NSWindow) {
            guard !isSnapping else {
                return
            }
            pendingSnapTask?.cancel()
            pendingSnapTask = Task { @MainActor [weak self, weak window] in
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard let self, let window, self.lastCollapsed else {
                    return
                }
                if NSEvent.pressedMouseButtons != 0 {
                    self.scheduleSnap(for: window)
                    return
                }
                self.snapToNearestEdge(window)
            }
        }

        private func snapToNearestEdge(_ window: NSWindow) {
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 0, dy: 8)
            let edge = visible.map { nearestEdge(for: window, visible: $0) } ?? storedEdge()
            let frame = railFrame(size: window.frame.size, for: window, edge: edge, midY: window.frame.midY)
            saveRailPlacement(frame: frame, edge: edge)

            let duration = HUDWindowMotion.snapDuration(reducesMotion: reducesMotion)
            guard duration > 0 else {
                isSnapping = false
                window.setFrame(frame, display: true)
                return
            }

            isSnapping = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.isSnapping = false
                }
            }
        }

        private func storedEdge() -> HUDSnapEdge {
            let rawValue = UserDefaults.standard.string(forKey: DefaultsKey.snapEdge)
            return HUDSnapEdge(rawValue: rawValue ?? "") ?? .right
        }

        private func nearestEdge(for window: NSWindow, visible: NSRect) -> HUDSnapEdge {
            window.frame.midX < visible.midX ? .left : .right
        }

        private func currentRailMidY(preferred: CGFloat?, visible: NSRect, railHeight: CGFloat) -> CGFloat {
            let saved = UserDefaults.standard.double(forKey: DefaultsKey.railMidY)
            let savedMidY = saved > 0 ? CGFloat(saved) : nil
            let midY = preferred ?? savedMidY ?? visible.midY
            return min(max(midY, visible.minY + railHeight / 2), visible.maxY - railHeight / 2)
        }

        private func clampedY(_ y: CGFloat, height: CGFloat, visible: NSRect) -> CGFloat {
            min(max(y, visible.minY), visible.maxY - height)
        }

        private func saveRailPlacement(frame: NSRect, edge: HUDSnapEdge) {
            UserDefaults.standard.set(edge.rawValue, forKey: DefaultsKey.snapEdge)
            UserDefaults.standard.set(frame.midY, forKey: DefaultsKey.railMidY)
        }

        private func configureRoundedContentLayer(_ window: NSWindow, cornerRadius: CGFloat) {
            guard let contentView = window.contentView else {
                return
            }

            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.clear.cgColor
            contentView.layer?.cornerRadius = cornerRadius
            contentView.layer?.cornerCurve = .continuous
            contentView.layer?.masksToBounds = true
            contentView.superview?.wantsLayer = true
            contentView.superview?.layer?.backgroundColor = NSColor.clear.cgColor
        }

        private func applyAppearance(to window: NSWindow, theme: AppTheme, systemColorScheme: ColorScheme) {
            let colorScheme = theme.resolvedColorScheme(system: systemColorScheme)
            let appearanceName: NSAppearance.Name = colorScheme == .dark ? .darkAqua : .aqua
            guard window.appearance?.name != appearanceName else {
                return
            }
            window.appearance = NSAppearance(named: appearanceName)
        }
    }
}

enum HUDSnapEdge: String {
    case left
    case right
}

enum HUDWindowMotion {
    static let transitionDuration: TimeInterval = 0.24

    static func duration(isCollapsed _: Bool, reducesMotion: Bool) -> TimeInterval {
        reducesMotion ? 0 : transitionDuration
    }

    static func snapDuration(reducesMotion: Bool) -> TimeInterval {
        reducesMotion ? 0 : 0.16
    }
}

enum HUDWindowPlacement {
    static func widthOnlyTransitionStart(
        currentFrame: NSRect,
        targetFrame: NSRect,
        edge: HUDSnapEdge
    ) -> NSRect {
        let x: CGFloat
        switch edge {
        case .left:
            x = targetFrame.minX
        case .right:
            x = targetFrame.maxX - currentFrame.width
        }
        return NSRect(
            x: x,
            y: targetFrame.minY,
            width: currentFrame.width,
            height: targetFrame.height)
    }

    static func anchoredX(
        edge: HUDSnapEdge,
        width: CGFloat,
        visibleFrame: NSRect,
        contentInsets: NSEdgeInsets
    ) -> CGFloat {
        switch edge {
        case .left:
            return visibleFrame.minX - contentInsets.left
        case .right:
            return visibleFrame.maxX - width + contentInsets.right
        }
    }

    static func collapsedRailMidY(
        savedRailMidY: Double,
        currentWindowMidY: CGFloat,
        visibleFrame: NSRect,
        railHeight: CGFloat
    ) -> CGFloat {
        let preferred = savedRailMidY > 0 ? CGFloat(savedRailMidY) : currentWindowMidY
        return min(
            max(preferred, visibleFrame.minY + railHeight / 2),
            visibleFrame.maxY - railHeight / 2)
    }
}

enum DefaultsKey {
    static let collapsed = "hud.collapsed"
    static let windowX = "hud.window.x"
    static let windowY = "hud.window.y"
    static let refreshSeconds = "refresh.seconds"
    static let expandedRefreshSeconds = "refresh.expanded.seconds"
    static let collapsedRefreshSeconds = "refresh.collapsed.seconds"
    static let launchAtLogin = "launch.at.login"
    static let theme = "appearance.theme"
    static let language = "appearance.language"
    static let snapEdge = "hud.snap.edge"
    static let railMidY = "hud.rail.midY"
    static let displaySource = "usage.display.source"
    static let selectedProvider = "usage.selected.provider"
    static let claudeMonitoringEnabled = "claude.monitoring.enabled"
    static let claudeOAuthEnabled = "claude.oauth.enabled"
}
