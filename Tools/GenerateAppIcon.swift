import AppKit
import CoreGraphics
import ImageIO
import Foundation

// NotchMate app icon: the whole squircle is a MacBook-style display — dark bezel
// frame, purple gradient screen, and a wide notch (65 % of the icon width) hanging
// from the top with the Obsidian logo inside (Tools/obsidian-logo.svg).
// Usage: swift GenerateAppIcon.swift [output.png]

let S = 1024
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
// top-left origin
ctx.translateBy(x: 0, y: CGFloat(S)); ctx.scaleBy(x: 1, y: -1)

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r/255, green: g/255, blue: b/255, alpha: a)
}

// Same silhouette as the app's NotchShape.
func notchPath(_ r: CGRect, topRadius: CGFloat, bottomRadius: CGFloat, topWidthFactor: CGFloat = 1.9) -> CGPath {
    let p = CGMutablePath()
    let topH = min(topRadius, r.height)
    let topW = min(topH * topWidthFactor, r.width/2 - 1)
    let botR = min(bottomRadius, r.height - topH, (r.width - 2*topW)/2)
    p.move(to: CGPoint(x: r.minX, y: r.minY))
    p.addQuadCurve(to: CGPoint(x: r.minX+topW, y: r.minY+topH), control: CGPoint(x: r.minX+topW, y: r.minY))
    p.addLine(to: CGPoint(x: r.minX+topW, y: r.maxY-botR))
    p.addQuadCurve(to: CGPoint(x: r.minX+topW+botR, y: r.maxY), control: CGPoint(x: r.minX+topW, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX-topW-botR, y: r.maxY))
    p.addQuadCurve(to: CGPoint(x: r.maxX-topW, y: r.maxY-botR), control: CGPoint(x: r.maxX-topW, y: r.maxY))
    p.addLine(to: CGPoint(x: r.maxX-topW, y: r.minY+topH))
    p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX-topW, y: r.minY))
    p.closeSubpath()
    return p
}

// ---- Bezel squircle (nearly edge-to-edge) ----
let outerInset: CGFloat = 34
let outer = CGRect(x: outerInset, y: outerInset, width: CGFloat(S) - 2*outerInset, height: CGFloat(S) - 2*outerInset)
let outerRadius = outer.width * 0.2237
let bezel = CGPath(roundedRect: outer, cornerWidth: outerRadius, cornerHeight: outerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(bezel); ctx.clip()
let bezelGrad = CGGradient(colorsSpace: cs, colors: [rgb(58, 56, 62), rgb(16, 15, 18)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bezelGrad, start: CGPoint(x: outer.midX, y: outer.minY), end: CGPoint(x: outer.midX, y: outer.maxY), options: [])
ctx.restoreGState()

// ---- Screen panel ----
let bezelW: CGFloat = 36
let screen = outer.insetBy(dx: bezelW, dy: bezelW)
let screenRadius = outerRadius - bezelW
let panel = CGPath(roundedRect: screen, cornerWidth: screenRadius, cornerHeight: screenRadius, transform: nil)

ctx.saveGState()
ctx.addPath(panel); ctx.clip()

// deep dark violet melting into a glowing purple horizon
let screenGrad = CGGradient(colorsSpace: cs, colors: [
    rgb(20, 15, 32), rgb(48, 30, 82), rgb(122, 78, 200), rgb(186, 148, 255)
] as CFArray, locations: [0, 0.45, 0.82, 1])!
ctx.drawLinearGradient(screenGrad, start: CGPoint(x: screen.midX, y: screen.minY), end: CGPoint(x: screen.midX, y: screen.maxY), options: [])

let bloom = CGGradient(colorsSpace: cs, colors: [rgb(178, 128, 255, 0.5), rgb(178, 128, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: CGPoint(x: screen.midX, y: screen.maxY), startRadius: 0,
                       endCenter: CGPoint(x: screen.midX, y: screen.maxY), endRadius: screen.width * 0.7, options: [])

// ---- Notch: 65 % of the icon width ----
let nW: CGFloat = CGFloat(S) * 0.65
let nH: CGFloat = 120
let nRect = CGRect(x: screen.midX - nW/2, y: screen.minY, width: nW, height: nH)
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 26, color: rgb(0, 0, 0, 0.45))
ctx.addPath(notchPath(nRect, topRadius: 30, bottomRadius: 42))
ctx.setFillColor(rgb(3, 3, 5))
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: CGColor(gray: 0, alpha: 0))

// ---- Obsidian logo in the notch ----
let logoURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("obsidian-logo.svg")
guard let logo = NSImage(contentsOf: logoURL) else { fatalError("obsidian-logo.svg not found next to the script") }
let logoH: CGFloat = 100
let logoW = logoH * logo.size.width / logo.size.height
let logoRect = CGRect(x: nRect.midX - logoW/2, y: nRect.minY + (nH - logoH)/2 - 4, width: logoW, height: logoH)
ctx.saveGState()
let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ns
logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1,
          respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
NSGraphicsContext.restoreGraphicsState()
ctx.restoreGState()

// subtle top sheen on the glass
let sheen = CGGradient(colorsSpace: cs, colors: [rgb(255, 255, 255, 0.10), rgb(255, 255, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: screen.midX, y: screen.minY), end: CGPoint(x: screen.midX, y: screen.minY + 200), options: [])

ctx.restoreGState()

// bezel inner edge highlight
ctx.saveGState()
ctx.addPath(panel)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.setLineWidth(3)
ctx.strokePath()
ctx.restoreGState()

// ---- write PNG ----
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
guard let img = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("write failed") }
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
