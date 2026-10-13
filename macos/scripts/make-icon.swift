// Builds every app icon from the master artwork at public/lidless-icon.png:
//   Resources/AppIcon.icns     Finder, Dock, notifications, About panel
//   Resources/AppIcon-1024.png
//   Resources/LidlessMark.png  in-app mark (panel header)
// Usage (from macos/): swift scripts/make-icon.swift
//
// The artwork is cropped to its visible shape and placed on Apple's macOS icon
// grid: an 824 pt body centred on a 1024 canvas, with the standard soft shadow.
import AppKit
import CoreGraphics

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let source = cwd.appendingPathComponent("../public/lidless-icon.png").standardized
guard let data = try? Data(contentsOf: source),
      let rep = NSBitmapImageRep(data: data),
      let master = rep.cgImage else {
    fatalError("Cannot read \(source.path)")
}

/// Bounding box of pixels that are clearly part of the icon body.
func opaqueBounds(_ rep: NSBitmapImageRep) -> CGRect {
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}

let crop = master.cropping(to: opaqueBounds(rep))!

func render(size: Int, onGrid: Bool) -> Data {
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: out)!.cgContext
    ctx.interpolationQuality = .high
    let s = CGFloat(size)
    let body = onGrid
        ? CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
        : CGRect(x: 0, y: 0, width: s, height: s)
    if onGrid {
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 10 / 1024), blur: s * 24 / 1024,
                      color: CGColor(gray: 0, alpha: 0.3))
    }
    ctx.draw(crop, in: body)
    return out.representation(using: .png, properties: [:])!
}

let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base, onGrid: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2, onGrid: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = cwd.appendingPathComponent("Resources")
try render(size: 1024, onGrid: true).write(to: resources.appendingPathComponent("AppIcon-1024.png"))
// The in-app mark fills its frame (no grid margin), so it lines up with text.
try render(size: 128, onGrid: false).write(to: resources.appendingPathComponent("LidlessMark.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns, AppIcon-1024.png and LidlessMark.png from public/lidless-icon.png")
