// Draws the DMG window background: swift scripts/dmg/background.swift <output.png> <scale>
import AppKit

let width: CGFloat = 640, height: CGFloat = 400
let output = CommandLine.arguments[1]
let scale = CGFloat(Double(CommandLine.arguments[2]) ?? 1)
let context = CGContext(data: nil, width: Int(width * scale), height: Int(height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.scaleBy(x: scale, y: scale)
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Soft wash of the website's accent colors.
context.setFillColor(color(0xfbfaff))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
let wash = CGGradient(colorsSpace: nil, colors: [color(0x4585f5, 0.16), color(0x9c6bed, 0.12), color(0xd9668f, 0.14)] as CFArray, locations: [0, 0.5, 1])!
context.drawLinearGradient(wash, start: CGPoint(x: 0, y: height), end: CGPoint(x: width, y: 0), options: [])

NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
func text(_ string: String, size: CGFloat, weight: NSFont.Weight, color textColor: NSColor, y: CGFloat) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    NSAttributedString(string: string, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: textColor, .paragraphStyle: style
    ]).draw(in: CGRect(x: 0, y: y, width: width, height: size * 1.5))
}
text("Blablador", size: 30, weight: .bold, color: NSColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1), y: 322)
text("Drag Blablador into Applications to install", size: 14, weight: .medium, color: NSColor(white: 0.36, alpha: 1), y: 296)

// Gradient arrow between the two icons (icons sit at y = 200 from the top, i.e. 200 from the bottom).
let arrow = CGMutablePath()
let midY: CGFloat = height - 200, left: CGFloat = 250, right: CGFloat = 390
arrow.move(to: CGPoint(x: left, y: midY + 7))
arrow.addLine(to: CGPoint(x: right - 26, y: midY + 7))
arrow.addLine(to: CGPoint(x: right - 26, y: midY + 20))
arrow.addLine(to: CGPoint(x: right, y: midY))
arrow.addLine(to: CGPoint(x: right - 26, y: midY - 20))
arrow.addLine(to: CGPoint(x: right - 26, y: midY - 7))
arrow.addLine(to: CGPoint(x: left, y: midY - 7))
arrow.closeSubpath()
context.saveGState()
context.addPath(arrow)
context.clip()
let accent = CGGradient(colorsSpace: nil, colors: [color(0x4585f5), color(0x9c6bed), color(0xd9668f)] as CFArray, locations: [0, 0.5, 1])!
context.drawLinearGradient(accent, start: CGPoint(x: left, y: midY), end: CGPoint(x: right, y: midY), options: [])
context.restoreGState()

// First-launch hint, since the app isn't notarized.
text("First launch: run  xattr -dr com.apple.quarantine /Applications/Blablador.app  in Terminal",
     size: 11, weight: .regular, color: NSColor(white: 0.42, alpha: 1), y: 24)

let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
rep.size = NSSize(width: width, height: height)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
