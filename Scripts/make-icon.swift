#!/usr/bin/env swift
// Draws the MeshDash app icon — concentric propagation rings with a mesh of
// linked nodes — and writes the iconset PNGs. Run via Scripts/make-icon.sh.
import AppKit
import CoreGraphics
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./MeshDash.iconset"
try? FileManager.default.createDirectory(atPath: outputDirectory, withIntermediateDirectories: true)

/// Node positions in a 0...1 unit square, plus the links between them.
let nodes: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
    (0.50, 0.56, 0.085),
    (0.26, 0.72, 0.050),
    (0.74, 0.73, 0.050),
    (0.30, 0.32, 0.046),
    (0.70, 0.31, 0.046),
    (0.50, 0.855, 0.040),
]
let links: [(Int, Int)] = [(0, 1), (0, 2), (0, 3), (0, 4), (1, 5), (2, 5), (1, 3), (2, 4)]

func drawIcon(size: CGFloat) -> CGImage? {
    let scale = size
    guard let context = CGContext(data: nil, width: Int(size), height: Int(size),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // Rounded-rect background with the macOS squircle proportions.
    let inset = size * 0.06
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let background = CGPath(roundedRect: rect, cornerWidth: rect.width * 0.225,
                            cornerHeight: rect.height * 0.225, transform: nil)
    context.saveGState()
    context.addPath(background)
    context.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [CGColor(red: 0.10, green: 0.16, blue: 0.34, alpha: 1),
                                          CGColor(red: 0.05, green: 0.42, blue: 0.55, alpha: 1)] as CFArray,
                                 locations: [0, 1]) {
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }

    // Propagation rings radiating from the central node.
    let center = CGPoint(x: 0.50 * scale, y: 0.56 * scale)
    for (index, radius) in [0.17, 0.26, 0.35, 0.44].enumerated() {
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.20 - Double(index) * 0.04))
        context.setLineWidth(size * 0.016)
        context.addArc(center: center, radius: radius * scale, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.strokePath()
    }

    // Links, then nodes on top so the joins stay clean.
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.45))
    context.setLineWidth(size * 0.018)
    context.setLineCap(.round)
    for link in links {
        context.move(to: CGPoint(x: nodes[link.0].x * scale, y: nodes[link.0].y * scale))
        context.addLine(to: CGPoint(x: nodes[link.1].x * scale, y: nodes[link.1].y * scale))
    }
    context.strokePath()

    for (index, node) in nodes.enumerated() {
        let point = CGPoint(x: node.x * scale, y: node.y * scale)
        let radius = node.r * scale
        context.setFillColor(index == 0
            ? CGColor(red: 0.51, green: 0.93, blue: 0.72, alpha: 1)
            : CGColor(red: 1, green: 1, blue: 1, alpha: 0.94))
        context.addArc(center: point, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        context.fillPath()
    }
    context.restoreGState()
    return context.makeImage()
}

// The sizes iconutil expects in an .iconset.
let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    guard let image = drawIcon(size: variant.size) else { continue }
    let bitmap = NSBitmapImageRep(cgImage: image)
    bitmap.size = NSSize(width: variant.size, height: variant.size)
    guard let data = bitmap.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: URL(fileURLWithPath: "\(outputDirectory)/\(variant.name).png"))
}
print("Wrote \(variants.count) icon sizes to \(outputDirectory)")
