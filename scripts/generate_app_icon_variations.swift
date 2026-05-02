import AppKit
import Foundation

let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDirectory = repoRoot.appendingPathComponent("marketing/app-store/icon/variations", isDirectory: true)

let canvasSize = CGSize(width: 1024, height: 1024)

let backgroundBase = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.92, alpha: 1)
let backgroundWarm = NSColor(calibratedRed: 0.99, green: 0.98, blue: 0.97, alpha: 1)
let bodyColor = NSColor(calibratedRed: 0.985, green: 0.98, blue: 0.97, alpha: 1)
let screenColor = NSColor(calibratedRed: 0.99, green: 0.985, blue: 0.975, alpha: 1)
let screenAccent = NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.92, alpha: 1)
let accent = NSColor(calibratedRed: 0.90, green: 0.48, blue: 0.24, alpha: 1)
let accentSoft = NSColor(calibratedRed: 0.97, green: 0.72, blue: 0.55, alpha: 1)
let glyph = NSColor(calibratedRed: 0.26, green: 0.31, blue: 0.37, alpha: 1)

func fillRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func strokeRoundedRect(_ rect: CGRect, radius: CGFloat, color: NSColor, lineWidth: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = lineWidth
    color.setStroke()
    path.stroke()
}

func withRotation(angleDegrees: CGFloat, around center: CGPoint, body: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext.current?.cgContext else {
        body()
        NSGraphicsContext.restoreGraphicsState()
        return
    }
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: angleDegrees * .pi / 180)
    context.translateBy(x: -center.x, y: -center.y)
    body()
    NSGraphicsContext.restoreGraphicsState()
}

func drawBackground() {
    fillRoundedRect(CGRect(origin: .zero, size: canvasSize), radius: 0, color: backgroundBase)

    NSColor.white.withAlphaComponent(0.65).setFill()
    NSBezierPath(ovalIn: CGRect(x: 84, y: 708, width: 316, height: 252)).fill()

    accentSoft.withAlphaComponent(0.18).setFill()
    NSBezierPath(ovalIn: CGRect(x: 740, y: 82, width: 244, height: 244)).fill()
    NSBezierPath(ovalIn: CGRect(x: 714, y: 614, width: 186, height: 186)).fill()

    glyph.withAlphaComponent(0.04).setFill()
    NSBezierPath(ovalIn: CGRect(x: 768, y: 746, width: 170, height: 170)).fill()

    let highlight = NSBezierPath()
    highlight.move(to: CGPoint(x: 230, y: 856))
    highlight.curve(
        to: CGPoint(x: 790, y: 842),
        controlPoint1: CGPoint(x: 404, y: 900),
        controlPoint2: CGPoint(x: 634, y: 892)
    )
    highlight.lineWidth = 18
    NSColor.white.withAlphaComponent(0.62).setStroke()
    highlight.stroke()
}

@discardableResult
func drawPhone(rect: CGRect, addSideButton: Bool = true) -> CGRect {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    shadow.shadowBlurRadius = 48
    shadow.shadowOffset = NSSize(width: 0, height: -24)
    shadow.set()
    fillRoundedRect(rect, radius: 112, color: bodyColor)
    NSGraphicsContext.restoreGraphicsState()

    fillRoundedRect(rect.insetBy(dx: 10, dy: 10), radius: 104, color: backgroundWarm)
    strokeRoundedRect(rect.insetBy(dx: 10, dy: 10), radius: 104, color: glyph.withAlphaComponent(0.05), lineWidth: 3)

    let screenRect = CGRect(x: rect.minX + 34, y: rect.minY + 54, width: rect.width - 68, height: rect.height - 108)
    fillRoundedRect(screenRect, radius: 82, color: screenAccent)
    fillRoundedRect(screenRect.insetBy(dx: 8, dy: 8), radius: 74, color: screenColor)
    strokeRoundedRect(screenRect, radius: 82, color: glyph.withAlphaComponent(0.06), lineWidth: 4)

    let islandRect = CGRect(x: rect.midX - 56, y: rect.maxY - 88, width: 112, height: 16)
    fillRoundedRect(islandRect, radius: 8, color: glyph.withAlphaComponent(0.18))

    let speakerGlow = NSBezierPath()
    speakerGlow.move(to: CGPoint(x: rect.minX + 82, y: rect.maxY - 46))
    speakerGlow.curve(
        to: CGPoint(x: rect.maxX - 82, y: rect.maxY - 50),
        controlPoint1: CGPoint(x: rect.minX + 170, y: rect.maxY - 16),
        controlPoint2: CGPoint(x: rect.maxX - 168, y: rect.maxY - 18)
    )
    speakerGlow.lineWidth = 12
    NSColor.white.withAlphaComponent(0.52).setStroke()
    speakerGlow.stroke()

    if addSideButton {
        fillRoundedRect(
            CGRect(x: rect.maxX - 8, y: rect.midY + 106, width: 12, height: 94),
            radius: 6,
            color: accent.withAlphaComponent(0.75)
        )
    }

    return screenRect
}

func drawPrompt(at point: CGPoint, size: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: size, weight: .bold),
        .foregroundColor: glyph
    ]
    NSAttributedString(string: ">_", attributes: attributes).draw(at: point)
}

func drawTranscriptLines(origin: CGPoint, widths: [CGFloat], lineWidth: CGFloat = 32, spacing: CGFloat = 82, color: NSColor = accent) {
    for (index, width) in widths.enumerated() {
        let y = origin.y - CGFloat(index) * spacing
        let path = NSBezierPath()
        path.move(to: CGPoint(x: origin.x, y: y))
        path.line(to: CGPoint(x: origin.x + width, y: y))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}

func drawMotionArc(start: CGPoint, end: CGPoint, control1: CGPoint, control2: CGPoint, width: CGFloat, color: NSColor) {
    let path = NSBezierPath()
    path.move(to: start)
    path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
    path.lineWidth = width
    path.lineCapStyle = .round
    color.setStroke()
    path.stroke()
}

func drawRouteBand(points: [CGPoint], controlPoints: [(CGPoint, CGPoint)], lineWidth: CGFloat = 26, nodeRadius: CGFloat = 30) {
    guard points.count == controlPoints.count + 1 else { return }

    let path = NSBezierPath()
    path.move(to: points[0])
    for index in controlPoints.indices {
        let controls = controlPoints[index]
        path.curve(to: points[index + 1], controlPoint1: controls.0, controlPoint2: controls.1)
    }

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.08)
    shadow.shadowBlurRadius = 12
    shadow.shadowOffset = NSSize(width: 0, height: -6)
    shadow.set()
    path.lineWidth = lineWidth
    path.lineCapStyle = .round
    path.lineJoinStyle = .round
    accent.setStroke()
    path.stroke()
    NSGraphicsContext.restoreGraphicsState()

    for point in points {
        fillRoundedRect(
            CGRect(x: point.x - nodeRadius, y: point.y - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2),
            radius: nodeRadius,
            color: accent
        )
        let inner = nodeRadius * 0.42
        fillRoundedRect(
            CGRect(x: point.x - inner, y: point.y - inner, width: inner * 2, height: inner * 2),
            radius: inner,
            color: screenColor
        )
    }
}

func drawConceptConversationRoute() {
    let phoneRect = CGRect(x: 336, y: 136, width: 352, height: 748)
    let screenRect = drawPhone(rect: phoneRect)

    drawMotionArc(
        start: CGPoint(x: 280, y: 326),
        end: CGPoint(x: 764, y: 282),
        control1: CGPoint(x: 386, y: 196),
        control2: CGPoint(x: 646, y: 184),
        width: 18,
        color: accentSoft.withAlphaComponent(0.32)
    )

    drawPrompt(at: CGPoint(x: screenRect.minX + 68, y: screenRect.maxY - 236), size: 150)
    drawRouteBand(
        points: [
            CGPoint(x: screenRect.minX + 88, y: screenRect.minY + 222),
            CGPoint(x: screenRect.minX + 100, y: screenRect.minY + 118),
            CGPoint(x: screenRect.maxX - 82, y: screenRect.minY + 136)
        ],
        controlPoints: [
            (CGPoint(x: screenRect.minX + 78, y: screenRect.minY + 192), CGPoint(x: screenRect.minX + 82, y: screenRect.minY + 148)),
            (CGPoint(x: screenRect.minX + 160, y: screenRect.minY + 58), CGPoint(x: screenRect.maxX - 136, y: screenRect.minY + 66))
        ]
    )
}

func drawConceptPromptTranscript() {
    let phoneRect = CGRect(x: 332, y: 142, width: 360, height: 740)
    withRotation(angleDegrees: -7, around: CGPoint(x: phoneRect.midX, y: phoneRect.midY)) {
        let screenRect = drawPhone(rect: phoneRect, addSideButton: false)

        drawMotionArc(
            start: CGPoint(x: phoneRect.minX - 42, y: phoneRect.maxY - 98),
            end: CGPoint(x: phoneRect.minX + 42, y: phoneRect.maxY - 16),
            control1: CGPoint(x: phoneRect.minX - 18, y: phoneRect.maxY - 54),
            control2: CGPoint(x: phoneRect.minX + 8, y: phoneRect.maxY - 24),
            width: 16,
            color: accentSoft.withAlphaComponent(0.34)
        )
        drawMotionArc(
            start: CGPoint(x: phoneRect.maxX - 14, y: phoneRect.minY + 80),
            end: CGPoint(x: phoneRect.maxX + 62, y: phoneRect.minY + 154),
            control1: CGPoint(x: phoneRect.maxX + 18, y: phoneRect.minY + 92),
            control2: CGPoint(x: phoneRect.maxX + 44, y: phoneRect.minY + 126),
            width: 14,
            color: accentSoft.withAlphaComponent(0.30)
        )

        drawPrompt(at: CGPoint(x: screenRect.minX + 58, y: screenRect.maxY - 220), size: 148)
        drawTranscriptLines(
            origin: CGPoint(x: screenRect.minX + 66, y: screenRect.midY + 12),
            widths: [172, 214, 158],
            lineWidth: 34,
            spacing: 82
        )
    }
}

func drawConceptThreadLane() {
    let phoneRect = CGRect(x: 326, y: 144, width: 372, height: 736)
    let screenRect = drawPhone(rect: phoneRect)

    drawMotionArc(
        start: CGPoint(x: 238, y: 720),
        end: CGPoint(x: 790, y: 738),
        control1: CGPoint(x: 398, y: 780),
        control2: CGPoint(x: 628, y: 786)
    ,
        width: 12,
        color: accentSoft.withAlphaComponent(0.22)
    )

    drawPrompt(at: CGPoint(x: screenRect.minX + 76, y: screenRect.maxY - 238), size: 146)
    drawTranscriptLines(
        origin: CGPoint(x: screenRect.minX + 72, y: screenRect.minY + 266),
        widths: [192, 142],
        lineWidth: 30,
        spacing: 74
    )

    fillRoundedRect(
        CGRect(x: screenRect.minX + 72, y: screenRect.minY + 98, width: screenRect.width - 144, height: 22),
        radius: 11,
        color: accent.withAlphaComponent(0.88)
    )
}

struct Concept {
    let filename: String
    let draw: () -> Void
}

let concepts = [
    Concept(filename: "CodingOnTheGo-AppIcon-Concept-ConversationRoute.png", draw: drawConceptConversationRoute),
    Concept(filename: "CodingOnTheGo-AppIcon-Concept-PromptTranscript.png", draw: drawConceptPromptTranscript),
    Concept(filename: "CodingOnTheGo-AppIcon-Concept-ThreadLane.png", draw: drawConceptThreadLane)
]

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for concept in concepts {
    let image = NSImage(size: canvasSize)
    image.lockFocus()
    guard NSGraphicsContext.current != nil else {
        fputs("Failed to create drawing context.\n", stderr)
        exit(1)
    }

    drawBackground()
    concept.draw()
    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode \(concept.filename).\n", stderr)
        exit(1)
    }

    let destination = outputDirectory.appendingPathComponent(concept.filename)
    try png.write(to: destination)
    print(destination.path)
}
