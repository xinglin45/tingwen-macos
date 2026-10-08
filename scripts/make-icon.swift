import AppKit

let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 72, y: 72, width: 880, height: 880), xRadius: 198, yRadius: 198)
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.48, blue: 0.44, alpha: 1),
           ending: NSColor(calibratedRed: 0.04, green: 0.29, blue: 0.30, alpha: 1))!.draw(in: background, angle: -90)
let page = NSBezierPath(roundedRect: NSRect(x: 258, y: 238, width: 430, height: 548), xRadius: 48, yRadius: 48)
NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.89, alpha: 1).setFill()
page.fill()
NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.39, alpha: 0.3).setStroke()
for y in [650, 570, 490] {
    let line = NSBezierPath()
    line.lineWidth = 24; line.lineCapStyle = .round
    line.move(to: NSPoint(x: 333, y: y)); line.line(to: NSPoint(x: 598, y: y)); line.stroke()
}
NSColor(calibratedRed: 0.91, green: 0.68, blue: 0.34, alpha: 1).setStroke()
for (i, height) in [72, 150, 232, 150, 72].enumerated() {
    let line = NSBezierPath()
    line.lineWidth = 31; line.lineCapStyle = .round
    let x = 540 + i * 54
    line.move(to: NSPoint(x: x, y: 340 - height / 2)); line.line(to: NSPoint(x: x, y: 340 + height / 2)); line.stroke()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
