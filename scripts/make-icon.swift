import AppKit

guard CommandLine.arguments.count > 1 else {
    fputs("usage: make-icon.swift output.png\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
    NSColor(srgbRed: 0.145, green: 0.455, blue: 0.965, alpha: 1).setFill()
    rect.fill()
    guard let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil) else {
        return true
    }
    let iconSide: CGFloat = 620
    let iconRect = NSRect(x: (side - iconSide) / 2, y: (side - iconSide) / 2 - 12, width: iconSide, height: iconSide)
    let tinted = NSImage(size: iconRect.size, flipped: false) { drawRect in
        NSColor.white.setFill()
        drawRect.fill()
        symbol.draw(in: drawRect, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
    tinted.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
    return true
}

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fputs("icon render failed\n", stderr)
    exit(1)
}

do {
    try png.write(to: output)
} catch {
    fputs("icon write failed: \(error)\n", stderr)
    exit(1)
}
