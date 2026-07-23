import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
  fputs("usage: render-icon.swift INPUT.svg OUTPUT.png\n", stderr)
  exit(EXIT_FAILURE)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let pixelSize = 1024

guard let image = NSImage(contentsOf: inputURL) else {
  fputs("Could not load \(inputURL.path)\n", stderr)
  exit(EXIT_FAILURE)
}

guard
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: pixelSize,
    pixelsHigh: pixelSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  )
else {
  fputs("Could not allocate icon bitmap\n", stderr)
  exit(EXIT_FAILURE)
}

bitmap.size = NSSize(width: pixelSize, height: pixelSize)

NSGraphicsContext.saveGraphicsState()
defer { NSGraphicsContext.restoreGraphicsState() }

guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
  fputs("Could not create icon graphics context\n", stderr)
  exit(EXIT_FAILURE)
}

NSGraphicsContext.current = context
context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
image.draw(
  in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
  from: .zero,
  operation: .sourceOver,
  fraction: 1
)

guard let png = bitmap.representation(using: .png, properties: [:]) else {
  fputs("Could not encode icon PNG\n", stderr)
  exit(EXIT_FAILURE)
}

do {
  try png.write(to: outputURL, options: .atomic)
} catch {
  fputs("Could not write \(outputURL.path): \(error)\n", stderr)
  exit(EXIT_FAILURE)
}
