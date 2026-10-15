#!/usr/bin/swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: compose-notifier-icon.swift doubaowork-base.png output.png\n", stderr)
    exit(2)
}
let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let inputImage = NSImage(contentsOf: inputURL),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                    isPlanar: false, colorSpaceName: .deviceRGB,
                                    bytesPerRow: 0, bitsPerPixel: 0) else {
    fputs("cannot read source image or create canvas\n", stderr)
    exit(3)
}
bitmap.size = NSSize(width: 1024, height: 1024)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
inputImage.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
                from: .zero, operation: .copy, fraction: 1)

let badgeRect = NSRect(x: 710, y: 98, width: 210, height: 210)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.set()
NSColor.white.setFill()
NSBezierPath(ovalIn: badgeRect).fill()
NSGraphicsContext.current?.saveGraphicsState()
let inner = badgeRect.insetBy(dx: 10, dy: 10)
NSColor(calibratedRed: 0.94, green: 0.08, blue: 0.09, alpha: 1).setFill()
NSBezierPath(ovalIn: inner).fill()
NSColor(calibratedWhite: 1, alpha: 0.86).setStroke()
let stroke = NSBezierPath(ovalIn: inner.insetBy(dx: 4, dy: 4))
stroke.lineWidth = 4
stroke.stroke()

if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil) {
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: 104, weight: .bold)
    let colorConfig = NSImage.SymbolConfiguration(paletteColors: [.white])
    let symbol = bell.withSymbolConfiguration(sizeConfig.applying(colorConfig)) ?? bell
    symbol.isTemplate = false
    let bellRect = NSRect(x: badgeRect.midX - 62, y: badgeRect.midY - 58, width: 124, height: 124)
    symbol.draw(in: bellRect, from: .zero, operation: .sourceOver, fraction: 1)
} else {
    fputs("system bell.fill symbol unavailable\n", stderr)
    exit(4)
}
NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else {
    fputs("cannot encode PNG\n", stderr)
    exit(5)
}
try data.write(to: outputURL, options: .atomic)
print("badge=bell.fill rect=710,98,210,210 size=1024x1024")
