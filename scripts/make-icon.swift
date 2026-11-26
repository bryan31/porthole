// Renders the Porthole app icon from the flat SVG artwork in design/logo/:
// a white porthole frame on coral, looking out at sky, sea and a rising sun.
// (Edit the artwork in design/logo/logo.py, which writes the SVGs.)
//
// Usage:
//   swift scripts/make-icon.swift <output.png>        one 1024×1024 PNG
//   swift scripts/make-icon.swift <AppIcon.iconset>   every size iconutil needs; the 16 and 32 px
//                                                      renditions use porthole-small.svg so they stay crisp
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let artwork = root.appendingPathComponent("design/logo/porthole.svg")
let artworkSmall = root.appendingPathComponent("design/logo/porthole-small.svg")

func load(_ url: URL) -> NSImage {
    guard let image = NSImage(contentsOf: url) else {
        FileHandle.standardError.write("Could not read \(url.path). Run python3 design/logo/logo.py first.\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

let full = load(artwork)
let small = load(artworkSmall)

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    (px <= 32 ? small : full).draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
if output.hasSuffix(".iconset") {
    try! FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
    for size in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = size * scale
            let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
            write(render(px: px), to: "\(output)/\(name)")
        }
    }
    print("wrote \(output)")
} else {
    write(render(px: 1024), to: output)
    print("wrote \(output)")
}
