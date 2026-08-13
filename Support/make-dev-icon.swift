// Builds AppIcon-dev.icns from AppIcon.icns by stamping every size with an
// amber band, so a local development build is never mistaken for the signed one
// people download. Run from the repo root:
//
//     ./Support/make-dev-icon.sh
//
// The band, not the word, is what does the work: privacy settings, Activity
// Monitor and the Force Quit list draw the icon at 16–32 points, where any text
// is unreadable. "DEV" is added only at sizes where it can actually be read.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 2 else {
    FileHandle.standardError.write("usage: make-dev-icon <in.iconset> <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let input = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2])

let amber = NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.18, alpha: 1)
let ink = NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.05, alpha: 1)

let files = try FileManager.default.contentsOfDirectory(atPath: input.path)
    .filter { $0.hasSuffix(".png") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

for name in files.sorted() {
    guard let source = NSImage(contentsOf: input.appendingPathComponent(name)),
          let sourceRep = source.representations.first else { continue }
    let width = CGFloat(sourceRep.pixelsWide)
    let height = CGFloat(sourceRep.pixelsHigh)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let full = NSRect(x: 0, y: 0, width: width, height: height)
    source.draw(in: full, from: .zero, operation: .copy, fraction: 1)

    // Sits inside the icon's rounded corners rather than spanning the full
    // width, so the shape still reads as the same app.
    let inset = width * 0.09
    let bandHeight = height * 0.26
    let band = NSRect(x: inset, y: height * 0.055,
                      width: width - inset * 2, height: bandHeight)
    let radius = bandHeight * 0.22
    amber.setFill()
    NSBezierPath(roundedRect: band, xRadius: radius, yRadius: radius).fill()

    // 128 pixels is about where three letters stay legible.
    if width >= 128 {
        let text = "DEV"
        let size = bandHeight * 0.62
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: .heavy),
            .foregroundColor: ink,
            .kern: size * 0.08,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let measured = string.size()
        string.draw(at: NSPoint(x: band.midX - measured.width / 2,
                                y: band.midY - measured.height / 2))
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else { continue }
    try data.write(to: output.appendingPathComponent(name))
    print("  \(name)  \(Int(width))x\(Int(height))")
}
