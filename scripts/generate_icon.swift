#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// DirectMetal macOS App Icon Generator (.icns)
// Pure Swift CoreGraphics + AppKit — zero external dependencies.
// Generates all standard macOS iconset sizes (16..1024 @1x/@2x) and compiles AppIcon.icns via iconutil.

struct IconSpec {
    let pointSize: Int
    let scale: Int
    var pixelSize: Int { pointSize * scale }
    var filename: String {
        scale == 1
            ? "icon_\(pointSize)x\(pointSize).png"
            : "icon_\(pointSize)x\(pointSize)@\(scale)x.png"
    }
}

let iconSpecs: [IconSpec] = [
    IconSpec(pointSize: 16, scale: 1),   // 16px
    IconSpec(pointSize: 16, scale: 2),   // 32px
    IconSpec(pointSize: 32, scale: 1),   // 32px
    IconSpec(pointSize: 32, scale: 2),   // 64px
    IconSpec(pointSize: 128, scale: 1),  // 128px
    IconSpec(pointSize: 128, scale: 2),  // 256px
    IconSpec(pointSize: 256, scale: 1),  // 256px
    IconSpec(pointSize: 256, scale: 2),  // 512px
    IconSpec(pointSize: 512, scale: 1),  // 512px
    IconSpec(pointSize: 512, scale: 2),  // 1024px
]

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func cgColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

func makeGradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    let colors = stops.map { $0.1 } as CFArray
    var locations = stops.map { $0.0 }
    return CGGradient(colorsSpace: colorSpace, colors: colors, locations: &locations)!
}

func makePolygon(_ points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    for pt in points.dropFirst() {
        path.addLine(to: pt)
    }
    path.closeSubpath()
    return path
}

func fillPolygonGradient(
    _ ctx: CGContext,
    points: [CGPoint],
    gradient: CGGradient,
    start: CGPoint,
    end: CGPoint
) {
    ctx.saveGState()
    ctx.addPath(makePolygon(points))
    ctx.clip()
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func makeDMEmblemPath() -> CGPath {
    let path = CGMutablePath()

    // 'D' outer contour (x: 398..496, y: 450..574)
    path.move(to: CGPoint(x: 398, y: 450))
    path.addLine(to: CGPoint(x: 398, y: 574))
    path.addLine(to: CGPoint(x: 446, y: 574))
    path.addCurve(
        to: CGPoint(x: 496, y: 512),
        control1: CGPoint(x: 478, y: 574),
        control2: CGPoint(x: 496, y: 548)
    )
    path.addCurve(
        to: CGPoint(x: 446, y: 450),
        control1: CGPoint(x: 496, y: 476),
        control2: CGPoint(x: 478, y: 450)
    )
    path.closeSubpath()

    // 'D' inner counter (punched out via even-odd rule)
    path.move(to: CGPoint(x: 424, y: 474))
    path.addLine(to: CGPoint(x: 424, y: 550))
    path.addLine(to: CGPoint(x: 444, y: 550))
    path.addCurve(
        to: CGPoint(x: 470, y: 512),
        control1: CGPoint(x: 461, y: 550),
        control2: CGPoint(x: 470, y: 534)
    )
    path.addCurve(
        to: CGPoint(x: 444, y: 474),
        control1: CGPoint(x: 470, y: 490),
        control2: CGPoint(x: 461, y: 474)
    )
    path.closeSubpath()

    // 'M' contour (x: 514..626, y: 450..574)
    path.move(to: CGPoint(x: 514, y: 450))
    path.addLine(to: CGPoint(x: 514, y: 574))
    path.addLine(to: CGPoint(x: 540, y: 574))
    path.addLine(to: CGPoint(x: 570, y: 514))
    path.addLine(to: CGPoint(x: 600, y: 574))
    path.addLine(to: CGPoint(x: 626, y: 574))
    path.addLine(to: CGPoint(x: 626, y: 450))
    path.addLine(to: CGPoint(x: 601, y: 450))
    path.addLine(to: CGPoint(x: 601, y: 526))
    path.addLine(to: CGPoint(x: 578, y: 482))
    path.addLine(to: CGPoint(x: 562, y: 482))
    path.addLine(to: CGPoint(x: 539, y: 526))
    path.addLine(to: CGPoint(x: 539, y: 450))
    path.closeSubpath()

    return path
}

func drawDirectMetalIcon(in ctx: CGContext, pixelSize: Int) {
    let canvas: CGFloat = 1024.0
    let scale = CGFloat(pixelSize) / canvas

    ctx.saveGState()
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
    ctx.scaleBy(x: scale, y: scale)

    let squircleRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 185.0
    let squirclePath = CGPath(
        roundedRect: squircleRect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )

    // 1. Exterior macOS elevation shadow
    if pixelSize >= 32 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -12),
            blur: 28,
            color: cgColor(0.0, 0.0, 0.0, 0.52)
        )
        ctx.setFillColor(cgColor(0.05, 0.06, 0.10, 1.0))
        ctx.addPath(squirclePath)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Clip all interior layers to the macOS squircle
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    // 2. Dark metallic anodized aluminum / obsidian gradient base
    let bgGrad = makeGradient([
        (0.00, cgColor(0.14, 0.17, 0.24, 1.0)), // Anodized titanium slate
        (0.45, cgColor(0.07, 0.09, 0.14, 1.0)), // Deep obsidian
        (1.00, cgColor(0.03, 0.04, 0.07, 1.0)), // Carbon abyss
    ])
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Subtle diagonal brushed anodized sheen
    let sheenGrad = makeGradient([
        (0.00, cgColor(0.38, 0.52, 0.78, 0.10)),
        (0.50, cgColor(1.00, 1.00, 1.00, 0.03)),
        (1.00, cgColor(0.52, 0.24, 0.88, 0.10)),
    ])
    ctx.drawLinearGradient(
        sheenGrad,
        start: CGPoint(x: 100, y: 924),
        end: CGPoint(x: 924, y: 100),
        options: []
    )

    // 3. Ambient DirectX (cyan/emerald) -> Metal 4 (violet/magenta) radial glows
    let leftGlow = makeGradient([
        (0.0, cgColor(0.06, 0.78, 0.82, 0.30)),
        (1.0, cgColor(0.06, 0.78, 0.82, 0.00)),
    ])
    ctx.drawRadialGradient(
        leftGlow,
        startCenter: CGPoint(x: 340, y: 512),
        startRadius: 10,
        endCenter: CGPoint(x: 340, y: 512),
        endRadius: 340,
        options: []
    )

    let rightGlow = makeGradient([
        (0.0, cgColor(0.62, 0.26, 0.96, 0.34)),
        (1.0, cgColor(0.62, 0.26, 0.96, 0.00)),
    ])
    ctx.drawRadialGradient(
        rightGlow,
        startCenter: CGPoint(x: 684, y: 512),
        startRadius: 10,
        endCenter: CGPoint(x: 684, y: 512),
        endRadius: 360,
        options: []
    )

    // 4. Apple Silicon precision die frame & subtle trace lines
    if pixelSize >= 64 {
        let dieFrame = CGPath(
            roundedRect: CGRect(x: 148, y: 148, width: 728, height: 728),
            cornerWidth: 142,
            cornerHeight: 142,
            transform: nil
        )
        ctx.setStrokeColor(cgColor(0.75, 0.84, 0.98, 0.08))
        ctx.setLineWidth(3.0)
        ctx.addPath(dieFrame)
        ctx.strokePath()

        // Subtle silicon wafer grid ticks along top & bottom die border
        ctx.setStrokeColor(cgColor(0.58, 0.72, 0.94, 0.07))
        ctx.setLineWidth(2.5)
        for step in stride(from: 332, through: 692, by: 45) {
            let x = CGFloat(step)
            ctx.move(to: CGPoint(x: x, y: 856))
            ctx.addLine(to: CGPoint(x: x, y: 876))
            ctx.move(to: CGPoint(x: x, y: 148))
            ctx.addLine(to: CGPoint(x: x, y: 168))
        }
        ctx.strokePath()
    }

    // 5. Incoming DirectX crystalline beam (left -> prism)
    fillPolygonGradient(
        ctx,
        points: [
            CGPoint(x: 100, y: 548),
            CGPoint(x: 312, y: 540),
            CGPoint(x: 312, y: 484),
            CGPoint(x: 100, y: 462),
        ],
        gradient: makeGradient([
            (0.0, cgColor(0.06, 0.73, 0.51, 0.18)), // Emerald
            (0.6, cgColor(0.08, 0.78, 0.85, 0.68)), // Cyan
            (1.0, cgColor(0.38, 0.92, 0.98, 0.92)), // Specular cyan core
        ]),
        start: CGPoint(x: 100, y: 505),
        end: CGPoint(x: 312, y: 512)
    )

    // 6. Outgoing Metal 4 refracted spectrum beams (prism -> right)
    // Upper Violet-Indigo ray
    fillPolygonGradient(
        ctx,
        points: [
            CGPoint(x: 706, y: 548),
            CGPoint(x: 924, y: 652),
            CGPoint(x: 924, y: 582),
            CGPoint(x: 716, y: 520),
        ],
        gradient: makeGradient([
            (0.0, cgColor(0.45, 0.42, 0.98, 0.90)),
            (1.0, cgColor(0.55, 0.36, 0.96, 0.16)),
        ]),
        start: CGPoint(x: 706, y: 534),
        end: CGPoint(x: 924, y: 618)
    )
    // Mid Magenta-Rose ray
    fillPolygonGradient(
        ctx,
        points: [
            CGPoint(x: 716, y: 526),
            CGPoint(x: 924, y: 554),
            CGPoint(x: 924, y: 474),
            CGPoint(x: 716, y: 496),
        ],
        gradient: makeGradient([
            (0.0, cgColor(0.86, 0.28, 0.94, 0.92)),
            (1.0, cgColor(0.96, 0.25, 0.58, 0.20)),
        ]),
        start: CGPoint(x: 716, y: 512),
        end: CGPoint(x: 924, y: 514)
    )
    // Lower Amber-Coral MetalFX ray
    fillPolygonGradient(
        ctx,
        points: [
            CGPoint(x: 706, y: 502),
            CGPoint(x: 924, y: 446),
            CGPoint(x: 924, y: 376),
            CGPoint(x: 696, y: 474),
        ],
        gradient: makeGradient([
            (0.0, cgColor(0.98, 0.46, 0.22, 0.88)),
            (1.0, cgColor(0.98, 0.74, 0.16, 0.15)),
        ]),
        start: CGPoint(x: 700, y: 488),
        end: CGPoint(x: 924, y: 412)
    )

    // 7. Central DirectX-to-Metal 3D Geometric Hexagonal Prism
    let pTop = CGPoint(x: 512, y: 816)
    let pUL  = CGPoint(x: 274, y: 664)
    let pLL  = CGPoint(x: 274, y: 360)
    let pBot = CGPoint(x: 512, y: 208)
    let pLR  = CGPoint(x: 750, y: 360)
    let pUR  = CGPoint(x: 750, y: 664)
    let pCtr = CGPoint(x: 512, y: 512)

    let prismOuter = makePolygon([pTop, pUL, pLL, pBot, pLR, pUR])

    // Prism drop shadow onto obsidian die
    if pixelSize >= 32 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -14),
            blur: 32,
            color: cgColor(0.0, 0.0, 0.0, 0.68)
        )
        ctx.setFillColor(cgColor(0.06, 0.08, 0.14, 1.0))
        ctx.addPath(prismOuter)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Six precision-cut prism facets meeting at center
    // Top-Left Facet: Electric Cyan -> Azure
    fillPolygonGradient(
        ctx,
        points: [pTop, pUL, pCtr],
        gradient: makeGradient([
            (0.0, cgColor(0.34, 0.88, 0.98, 0.96)),
            (1.0, cgColor(0.14, 0.48, 0.88, 0.92)),
        ]),
        start: pTop,
        end: pUL
    )

    // Mid-Left Facet: Emerald-Teal -> Deep Cobalt
    fillPolygonGradient(
        ctx,
        points: [pUL, pLL, pCtr],
        gradient: makeGradient([
            (0.0, cgColor(0.08, 0.74, 0.72, 0.94)),
            (1.0, cgColor(0.10, 0.28, 0.64, 0.94)),
        ]),
        start: pUL,
        end: pLL
    )

    // Bottom-Left Facet: Sapphire -> Midnight Indigo
    fillPolygonGradient(
        ctx,
        points: [pLL, pBot, pCtr],
        gradient: makeGradient([
            (0.0, cgColor(0.14, 0.34, 0.76, 0.95)),
            (1.0, cgColor(0.16, 0.14, 0.44, 0.96)),
        ]),
        start: pLL,
        end: pBot
    )

    // Top-Right Facet: Luminous Violet -> Metal Magenta
    fillPolygonGradient(
        ctx,
        points: [pTop, pCtr, pUR],
        gradient: makeGradient([
            (0.0, cgColor(0.68, 0.52, 1.00, 0.96)),
            (1.0, cgColor(0.84, 0.24, 0.78, 0.93)),
        ]),
        start: pTop,
        end: pUR
    )

    // Mid-Right Facet: Vivid Magenta -> Coral-Crimson
    fillPolygonGradient(
        ctx,
        points: [pUR, pCtr, pLR],
        gradient: makeGradient([
            (0.0, cgColor(0.88, 0.26, 0.74, 0.94)),
            (1.0, cgColor(0.94, 0.34, 0.30, 0.92)),
        ]),
        start: pUR,
        end: pLR
    )

    // Bottom-Right Facet: Deep Violet -> Warm Amber-Plum
    fillPolygonGradient(
        ctx,
        points: [pLR, pCtr, pBot],
        gradient: makeGradient([
            (0.0, cgColor(0.76, 0.28, 0.48, 0.94)),
            (1.0, cgColor(0.28, 0.14, 0.50, 0.96)),
        ]),
        start: pLR,
        end: pBot
    )

    // Facet specular ridge lines
    ctx.saveGState()
    ctx.setStrokeColor(cgColor(1.0, 1.0, 1.0, 0.38))
    ctx.setLineWidth(pixelSize <= 32 ? 10.0 : 4.5)
    ctx.setLineJoin(.round)
    for v in [pTop, pUL, pLL, pBot, pLR, pUR] {
        ctx.move(to: pCtr)
        ctx.addLine(to: v)
    }
    ctx.strokePath()

    ctx.setStrokeColor(cgColor(1.0, 1.0, 1.0, 0.58))
    ctx.setLineWidth(pixelSize <= 32 ? 12.0 : 5.5)
    ctx.addPath(prismOuter)
    ctx.strokePath()
    ctx.restoreGState()

    // 8. Apple Silicon Core Plate + 'DM' Metallic Emblem
    let corePlateRect = CGRect(x: 360, y: 408, width: 304, height: 208)
    let corePlatePath = CGPath(
        roundedRect: corePlateRect,
        cornerWidth: 46,
        cornerHeight: 46,
        transform: nil
    )

    ctx.saveGState()
    if pixelSize >= 32 {
        ctx.setShadow(
            offset: CGSize(width: 0, height: -8),
            blur: 18,
            color: cgColor(0.0, 0.0, 0.0, 0.65)
        )
    }
    ctx.setFillColor(cgColor(0.06, 0.08, 0.13, 0.94))
    ctx.addPath(corePlatePath)
    ctx.fillPath()
    ctx.restoreGState()

    // Core plate anodized gradient fill & metallic rim
    ctx.saveGState()
    ctx.addPath(corePlatePath)
    ctx.clip()
    let plateGrad = makeGradient([
        (0.0, cgColor(0.16, 0.20, 0.29, 0.96)),
        (1.0, cgColor(0.06, 0.08, 0.12, 0.98)),
    ])
    ctx.drawLinearGradient(
        plateGrad,
        start: CGPoint(x: 512, y: 616),
        end: CGPoint(x: 512, y: 408),
        options: []
    )
    ctx.restoreGState()

    ctx.saveGState()
    ctx.setStrokeColor(cgColor(0.82, 0.90, 1.0, 0.48))
    ctx.setLineWidth(pixelSize <= 32 ? 10.0 : 4.5)
    ctx.addPath(corePlatePath)
    ctx.strokePath()
    ctx.restoreGState()

    // Render crisp geometric 'DM' emblem at >= 32px; render luminous diamond core at 16px
    if pixelSize >= 32 {
        let dmPath = makeDMEmblemPath()

        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -4),
            blur: 8,
            color: cgColor(0.0, 0.0, 0.0, 0.65)
        )
        ctx.setFillColor(cgColor(0.92, 0.96, 1.0, 1.0))
        ctx.addPath(dmPath)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(dmPath)
        ctx.clip(using: .evenOdd)
        let metalTextGrad = makeGradient([
            (0.00, cgColor(1.00, 1.00, 1.00, 1.0)), // Pure specular silver
            (0.48, cgColor(0.86, 0.91, 0.98, 1.0)), // Brushed platinum
            (0.55, cgColor(0.66, 0.75, 0.88, 1.0)), // Machined horizon
            (1.00, cgColor(0.84, 0.90, 0.98, 1.0)), // Bottom rim bounce
        ])
        ctx.drawLinearGradient(
            metalTextGrad,
            start: CGPoint(x: 512, y: 574),
            end: CGPoint(x: 512, y: 450),
            options: []
        )
        ctx.restoreGState()
    } else {
        // Ultra-crisp glowing core gem at 16x16 so sub-pixel stems stay sharp
        let miniCore = makePolygon([
            CGPoint(x: 512, y: 572),
            CGPoint(x: 444, y: 512),
            CGPoint(x: 512, y: 452),
            CGPoint(x: 580, y: 512),
        ])
        fillPolygonGradient(
            ctx,
            points: [
                CGPoint(x: 512, y: 572),
                CGPoint(x: 444, y: 512),
                CGPoint(x: 512, y: 452),
                CGPoint(x: 580, y: 512),
            ],
            gradient: makeGradient([
                (0.0, cgColor(0.96, 0.98, 1.0, 1.0)),
                (1.0, cgColor(0.62, 0.84, 1.0, 1.0)),
            ]),
            start: CGPoint(x: 512, y: 572),
            end: CGPoint(x: 512, y: 452)
        )
        ctx.addPath(miniCore)
        ctx.setStrokeColor(cgColor(1.0, 1.0, 1.0, 0.85))
        ctx.setLineWidth(16.0)
        ctx.strokePath()
    }

    ctx.restoreGState() // End squircle interior clip

    // 9. Outer squircle anodized bevel highlight
    let innerRimRect = squircleRect.insetBy(dx: 3.0, dy: 3.0)
    let innerRimPath = CGPath(
        roundedRect: innerRimRect,
        cornerWidth: cornerRadius - 3.0,
        cornerHeight: cornerRadius - 3.0,
        transform: nil
    )
    ctx.saveGState()
    ctx.addPath(innerRimPath)
    ctx.setLineWidth(pixelSize <= 32 ? 12.0 : 5.0)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    let rimGrad = makeGradient([
        (0.00, cgColor(0.88, 0.94, 1.00, 0.42)),
        (0.50, cgColor(0.32, 0.48, 0.78, 0.14)),
        (1.00, cgColor(0.68, 0.34, 0.92, 0.28)),
    ])
    ctx.drawLinearGradient(
        rimGrad,
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )
    ctx.restoreGState()

    ctx.restoreGState()
}

func renderIconPNG(spec: IconSpec, to outputURL: URL) throws {
    let px = spec.pixelSize
    guard let cgCtx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: px * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "DirectMetalIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGContext for \(px)x\(px)"])
    }

    drawDirectMetalIcon(in: cgCtx, pixelSize: px)

    guard let cgImage = cgCtx.makeImage() else {
        throw NSError(domain: "DirectMetalIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to snapshot CGImage for \(px)x\(px)"])
    }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: spec.pointSize, height: spec.pointSize)

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "DirectMetalIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG for \(px)x\(px)"])
    }
    try pngData.write(to: outputURL, options: .atomic)
}

func main() throws {
    let fm = FileManager.default
    let scriptURL = URL(fileURLWithPath: #filePath).standardizedFileURL
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    let defaultOutput = repoRoot.appendingPathComponent("app/DirectMetalApp/AppIcon.icns")

    let outputURL: URL
    if CommandLine.arguments.count >= 2 {
        outputURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    } else {
        outputURL = defaultOutput
    }

    let tempIconset = fm.temporaryDirectory.appendingPathComponent("DirectMetal_\(UUID().uuidString).iconset", isDirectory: true)
    try fm.createDirectory(at: tempIconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempIconset) }

    for spec in iconSpecs {
        let pngURL = tempIconset.appendingPathComponent(spec.filename)
        try renderIconPNG(spec: spec, to: pngURL)
    }

    try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    proc.arguments = ["-c", "icns", "-o", outputURL.path, tempIconset.path]
    let errPipe = Pipe()
    proc.standardError = errPipe
    try proc.run()
    proc.waitUntilExit()

    if proc.terminationStatus != 0 {
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let errMsg = String(data: errData, encoding: .utf8) ?? "iconutil exited with status \(proc.terminationStatus)"
        throw NSError(domain: "DirectMetalIcon", code: Int(proc.terminationStatus), userInfo: [NSLocalizedDescriptionKey: errMsg])
    }

    let attrs = try fm.attributesOfItem(atPath: outputURL.path)
    let sizeBytes = (attrs[.size] as? NSNumber)?.intValue ?? 0
    print("[DirectMetal] Generated \(outputURL.path) (\(sizeBytes) bytes, \(iconSpecs.count) iconset representations: 16..1024px)")
}

do {
    try main()
} catch {
    fputs("[DirectMetal] Icon generation failed: \(error.localizedDescription)\n", stderr)
    Foundation.exit(1)
}
