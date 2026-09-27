import AppKit

let destination = CommandLine.arguments[1]
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let background = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(calibratedRed: 0.14, green: 0.22, blue: 0.28, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.17, alpha: 1))!.draw(in: background, angle: 90)
let symbol = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: nil)!
let configuration = NSImage.SymbolConfiguration(pointSize: 470, weight: .medium)
let configured = symbol.withSymbolConfiguration(configuration)!
NSColor(calibratedRed: 0.81, green: 0.94, blue: 0.90, alpha: 1).set()
let tinted = NSImage(size: configured.size)
tinted.lockFocus()
configured.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
NSColor(calibratedRed: 0.81, green: 0.94, blue: 0.90, alpha: 1).setFill()
NSRect(origin: .zero, size: configured.size).fill(using: .sourceAtop)
tinted.unlockFocus()
tinted.draw(in: NSRect(x: 250, y: 230, width: 540, height: 570))
let dot = NSBezierPath(ovalIn: NSRect(x: 695, y: 205, width: 126, height: 126))
NSColor(calibratedRed: 1, green: 0.65, blue: 0.23, alpha: 1).setFill()
dot.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
