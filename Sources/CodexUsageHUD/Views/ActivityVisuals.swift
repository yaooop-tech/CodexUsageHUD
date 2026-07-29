import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import SwiftUI

enum ActivityVisualTheme: String, Sendable, Hashable {
    case completion
    case thinking
    case attention
    case error

    init?(state: AgentActivityState) {
        switch state {
        case .idle:
            return nil
        case .unread:
            self = .completion
        case .thinking:
            self = .thinking
        case .attention:
            self = .attention
        case .error:
            self = .error
        }
    }

    var colors: [Color] {
        rgbaColors.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
    }

    fileprivate var rgbaColors: [StarlightRGBA] {
        switch self {
        case .completion:
            return [
                StarlightRGBA(0.02, 0.88, 0.35),
                StarlightRGBA(0.12, 0.96, 0.69),
                StarlightRGBA(0.00, 0.67, 0.63),
                StarlightRGBA(0.45, 1.00, 0.78),
            ]
        case .thinking:
            return [
                StarlightRGBA(0.02, 0.39, 1.00),
                StarlightRGBA(0.00, 0.78, 0.96),
                StarlightRGBA(0.31, 0.20, 0.96),
                StarlightRGBA(0.39, 0.71, 1.00),
            ]
        case .attention:
            return [
                StarlightRGBA(1.00, 0.53, 0.00),
                StarlightRGBA(1.00, 0.76, 0.08),
                StarlightRGBA(1.00, 0.31, 0.02),
                StarlightRGBA(1.00, 0.88, 0.42),
            ]
        case .error:
            return [
                StarlightRGBA(1.00, 0.05, 0.10),
                StarlightRGBA(1.00, 0.20, 0.45),
                StarlightRGBA(0.73, 0.04, 0.43),
                StarlightRGBA(1.00, 0.38, 0.22),
            ]
        }
    }
}

enum CollapsedHUDMode: Sendable, Equatable {
    case idle
    case active(ActivityVisualTheme)

    init(activityState: AgentActivityState) {
        if let theme = ActivityVisualTheme(state: activityState) {
            self = .active(theme)
        } else {
            self = .idle
        }
    }

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    var theme: ActivityVisualTheme? {
        if case let .active(theme) = self { return theme }
        return nil
    }
}

struct StarlightMotionProfile: Equatable {
    let speed: Double
    let horizontalDrift: CGFloat
    let verticalDrift: CGFloat
    let scaleDepth: CGFloat
    let rotation: CGFloat
    let opacityDepth: Float
    let pulseCadence: Double?

    static func profile(for theme: ActivityVisualTheme) -> StarlightMotionProfile {
        switch theme {
        case .thinking:
            return StarlightMotionProfile(
                speed: 1.16,
                horizontalDrift: 0.105,
                verticalDrift: 0.075,
                scaleDepth: 0.13,
                rotation: 0.040,
                opacityDepth: 0.28,
                pulseCadence: nil)
        case .attention:
            return StarlightMotionProfile(
                speed: 0.94,
                horizontalDrift: 0.052,
                verticalDrift: 0.055,
                scaleDepth: 0.18,
                rotation: 0.018,
                opacityDepth: 0.38,
                pulseCadence: 2.15)
        case .error:
            return StarlightMotionProfile(
                speed: 1.48,
                horizontalDrift: 0.074,
                verticalDrift: 0.042,
                scaleDepth: 0.09,
                rotation: 0.052,
                opacityDepth: 0.38,
                pulseCadence: nil)
        case .completion:
            return StarlightMotionProfile(
                speed: 0.62,
                horizontalDrift: 0.058,
                verticalDrift: 0.068,
                scaleDepth: 0.20,
                rotation: 0.024,
                opacityDepth: 0.24,
                pulseCadence: nil)
        }
    }
}

struct StarlightTextureKey: Hashable, Sendable {
    let theme: ActivityVisualTheme
    let usesLightSurface: Bool
    let pointWidth: Int
    let pointHeight: Int
    let scaleMilli: Int

    init(
        theme: ActivityVisualTheme,
        usesLightSurface: Bool,
        size: CGSize,
        scale: CGFloat
    ) {
        self.theme = theme
        self.usesLightSurface = usesLightSurface
        pointWidth = max(1, Int(size.width.rounded()))
        pointHeight = max(1, Int(size.height.rounded()))
        scaleMilli = max(1_000, Int((scale * 1_000).rounded()))
    }

    var scale: CGFloat {
        CGFloat(scaleMilli) / 1_000
    }

    var renderSize: CGSize {
        CGSize(width: CGFloat(pointWidth) * 1.42, height: CGFloat(pointHeight) * 1.20)
    }

    fileprivate var cacheIdentifier: NSString {
        "\(theme.rawValue)-\(usesLightSurface)-\(pointWidth)x\(pointHeight)-\(scaleMilli)" as NSString
    }
}

final class StarlightTextureSet: NSObject, @unchecked Sendable {
    let images: [CGImage]

    init(images: [CGImage]) {
        self.images = images
    }
}

final class StarlightTextureCache: @unchecked Sendable {
    static let shared = StarlightTextureCache()
    private let cache = NSCache<NSString, StarlightTextureSet>()
    private let directory: URL

    private init() {
        cache.countLimit = 24
        directory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
            .appendingPathComponent("CodexUsageHUD", isDirectory: true)
            .appendingPathComponent("StarlightTextures-v1", isDirectory: true)
    }

    func value(for key: StarlightTextureKey) -> StarlightTextureSet? {
        cache.object(forKey: key.cacheIdentifier)
    }

    func insert(_ value: StarlightTextureSet, for key: StarlightTextureKey) {
        cache.setObject(value, forKey: key.cacheIdentifier)
    }

    func loadOrRender(for key: StarlightTextureKey) -> StarlightTextureSet? {
        if let cached = value(for: key) {
            return cached
        }
        if let stored = loadFromDisk(for: key) {
            insert(stored, for: key)
            return stored
        }
        guard let rendered = StarlightTextureRenderer.render(key: key) else {
            return nil
        }
        insert(rendered, for: key)
        persist(rendered, for: key)
        return rendered
    }

    private func loadFromDisk(for key: StarlightTextureKey) -> StarlightTextureSet? {
        let images = (0 ..< 4).compactMap { index -> CGImage? in
            let url = imageURL(for: key, index: index)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard images.count == 4 else { return nil }
        return StarlightTextureSet(images: images)
    }

    private func persist(_ textures: StarlightTextureSet, for key: StarlightTextureKey) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        for (index, image) in textures.images.enumerated() {
            let url = imageURL(for: key, index: index)
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil)
            else { continue }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private func imageURL(for key: StarlightTextureKey, index: Int) -> URL {
        directory.appendingPathComponent(
            "\(key.cacheIdentifier)-\(index).png",
            isDirectory: false)
    }
}

struct StarlightFlowField: View {
    let theme: ActivityVisualTheme
    let usesLightSurface: Bool
    let isVisible: Bool
    let isLowPowerModeEnabled: Bool
    let reducesMotion: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    theme.colors[0].opacity(usesLightSurface ? 0.34 : 0.40),
                    theme.colors[2].opacity(usesLightSurface ? 0.18 : 0.23),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom)

            GeometryReader { proxy in
                StarlightFlowLayerRepresentable(
                    theme: theme,
                    usesLightSurface: usesLightSurface,
                    isVisible: isVisible,
                    isLowPowerModeEnabled: isLowPowerModeEnabled,
                    reducesMotion: reducesMotion)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

private struct StarlightFlowLayerRepresentable: NSViewRepresentable {
    let theme: ActivityVisualTheme
    let usesLightSurface: Bool
    let isVisible: Bool
    let isLowPowerModeEnabled: Bool
    let reducesMotion: Bool

    func makeNSView(context: Context) -> StarlightFlowLayerHost {
        let view = StarlightFlowLayerHost()
        view.configure(
            theme: theme,
            usesLightSurface: usesLightSurface,
            isVisible: isVisible,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            reducesMotion: reducesMotion)
        return view
    }

    func updateNSView(_ nsView: StarlightFlowLayerHost, context: Context) {
        nsView.configure(
            theme: theme,
            usesLightSurface: usesLightSurface,
            isVisible: isVisible,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            reducesMotion: reducesMotion)
    }

    static func dismantleNSView(_ nsView: StarlightFlowLayerHost, coordinator: Void) {
        nsView.stop()
    }
}

@MainActor
final class StarlightFlowLayerHost: NSView {
    private struct Configuration: Equatable {
        let theme: ActivityVisualTheme
        let usesLightSurface: Bool
        let isVisible: Bool
        let isLowPowerModeEnabled: Bool
        let reducesMotion: Bool
    }

    private var configuration: Configuration?
    private var textureLayers: [CALayer] = []
    private var currentTextureKey: StarlightTextureKey?
    private var textureTask: Task<Void, Never>?
    private var lastLayoutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }

    func configure(
        theme: ActivityVisualTheme,
        usesLightSurface: Bool,
        isVisible: Bool,
        isLowPowerModeEnabled: Bool,
        reducesMotion: Bool
    ) {
        let next = Configuration(
            theme: theme,
            usesLightSurface: usesLightSurface,
            isVisible: isVisible,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            reducesMotion: reducesMotion)
        guard next != configuration else { return }
        let requiresNewTexture = configuration?.theme != next.theme
            || configuration?.usesLightSurface != next.usesLightSurface
        configuration = next
        if requiresNewTexture {
            currentTextureKey = nil
        }
        requestTexturesIfNeeded()
        updateAnimationState()
    }

    override func layout() {
        super.layout()
        guard bounds.size != .zero else { return }
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            currentTextureKey = nil
            requestTexturesIfNeeded()
        } else {
            layoutTextureLayers()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        currentTextureKey = nil
        requestTexturesIfNeeded()
        updateAnimationState()
    }

    func stop() {
        textureTask?.cancel()
        textureTask = nil
        textureLayers.forEach { $0.removeAllAnimations() }
    }

    private func requestTexturesIfNeeded() {
        guard let configuration, bounds.width > 1, bounds.height > 1 else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = StarlightTextureKey(
            theme: configuration.theme,
            usesLightSurface: configuration.usesLightSurface,
            size: bounds.size,
            scale: scale)
        guard key != currentTextureKey else { return }
        currentTextureKey = key
        textureTask?.cancel()

        if let cached = StarlightTextureCache.shared.value(for: key) {
            apply(cached, for: key)
            return
        }

        textureTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .utility) {
                StarlightTextureCache.shared.loadOrRender(for: key)
            }.value
            guard !Task.isCancelled, let rendered else { return }
            guard let self, self.currentTextureKey == key else { return }
            self.apply(rendered, for: key)
        }
    }

    private func apply(_ textures: StarlightTextureSet, for key: StarlightTextureKey) {
        textureLayers.forEach { $0.removeFromSuperlayer() }
        textureLayers = textures.images.enumerated().map { index, image in
            let textureLayer = CALayer()
            textureLayer.contents = image
            textureLayer.contentsScale = key.scale
            textureLayer.contentsGravity = .resize
            textureLayer.magnificationFilter = .linear
            textureLayer.minificationFilter = .linear
            textureLayer.opacity = modelOpacity(index: index)
            layer?.addSublayer(textureLayer)
            return textureLayer
        }
        installBottomFadeMask()
        layoutTextureLayers()

        let reveal = CABasicAnimation(keyPath: "opacity")
        reveal.fromValue = 0
        reveal.duration = 0.18
        reveal.timingFunction = CAMediaTimingFunction(name: .easeOut)
        textureLayers.forEach { $0.add(reveal, forKey: "starlight-reveal") }
        updateAnimationState()
    }

    private func installBottomFadeMask() {
        let fade = CAGradientLayer()
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.locations = [0, 0.64, 0.84, 1]
        fade.colors = [
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(0.52).cgColor,
            NSColor.clear.cgColor,
        ]
        fade.frame = bounds
        layer?.mask = fade
    }

    private func layoutTextureLayers() {
        guard let key = currentTextureKey, !textureLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.mask?.frame = bounds
        for (index, textureLayer) in textureLayers.enumerated() {
            textureLayer.bounds = CGRect(origin: .zero, size: key.renderSize)
            textureLayer.position = basePosition(index: index)
            textureLayer.setAffineTransform(.identity)
            textureLayer.opacity = modelOpacity(index: index)
        }
        CATransaction.commit()
        updateAnimationState()
    }

    private func updateAnimationState() {
        textureLayers.forEach { $0.removeAllAnimations() }
        guard let configuration,
              configuration.isVisible,
              !configuration.reducesMotion,
              window != nil,
              bounds.width > 1,
              !textureLayers.isEmpty
        else { return }

        let profile = StarlightMotionProfile.profile(for: configuration.theme)
        for (index, textureLayer) in textureLayers.enumerated() {
            installAnimations(
                on: textureLayer,
                index: index,
                profile: profile,
                lowPower: configuration.isLowPowerModeEnabled)
        }
    }

    private func installAnimations(
        on textureLayer: CALayer,
        index: Int,
        profile: StarlightMotionProfile,
        lowPower: Bool
    ) {
        let base = basePosition(index: index)
        let direction: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        let layerScale = 1 + CGFloat(index) * 0.10
        let x = bounds.width * profile.horizontalDrift * layerScale * direction
        let y = bounds.height * profile.verticalDrift * (1 + CGFloat(index) * 0.06)
        let durationScale = lowPower ? 1.55 : 1.0
        let phase = Double(index) * 0.17
        let frameRate = CAFrameRateRange(
            minimum: lowPower ? 8 : 15,
            maximum: lowPower ? 15 : 30,
            preferred: lowPower ? 15 : 30)

        let movement = CAKeyframeAnimation(keyPath: "position")
        movement.values = [
            CGPoint(x: base.x - x, y: base.y + y * 0.22),
            CGPoint(x: base.x + x * 0.45, y: base.y - y),
            CGPoint(x: base.x + x, y: base.y + y * 0.55),
            CGPoint(x: base.x - x * 0.34, y: base.y + y),
            CGPoint(x: base.x - x, y: base.y + y * 0.22),
        ].map(NSValue.init(point:))
        movement.keyTimes = [0, 0.24, 0.52, 0.79, 1]
        movement.duration = (6.2 + Double(index) * 0.82) * durationScale / profile.speed
        movement.repeatCount = .infinity
        movement.timingFunctions = Array(
            repeating: CAMediaTimingFunction(name: .easeInEaseOut),
            count: 4)
        movement.beginTime = CACurrentMediaTime() - movement.duration * phase
        movement.preferredFrameRateRange = frameRate
        movement.isRemovedOnCompletion = false
        textureLayer.add(movement, forKey: "starlight-position")

        let transform = CAKeyframeAnimation(keyPath: "transform")
        let rotation = profile.rotation * direction
        transform.values = [
            NSValue(caTransform3D: CATransform3DMakeAffineTransform(
                CGAffineTransform(rotationAngle: -rotation)
                    .scaledBy(x: 1 - profile.scaleDepth * 0.34, y: 1 + profile.scaleDepth * 0.14))),
            NSValue(caTransform3D: CATransform3DMakeAffineTransform(
                CGAffineTransform(rotationAngle: rotation * 0.45)
                    .scaledBy(x: 1 + profile.scaleDepth, y: 1 - profile.scaleDepth * 0.24))),
            NSValue(caTransform3D: CATransform3DMakeAffineTransform(
                CGAffineTransform(rotationAngle: -rotation)
                    .scaledBy(x: 1 - profile.scaleDepth * 0.34, y: 1 + profile.scaleDepth * 0.14))),
        ]
        transform.keyTimes = [0, 0.52, 1]
        transform.duration = (5.1 + Double(index) * 0.74) * durationScale / profile.speed
        transform.repeatCount = .infinity
        transform.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        transform.beginTime = CACurrentMediaTime() - transform.duration * (phase + 0.11)
        transform.preferredFrameRateRange = frameRate
        transform.isRemovedOnCompletion = false
        textureLayer.add(transform, forKey: "starlight-transform")

        let opacity = modelOpacity(index: index)
        if let pulseCadence = profile.pulseCadence {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [
                max(0.16, opacity - profile.opacityDepth * 0.72),
                min(1, opacity + profile.opacityDepth * 0.58),
                max(0.20, opacity - profile.opacityDepth * 0.34),
                min(1, opacity + profile.opacityDepth * 0.72),
                max(0.16, opacity - profile.opacityDepth * 0.72),
            ]
            pulse.keyTimes = [0, 0.18, 0.36, 0.62, 1]
            pulse.duration = (pulseCadence + Double(index) * 0.08) * durationScale
            pulse.repeatCount = .infinity
            pulse.timingFunctions = Array(
                repeating: CAMediaTimingFunction(name: .easeInEaseOut),
                count: 4)
            pulse.beginTime = CACurrentMediaTime() - pulse.duration * (phase + 0.21)
            pulse.preferredFrameRateRange = frameRate
            pulse.isRemovedOnCompletion = false
            textureLayer.add(pulse, forKey: "starlight-opacity")
        } else {
            let shimmer = CABasicAnimation(keyPath: "opacity")
            shimmer.fromValue = max(0.20, opacity - profile.opacityDepth)
            shimmer.toValue = min(1, opacity + profile.opacityDepth * 0.45)
            shimmer.duration = (4.0 + Double(index) * 0.61) * durationScale / profile.speed
            shimmer.autoreverses = true
            shimmer.repeatCount = .infinity
            shimmer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shimmer.beginTime = CACurrentMediaTime() - shimmer.duration * (phase + 0.21)
            shimmer.preferredFrameRateRange = frameRate
            shimmer.isRemovedOnCompletion = false
            textureLayer.add(shimmer, forKey: "starlight-opacity")
        }
    }

    private func basePosition(index: Int) -> CGPoint {
        let offsets: [CGPoint] = [
            CGPoint(x: 0.50, y: 0.40),
            CGPoint(x: 0.43, y: 0.36),
            CGPoint(x: 0.57, y: 0.42),
            CGPoint(x: 0.49, y: 0.33),
        ]
        let offset = offsets[min(index, offsets.count - 1)]
        return CGPoint(x: bounds.width * offset.x, y: bounds.height * offset.y)
    }

    private func modelOpacity(index: Int) -> Float {
        let light = configuration?.usesLightSurface == true
        let values: [Float] = light
            ? [0.76, 0.72, 0.68, 0.62]
            : [0.72, 0.68, 0.64, 0.58]
        return values[min(index, values.count - 1)]
    }
}

private struct StarlightRGBA: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    init(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func cgColor(alpha: CGFloat) -> CGColor {
        CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

private enum StarlightTextureRenderer {
    static func render(key: StarlightTextureKey) -> StarlightTextureSet? {
        let scale = key.scale
        let size = key.renderSize
        let width = max(1, Int((size.width * scale).rounded(.up)))
        let height = max(1, Int((size.height * scale).rounded(.up)))
        let opacity: CGFloat = key.usesLightSurface ? 0.84 : 0.78
        let colors = key.theme.rgbaColors

        guard let glow = renderImage(width: width, height: height, scale: scale, draw: { context, points in
            guard let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    colors[0].cgColor(alpha: opacity),
                    colors[1].cgColor(alpha: opacity * 0.54),
                    colors[2].cgColor(alpha: opacity * 0.18),
                    colors[2].cgColor(alpha: 0),
                ] as CFArray,
                locations: [0, 0.30, 0.66, 1])
            else { return }
            context.drawRadialGradient(
                gradient,
                startCenter: CGPoint(x: points.width * 0.50, y: points.height * 0.38),
                startRadius: 0,
                endCenter: CGPoint(x: points.width * 0.50, y: points.height * 0.43),
                endRadius: max(points.width, points.height) * 0.58,
                options: [.drawsAfterEndLocation])
        }) else { return nil }

        var images = [glow]
        for index in 0 ..< 3 {
            guard let band = renderImage(width: width, height: height, scale: scale, draw: { context, points in
                let path = CGMutablePath()
                let startY = points.height * (0.18 + CGFloat(index) * 0.12)
                path.move(to: CGPoint(x: -points.width * 0.10, y: startY))
                path.addCurve(
                    to: CGPoint(x: points.width * 1.10, y: points.height * (0.24 + CGFloat(index) * 0.05)),
                    control1: CGPoint(
                        x: points.width * 0.22,
                        y: points.height * (0.04 + CGFloat(index) * 0.09)),
                    control2: CGPoint(
                        x: points.width * 0.68,
                        y: points.height * (0.48 - CGFloat(index) * 0.07)))
                context.setLineCap(.round)
                context.setLineJoin(.round)
                let color = colors[(index + 1) % colors.count]
                for feather in stride(from: 9, through: 1, by: -1) {
                    context.addPath(path)
                    context.setLineWidth(CGFloat(feather) * (2.3 + CGFloat(index) * 0.35))
                    context.setStrokeColor(color.cgColor(
                        alpha: opacity * CGFloat(10 - feather) / 38))
                    context.strokePath()
                }
            }) else { return nil }
            images.append(band)
        }
        return StarlightTextureSet(images: images)
    }

    private static func renderImage(
        width: Int,
        height: Int,
        scale: CGFloat,
        draw: (CGContext, CGSize) -> Void
    ) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context, CGSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        return context.makeImage()
    }
}

struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isVisible: $isVisible)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: @unchecked Sendable {
        private var isVisible: Binding<Bool>
        private weak var window: NSWindow?
        private var observer: NSObjectProtocol?

        init(isVisible: Binding<Bool>) {
            self.isVisible = isVisible
        }

        func detach() {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            window = nil
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                update()
                return
            }
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            self.window = window
            if let window {
                observer = NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.update()
                    }
                }
            }
            update()
        }

        private func update() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            if isVisible.wrappedValue != visible {
                isVisible.wrappedValue = visible
            }
        }
    }
}
