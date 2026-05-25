#!/usr/bin/env swift
// Generates the DMG background image: white canvas with a soft right-pointing
// arrow between where the app icon and the Applications symlink will sit,
// plus a "Drag to install" caption underneath.
import AppKit

guard CommandLine.arguments.count == 2 else {
    print("Usage: make-background.swift <output.png>")
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let width: CGFloat = 600
let height: CGFloat = 400

let img = NSImage(size: NSSize(width: width, height: height))
img.lockFocus()

// White background
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Arrow geometry — centered between icon positions (160, 200) and (440, 200)
let arrowColor = NSColor(calibratedRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)
let arrowStartX: CGFloat = 235
let arrowTipX: CGFloat = 365
let arrowY: CGFloat = 200
let arrowHeadLen: CGFloat = 24
let arrowHeadWidth: CGFloat = 22

// Shaft — a thick rounded line
let shaft = NSBezierPath()
shaft.lineWidth = 8
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: arrowStartX, y: arrowY))
shaft.line(to: NSPoint(x: arrowTipX - arrowHeadLen + 4, y: arrowY))
arrowColor.setStroke()
shaft.stroke()

// Arrowhead — filled triangle
let head = NSBezierPath()
head.move(to: NSPoint(x: arrowTipX, y: arrowY))
head.line(to: NSPoint(x: arrowTipX - arrowHeadLen, y: arrowY + arrowHeadWidth / 2))
head.line(to: NSPoint(x: arrowTipX - arrowHeadLen, y: arrowY - arrowHeadWidth / 2))
head.close()
arrowColor.setFill()
head.fill()

// Caption
let caption = "Drag NoteFlow to Applications to install"
let font = NSFont.systemFont(ofSize: 13, weight: .medium)
let textColor = NSColor(calibratedRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
let textSize = caption.size(withAttributes: attrs)
let textRect = NSRect(
    x: (width - textSize.width) / 2,
    y: 56,
    width: textSize.width,
    height: textSize.height
)
caption.draw(in: textRect, withAttributes: attrs)

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    print("Failed to encode PNG")
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
    print("Wrote \(outputPath)")
} catch {
    print("Failed to write: \(error)")
    exit(1)
}
