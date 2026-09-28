//
//  Tools/make_icon.swift
//  Transmute
//
//  Draws the app icon and writes every size the asset catalog asks for.
//  Code rather than a drawing file, so the icon can be changed by editing
//  numbers and rerunning, without a graphics program. (DropMaster's icon
//  tool, with a new picture.)
//
//  The picture: a kick drum's waveform - fast cycles at the start, slower
//  and smaller ones as the pitch falls and the hit decays - that begins as
//  loose, scattered sample dots (the recording) and becomes one clean,
//  bright line (the synth). The hit turning into its model, which is the
//  one thing the app does.
//
//  Usage: swift Tools/make_icon.swift
//

import AppKit

let folder = URL(fileURLWithPath: "Transmute/Assets.xcassets/AppIcon.appiconset")

/// The kick: pitch 6 → 2.6 cycles per unit width, amplitude decaying.
func kick(_ u: Double) -> Double {
    let tau = 0.2
    let phase = 2 * Double.pi * (2.6 * u + (6.0 - 2.6) * tau * (1 - exp(-u / tau)))
    let envelope = min(u / 0.02, 1) * exp(-u / 0.7)
    return envelope * sin(phase)
}

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // The macOS tile: 824 of 1024 with a margin, corner radius ~185.
    let tile = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = CGPath(roundedRect: tile, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
    c.saveGState()
    c.addPath(path); c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(red: 0.16, green: 0.11, blue: 0.20, alpha: 1),
                                       CGColor(red: 0.05, green: 0.04, blue: 0.08, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    let left = tile.minX + 90 * s, width = tile.width - 180 * s
    let mid = tile.midY, height = 250 * s
    func point(_ u: Double) -> CGPoint {
        CGPoint(x: left + CGFloat(u) * width, y: mid + CGFloat(kick(u)) * height)
    }

    // The recording: dots on the curve, pushed off it a little, fewer
    // and dimmer the further left - up to the handover at 0.36.
    var seed: UInt64 = 0x7A45_C0DE
    func jitter() -> CGFloat {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat(Double(seed >> 33) / Double(1 << 31) - 1)
    }
    let handover = 0.36
    let dots = 34
    for i in 0..<dots {
        let u = handover * Double(i) / Double(dots - 1)
        var p = point(u)
        p.y += jitter() * 22 * s * CGFloat(1 - u / handover)
        let r = (11 + 4 * CGFloat(u / handover)) * s
        let alpha = 0.35 + 0.55 * u / handover
        c.setFillColor(CGColor(red: 0.95, green: 0.62, blue: 0.40, alpha: alpha))
        c.fillEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }

    // The synth: one continuous line from the handover on, with a glow.
    let line = CGMutablePath()
    let steps = 400
    for i in 0...steps {
        let u = handover + (1 - handover) * Double(i) / Double(steps)
        if i == 0 { line.move(to: point(u)) } else { line.addLine(to: point(u)) }
    }
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.addPath(line)
    c.setStrokeColor(CGColor(red: 1.0, green: 0.45, blue: 0.70, alpha: 0.25))
    c.setLineWidth(46 * s)
    c.strokePath()
    c.addPath(line)
    c.setStrokeColor(CGColor(red: 1.0, green: 0.55, blue: 0.75, alpha: 1))
    c.setLineWidth(20 * s)
    c.strokePath()
    c.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let rep = draw(CGFloat(points * scale))
        let url = folder.appendingPathComponent("icon_\(points)x\(points)@\(scale)x.png")
        try! rep.representation(using: .png, properties: [:])!.write(to: url)
    }
}
print("icons written to \(folder.path)")
