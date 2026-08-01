#!/usr/bin/env swift

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
let rootPath: String = {
    if let index = arguments.firstIndex(of: "--root"), index + 1 < arguments.count {
        return arguments[index + 1]
    }
    return FileManager.default.currentDirectoryPath
}()

let root = URL(fileURLWithPath: rootPath, isDirectory: true)
let screenshots = root.appendingPathComponent("Screenshots", isDirectory: true)
let animations = screenshots.appendingPathComponent("animations", isDirectory: true)
let providers = screenshots.appendingPathComponent("providers", isDirectory: true)

try FileManager.default.createDirectory(at: animations, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)

let canvasSize = NSSize(width: 900, height: 760)

enum DemoState {
    case idle
    case running
    case error
    case completed
    case multipleRunning
    case runningWithCompletions

    var title: String {
        switch self {
        case .idle: return "Default"
        case .running: return "Task running"
        case .error: return "Task error"
        case .completed: return "Task completed"
        case .multipleRunning: return "Multiple tasks running"
        case .runningWithCompletions: return "Running + completed"
        }
    }

    var subtitle: String {
        switch self {
        case .idle: return "Quota stays visible while you code"
        case .running: return "The HUD surfaces active work at a glance"
        case .error: return "Errors stay visible until they are acknowledged"
        case .completed: return "Completed work becomes an unread reminder"
        case .multipleRunning: return "Parallel agent work is summarized in one rail"
        case .runningWithCompletions: return "A completion reminder survives while work continues"
        }
    }

    var detailLines: [String] {
        switch self {
        case .idle:
            return ["No task activity", "Quota stays visible", "Reset time remains visible"]
        case .running:
            return ["Thinking", "Quota remains visible", "Activity rail turns blue"]
        case .error:
            return ["Error state", "Red attention signal", "Needs acknowledgement"]
        case .completed:
            return ["Unread completion", "Green reminder badge", "Click to acknowledge"]
        case .multipleRunning:
            return ["2 tasks running", "Aggregated activity", "One compact HUD"]
        case .runningWithCompletions:
            return ["1 task running", "2 completed unread", "No reminder is lost"]
        }
    }
}

struct StateFrame {
    let state: DemoState
    let imageName: String
    let isSynthetic: Bool
}

func image(named name: String) -> NSImage {
    let url = screenshots.appendingPathComponent(name)
    guard let value = NSImage(contentsOf: url) else {
        fatalError("Unable to load screenshot: \(url.path)")
    }
    return value
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

func roundedPath(_ rect: NSRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func drawText(_ value: String, at point: NSPoint, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    value.draw(at: point, withAttributes: attributes)
}

func drawText(_ value: String, in rect: NSRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph
    ]
    value.draw(in: rect, withAttributes: attributes)
}

func fill(_ path: NSBezierPath, with color: NSColor) {
    color.setFill()
    path.fill()
}

func stroke(_ path: NSBezierPath, with color: NSColor, width: CGFloat = 1) {
    color.setStroke()
    path.lineWidth = width
    path.stroke()
}

func makeImage(_ draw: () -> Void) -> NSImage {
    let pixelsWide = Int(canvasSize.width)
    let pixelsHigh = Int(canvasSize.height)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0) else {
        fatalError("Unable to create bitmap canvas")
    }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create graphics context")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    draw()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    let result = NSImage(size: canvasSize)
    result.addRepresentation(bitmap)
    return result
}

func drawBackground() {
    let bounds = NSRect(origin: .zero, size: canvasSize)
    let gradient = NSGradient(colors: [
        color(0.025, 0.035, 0.065),
        color(0.055, 0.075, 0.125),
        color(0.018, 0.022, 0.042)
    ])!
    gradient.draw(in: bounds, angle: 35)

    let glow = NSBezierPath(ovalIn: NSRect(x: -180, y: 315, width: 640, height: 640))
    color(0.05, 0.25, 0.52, 0.12).setFill()
    glow.fill()
    let glowTwo = NSBezierPath(ovalIn: NSRect(x: 480, y: -230, width: 620, height: 620))
    color(0.15, 0.32, 0.52, 0.08).setFill()
    glowTwo.fill()
}

func statusColor(for state: DemoState) -> NSColor {
    switch state {
    case .idle: return color(0.42, 0.48, 0.58)
    case .running, .multipleRunning, .runningWithCompletions: return color(0.20, 0.52, 1.0)
    case .error: return color(1.0, 0.29, 0.31)
    case .completed: return color(0.20, 0.82, 0.42)
    }
}

func stateBadge(for state: DemoState) -> String {
    switch state {
    case .idle: return "IDLE"
    case .running: return "THINKING"
    case .error: return "ERROR"
    case .completed: return "UNREAD"
    case .multipleRunning: return "THINKING ×2"
    case .runningWithCompletions: return "THINKING  ✓2"
    }
}

func syntheticActivityImage(base: NSImage, state: DemoState) -> NSImage {
    let size = base.size
    let output = NSImage(size: size)
    output.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)

    guard state != .idle else {
        output.unlockFocus()
        return output
    }

    let accent = statusColor(for: state)
    let topHeight = min(205, size.height * 0.43)
    let gradient = NSGradient(colors: [accent.withAlphaComponent(0.66), accent.withAlphaComponent(0.08), .clear])!
    gradient.draw(in: NSRect(x: 0, y: size.height - topHeight, width: size.width, height: topHeight), angle: 90)

    let badgeWidth = min(size.width - 24, max(88, stateBadge(for: state).size(withAttributes: [.font: NSFont.systemFont(ofSize: 15, weight: .bold)]).width + 30))
    let badge = NSRect(x: (size.width - badgeWidth) / 2, y: size.height - 154, width: badgeWidth, height: 40)
    fill(roundedPath(badge, radius: 20), with: color(0.03, 0.035, 0.05, 0.92))
    drawText(stateBadge(for: state), in: badge.offsetBy(dx: 0, dy: 1), font: NSFont.systemFont(ofSize: 15, weight: .bold), color: .white, alignment: .center)
    output.unlockFocus()
    return output
}

func makeStage(hud: NSImage, state: DemoState, quotaTitle: String, frameIndex: Int, frameCount: Int) -> NSImage {
    makeImage {
        drawBackground()

        drawText("CODEX USAGE HUD", at: NSPoint(x: 64, y: 704), font: NSFont.systemFont(ofSize: 13, weight: .bold), color: color(0.62, 0.70, 0.82))
        drawText("DEMO DATA · NO ACCOUNT INFO", in: NSRect(x: 605, y: 701, width: 230, height: 20), font: NSFont.systemFont(ofSize: 11, weight: .medium), color: color(0.48, 0.56, 0.68), alignment: .right)

        let card = NSRect(x: 46, y: 72, width: 320, height: 585)
        fill(roundedPath(card, radius: 28), with: color(0.03, 0.045, 0.08, 0.54))
        stroke(roundedPath(card, radius: 28), with: color(0.35, 0.55, 0.82, 0.16), width: 1)

        let scale = min(0.78, (card.height - 40) / hud.size.height)
        let hudRect = NSRect(
            x: card.midX - hud.size.width * scale / 2,
            y: card.midY - hud.size.height * scale / 2,
            width: hud.size.width * scale,
            height: hud.size.height * scale)
        hud.draw(in: hudRect, from: .zero, operation: .sourceOver, fraction: 1)

        drawText(quotaTitle, at: NSPoint(x: 428, y: 574), font: NSFont.systemFont(ofSize: 26, weight: .bold), color: .white)
        drawText(state.title, at: NSPoint(x: 428, y: 516), font: NSFont.systemFont(ofSize: 34, weight: .bold), color: statusColor(for: state))
        drawText(state.subtitle, in: NSRect(x: 428, y: 463, width: 390, height: 52), font: NSFont.systemFont(ofSize: 17, weight: .regular), color: color(0.72, 0.78, 0.88))

        let lineX: CGFloat = 428
        for (offset, line) in state.detailLines.enumerated() {
            let y = 370 - CGFloat(offset) * 48
            let dot = NSBezierPath(ovalIn: NSRect(x: lineX, y: y + 5, width: 9, height: 9))
            fill(dot, with: statusColor(for: state))
            drawText(line, at: NSPoint(x: lineX + 22, y: y), font: NSFont.systemFont(ofSize: 17, weight: .medium), color: color(0.86, 0.89, 0.95))
        }

        let progressY: CGFloat = 112
        drawText("STATE FLOW", at: NSPoint(x: 428, y: progressY + 28), font: NSFont.systemFont(ofSize: 11, weight: .bold), color: color(0.48, 0.57, 0.70))
        let startX: CGFloat = 428
        let gap: CGFloat = 42
        for index in 0..<frameCount {
            let x = startX + CGFloat(index) * gap
            let dot = NSBezierPath(ovalIn: NSRect(x: x, y: progressY, width: index == frameIndex ? 12 : 8, height: index == frameIndex ? 12 : 8))
            fill(dot, with: index == frameIndex ? statusColor(for: state) : color(0.34, 0.42, 0.55))
        }
        let footer = "Fixed screenshots · safe for README and release page"
        drawText(footer, at: NSPoint(x: 428, y: 70), font: NSFont.systemFont(ofSize: 11, weight: .regular), color: color(0.46, 0.54, 0.66))
    }
}

func blend(_ from: NSImage, _ to: NSImage, amount: CGFloat) -> NSImage {
    makeImage {
        from.draw(in: NSRect(origin: .zero, size: canvasSize), from: .zero, operation: .sourceOver, fraction: 1 - amount)
        to.draw(in: NSRect(origin: .zero, size: canvasSize), from: .zero, operation: .sourceOver, fraction: amount)
    }
}

func cgImage(_ image: NSImage) -> CGImage {
    var rect = NSRect(origin: .zero, size: image.size)
    guard let value = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
        fatalError("Unable to create CGImage")
    }
    return value
}

func writeGIF(_ images: [NSImage], to url: URL, delay: Double = 0.78) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, images.count, nil) else {
        throw NSError(domain: "DemoGIF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to create GIF destination"])
    }
    let properties: [CFString: Any] = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0
        ]
    ]
    CGImageDestinationSetProperties(destination, properties as CFDictionary)
    for item in images {
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay,
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage(item), frameProperties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "DemoGIF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize GIF"])
    }
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "DemoGIF", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create PNG destination"])
    }
    CGImageDestinationAddImage(destination, cgImage(image), nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "DemoGIF", code: 4, userInfo: [NSLocalizedDescriptionKey: "Unable to finalize PNG"])
    }
}

func makeFrames(weeklyOnly: Bool) -> [NSImage] {
    let states: [StateFrame] = weeklyOnly
        ? [
            StateFrame(state: .idle, imageName: "02-weekly-only-default.png", isSynthetic: false),
            StateFrame(state: .running, imageName: "02-weekly-only-default.png", isSynthetic: true),
            StateFrame(state: .error, imageName: "02-weekly-only-default.png", isSynthetic: true),
            StateFrame(state: .completed, imageName: "02-weekly-only-default.png", isSynthetic: true),
            StateFrame(state: .multipleRunning, imageName: "02-weekly-only-default.png", isSynthetic: true),
            StateFrame(state: .runningWithCompletions, imageName: "02-weekly-only-default.png", isSynthetic: true)
        ]
        : [
            StateFrame(state: .idle, imageName: "01-dual-default.png", isSynthetic: false),
            StateFrame(state: .running, imageName: "05-multitask-running.png", isSynthetic: false),
            StateFrame(state: .error, imageName: "01-dual-default.png", isSynthetic: true),
            StateFrame(state: .completed, imageName: "07-single-task-completed.png", isSynthetic: false),
            StateFrame(state: .multipleRunning, imageName: "05-multitask-running.png", isSynthetic: false),
            StateFrame(state: .runningWithCompletions, imageName: "08-running-with-completions.png", isSynthetic: false)
        ]

    var baseFrames: [NSImage] = []
    for item in states {
        let base = image(named: item.imageName)
        let hud = item.isSynthetic ? syntheticActivityImage(base: base, state: item.state) : base
        let title = weeklyOnly ? "Weekly-only quota" : "Five-hour + weekly quota"
        baseFrames.append(makeStage(hud: hud, state: item.state, quotaTitle: title, frameIndex: baseFrames.count, frameCount: states.count))
    }

    var frames: [NSImage] = []
    for index in baseFrames.indices {
        for _ in 0..<2 { frames.append(baseFrames[index]) }
        let next = baseFrames[(index + 1) % baseFrames.count]
        for step in 1...4 {
            frames.append(blend(baseFrames[index], next, amount: CGFloat(step) / 5))
        }
    }
    return frames
}

func makeProviderImage(title: String, subtitle: String, accent: NSColor, base: NSImage, iconText: String?) -> NSImage {
    let output = NSImage(size: base.size)
    output.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: base.size), from: .zero, operation: .copy, fraction: 1)

    if let iconText {
        let headerPatch = NSRect(x: 14, y: base.size.height - 80, width: 340, height: 68)
        fill(NSBezierPath(rect: headerPatch), with: color(0.105, 0.108, 0.112))
        let iconRect = NSRect(x: 28, y: base.size.height - 65, width: 42, height: 42)
        fill(roundedPath(iconRect, radius: 10), with: accent)
        drawText(iconText, in: iconRect.offsetBy(dx: 0, dy: 1), font: NSFont.systemFont(ofSize: 22, weight: .bold), color: .white, alignment: .center)
        drawText(title, at: NSPoint(x: 84, y: base.size.height - 57), font: NSFont.systemFont(ofSize: 25, weight: .bold), color: color(0.88, 0.88, 0.90))
    }

    let labelRect = NSRect(x: 22, y: 22, width: base.size.width - 44, height: 30)
    fill(roundedPath(labelRect, radius: 15), with: color(0.03, 0.035, 0.05, 0.90))
    drawText(subtitle, in: labelRect.offsetBy(dx: 0, dy: 1), font: NSFont.systemFont(ofSize: 13, weight: .medium), color: color(0.75, 0.81, 0.90), alignment: .center)
    output.unlockFocus()
    return output
}

let dualFrames = makeFrames(weeklyOnly: false)
let weeklyFrames = makeFrames(weeklyOnly: true)
try writeGIF(dualFrames, to: animations.appendingPathComponent("five-hour-plus-weekly.gif"))
try writeGIF(weeklyFrames, to: animations.appendingPathComponent("weekly-only.gif"))

let dualExpanded = image(named: "03-dual-expanded.png")
try writePNG(dualExpanded, to: providers.appendingPathComponent("codex.png"))
try writePNG(
    makeProviderImage(
        title: "Claude Code",
        subtitle: "Claude Code · fixed demo data",
        accent: color(0.55, 0.35, 0.95),
        base: dualExpanded,
        iconText: "C"),
    to: providers.appendingPathComponent("claude-code.png"))
try writePNG(
    makeProviderImage(
        title: "Kimi",
        subtitle: "Kimi · fixed demo data",
        accent: color(0.18, 0.46, 0.98),
        base: dualExpanded,
        iconText: "K"),
    to: providers.appendingPathComponent("kimi.png"))

print("Generated demo assets in \(screenshots.path)")
