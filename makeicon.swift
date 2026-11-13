// makeicon.swift <source-image> <out-1024.png>
// Вписывает картинку в нативный macOS-squircle (поля + скруглённые прозрачные углы).
import Cocoa

let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: makeicon <src> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let canvas: CGFloat = 1024
let margin: CGFloat = 100            // прозрачные поля
let side = canvas - margin * 2       // 824 — размер плитки
let radius = side * 0.2237           // радиус скругления Apple-грид

let out = NSImage(size: NSSize(width: canvas, height: canvas))
out.lockFocus()
let ctx = NSGraphicsContext.current!
ctx.imageInterpolation = .high

let tile = NSRect(x: margin, y: margin, width: side, height: side)
let path = NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius)
path.addClip()

// aspect-fill исходника внутрь плитки
let s = src.size
let scale = max(side / s.width, side / s.height)
let dw = s.width * scale, dh = s.height * scale
let dst = NSRect(x: tile.midX - dw / 2, y: tile.midY - dh / 2, width: dw, height: dh)
src.draw(in: dst, from: .zero, operation: .copy, fraction: 1.0)

out.unlockFocus()

guard let tiff = out.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(2) }
try! png.write(to: URL(fileURLWithPath: args[2]))
