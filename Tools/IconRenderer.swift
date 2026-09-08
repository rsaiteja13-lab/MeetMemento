import AppKit
import Foundation

@main
struct IconRenderer {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        let pixels = 1024
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw CocoaError(.fileWriteUnknown)
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let background = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 216, yRadius: 216)
        background.addClip()
        NSGradient(starting: NSColor(red: 0.063, green: 0.165, blue: 0.337, alpha: 1),
                   ending: NSColor(red: 0.027, green: 0.075, blue: 0.153, alpha: 1))?
            .draw(in: background, angle: -45)

        let ring = NSBezierPath(ovalIn: NSRect(x: 226, y: 226, width: 572, height: 572))
        NSColor.white.withAlphaComponent(0.07).setFill()
        ring.fill()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        ring.lineWidth = 8
        ring.stroke()

        let wave = NSBezierPath()
        wave.move(to: NSPoint(x: 244, y: 512))
        for point in [
            NSPoint(x: 326, y: 512), NSPoint(x: 371, y: 644), NSPoint(x: 449, y: 374),
            NSPoint(x: 520, y: 730), NSPoint(x: 594, y: 341), NSPoint(x: 655, y: 582),
            NSPoint(x: 698, y: 446), NSPoint(x: 780, y: 446)
        ] { wave.line(to: point) }
        wave.lineWidth = 48
        wave.lineCapStyle = .round
        wave.lineJoinStyle = .round
        NSColor(red: 0.36, green: 0.72, blue: 1, alpha: 1).setStroke()
        wave.stroke()

        let recordingDot = NSBezierPath(ovalIn: NSRect(x: 725, y: 725, width: 132, height: 132))
        NSColor(red: 1, green: 0.294, blue: 0.333, alpha: 1).setFill()
        recordingDot.fill()

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: destination, options: .atomic)
    }
}
