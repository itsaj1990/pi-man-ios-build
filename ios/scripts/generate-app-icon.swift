// Generates the App Store's opaque icon from the approved PI Man icon.
// Runs in a macOS GitHub runner; does not alter the source image.
import AppKit
import Foundation

guard CommandLine.arguments.count == 3,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fputs("Usage: swift generate-app-icon.swift source.png output.png\n", stderr)
    exit(2)
}
let destination = URL(fileURLWithPath: CommandLine.arguments[2])
let side: CGFloat = 1024
let drawing = NSImage(size: NSSize(width: side, height: side))
drawing.lockFocus()
NSColor(calibratedRed: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: side, height: side)).fill()
NSGraphicsContext.current?.imageInterpolation = .high
image.draw(in: NSRect(x: 0, y: 0, width: side, height: side),
           from: NSRect(origin: .zero, size: image.size),
           operation: .sourceOver, fraction: 1)
drawing.unlockFocus()

// Passing through an opaque RGB JPEG representation removes the alpha
// channel; the final asset is PNG with a solid charcoal background.
guard let tiff = drawing.tiffRepresentation,
      let rgba = NSBitmapImageRep(data: tiff),
      let jpeg = rgba.representation(using: .jpeg, properties: [.compressionFactor: 1.0]),
      let rgb = NSBitmapImageRep(data: jpeg),
      let png = rgb.representation(using: .png, properties: [:]) else {
    fputs("Could not compose PI Man's 1024px opaque icon.\n", stderr)
    exit(1)
}
try FileManager.default.createDirectory(
    at: destination.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: destination, options: .atomic)
print("Generated branded 1024px iOS icon without an alpha channel.")
