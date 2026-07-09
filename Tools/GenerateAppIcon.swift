#!/usr/bin/swift
//
//  GenerateAppIcon.swift — NotchMate
//  Zeichnet das App-Icon (1a „Waveform") als 1024×1024-PNG, rein CoreGraphics.
//  Aufruf:  swift Tools/GenerateAppIcon.swift [ausgabe.png]
//
//  Koordinaten: 1024er-Raster, Ursprung OBEN LINKS (Kontext wird geflippt),
//  identisch mit dem Design-Dokument.
//

import Foundation
import CoreGraphics
import ImageIO

// MARK: - Helfer

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [
        CGFloat((hex >> 16) & 0xFF) / 255,
        CGFloat((hex >> 8) & 0xFF) / 255,
        CGFloat(hex & 0xFF) / 255,
        alpha
    ])!
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: srgb,
               colors: stops.map { $0.1 } as CFArray,
               locations: stops.map { $0.0 })!
}

// MARK: - Konstanten (alles in 1024er-Koordinaten)

let size: CGFloat = 1024

// Bezel: abgerundeter Rahmen, Radius ≈ 22 % der Breite (System-Squircle maskiert zusätzlich)
let bezelRadius: CGFloat = 225

// Screen-Panel
let screenRect = CGRect(x: 88, y: 88, width: 848, height: 848)
let screenRadius: CGFloat = 120

// Notch: 666 px oben / 634 px unten × 134 px, Bodenradius 46, leicht trapezförmig
// (Pfad unten; Werte entsprechen dem SVG-Entwurf 1a)

// Waveform: 5 Kapseln, Breite 26, Raster 52, zentriert auf (512, 155), Eckradius 13
let barCorner: CGFloat = 13
let bars: [CGRect] = [
    CGRect(x: 395, y: 132, width: 26, height: 46),
    CGRect(x: 447, y: 116, width: 26, height: 78),
    CGRect(x: 499, y: 104, width: 26, height: 102),
    CGRect(x: 551, y: 123, width: 26, height: 64),
    CGRect(x: 603, y: 111, width: 26, height: 88),
]

// MARK: - Kontext (geflippt: Ursprung oben links)

let ctx = CGContext(data: nil,
                    width: Int(size), height: Int(size),
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: srgb,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

// MARK: - 1) Bezel (#3A383E oben → #100F12 unten)

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: size, height: size),
                   cornerWidth: bezelRadius, cornerHeight: bezelRadius, transform: nil))
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0x3A383E)), (1, color(0x100F12))]),
                       start: CGPoint(x: 512, y: 0),
                       end: CGPoint(x: 512, y: size), options: [])
ctx.restoreGState()

// MARK: - 2) Screen (#140F20 unten → #BA94FF oben) — Clip bleibt bis zum Ende aktiv

ctx.saveGState()
ctx.addPath(CGPath(roundedRect: screenRect,
                   cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil))
ctx.clip()
ctx.drawLinearGradient(gradient([
    (0.00, color(0x140F20)),
    (0.38, color(0x301E52)),
    (0.74, color(0x7A4EC8)),
    (1.00, color(0xBA94FF)),
]), start: CGPoint(x: 512, y: 936), end: CGPoint(x: 512, y: 88), options: [])

// MARK: - 3) Bloom: elliptischer Radialverlauf, Zentrum (512, 96), rx 450 / ry 265

ctx.saveGState()
ctx.translateBy(x: 512, y: 96)
ctx.scaleBy(x: 1, y: 265.0 / 450.0)
ctx.drawRadialGradient(gradient([
    (0.00, color(0xFFFCFF, 0.9)),
    (0.45, color(0xE9DBFF, 0.5)),
    (1.00, color(0xE9DBFF, 0.0)),
]), startCenter: .zero, startRadius: 0,
    endCenter: .zero, endRadius: 450, options: [])
ctx.restoreGState()

// MARK: - 4) Notch (#17151C → #0A090D)

let notch = CGMutablePath()
notch.move(to: CGPoint(x: 151, y: 88))
notch.addCurve(to: CGPoint(x: 184, y: 118),
               control1: CGPoint(x: 170, y: 88), control2: CGPoint(x: 181, y: 98))
notch.addLine(to: CGPoint(x: 193, y: 176))
notch.addQuadCurve(to: CGPoint(x: 242, y: 222), control: CGPoint(x: 196, y: 222))
notch.addLine(to: CGPoint(x: 782, y: 222))
notch.addQuadCurve(to: CGPoint(x: 831, y: 176), control: CGPoint(x: 828, y: 222))
notch.addLine(to: CGPoint(x: 840, y: 118))
notch.addCurve(to: CGPoint(x: 873, y: 88),
               control1: CGPoint(x: 843, y: 98), control2: CGPoint(x: 854, y: 88))
notch.closeSubpath()

ctx.saveGState()
ctx.addPath(notch)
ctx.clip()
ctx.drawLinearGradient(gradient([(0, color(0x17151C)), (1, color(0x0A090D))]),
                       start: CGPoint(x: 512, y: 88),
                       end: CGPoint(x: 512, y: 222), options: [])
ctx.restoreGState()

// MARK: - 5) Waveform-Balken — Pass 1: Glow (#A97BFF, Blur 20, 80 %)

let allBars = CGMutablePath()
for b in bars {
    allBars.addPath(CGPath(roundedRect: b, cornerWidth: barCorner, cornerHeight: barCorner, transform: nil))
}
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 20, color: color(0xA97BFF, 0.8))
ctx.addPath(allBars)
ctx.setFillColor(color(0xA97BFF))
ctx.fillPath()
ctx.restoreGState()

// MARK: - 5b) Waveform-Balken — Pass 2: Verlauf pro Balken (#F1E7FF oben → #C09AFF unten)

for b in bars {
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: b, cornerWidth: barCorner, cornerHeight: barCorner, transform: nil))
    ctx.clip()
    ctx.drawLinearGradient(gradient([(0, color(0xF1E7FF)), (1, color(0xC09AFF))]),
                           start: CGPoint(x: b.midX, y: b.minY),
                           end: CGPoint(x: b.midX, y: b.maxY), options: [])
    ctx.restoreGState()
}

ctx.restoreGState() // Screen-Clip

// MARK: - PNG schreiben

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon_1024.png"
let url = URL(fileURLWithPath: outPath) as CFURL
let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("✓ \(outPath) (1024×1024) geschrieben")
