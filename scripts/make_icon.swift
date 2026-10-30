#!/usr/bin/env swift
import AppKit

// 生成 AppIcon.icns：圆角方块渐变底 + 白色剪贴板图形。
// Xcode 26 的 swift 解释器会把脚本参数追加在 "--" 之后，需要先过滤驱动自身参数。
let rawArgs = CommandLine.arguments
let outputDir: String = {
    if let separator = rawArgs.firstIndex(of: "--"), separator + 1 < rawArgs.count {
        return rawArgs[separator + 1]
    }
    return "build/icon.iconset"
}()
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

func drawIcon(size: CGFloat) -> Data {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return Data()
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.055
    let body = rect.insetBy(dx: inset, dy: inset)
    let radius = size * 0.22

    let colors = [
        NSColor(srgbRed: 0.49, green: 0.35, blue: 0.95, alpha: 1).cgColor,
        NSColor(srgbRed: 0.28, green: 0.55, blue: 0.98, alpha: 1).cgColor
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        let path = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        ctx.resetClip()
    }

    // 剪贴板外形
    let clipboard = body.insetBy(dx: size * 0.20, dy: size * 0.17)
    let sheet = CGRect(x: clipboard.minX, y: clipboard.minY, width: clipboard.width, height: clipboard.height * 0.86)
    let sheetPath = CGPath(roundedRect: sheet, cornerWidth: size * 0.055, cornerHeight: size * 0.055, transform: nil)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.96).cgColor)
    ctx.addPath(sheetPath)
    ctx.fillPath()

    // 顶部夹子
    let clip = CGRect(x: sheet.midX - size * 0.10, y: sheet.maxY - size * 0.045, width: size * 0.20, height: size * 0.085)
    let clipPath = CGPath(roundedRect: clip, cornerWidth: size * 0.032, cornerHeight: size * 0.032, transform: nil)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(clipPath)
    ctx.fillPath()

    // 三条内容线
    ctx.setFillColor(NSColor(srgbRed: 0.35, green: 0.37, blue: 0.65, alpha: 0.55).cgColor)
    for index in 0..<3 {
        let width = sheet.width * (index == 2 ? 0.52 : 0.68)
        let line = CGRect(x: sheet.minX + size * 0.048, y: sheet.maxY - size * 0.19 - CGFloat(index) * size * 0.085,
                          width: width, height: size * 0.042)
        let path = CGPath(roundedRect: line, cornerWidth: line.height / 2, cornerHeight: line.height / 2, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()
    }

    image.unlockFocus()

    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return Data() }
    return png
}

let variants: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")
]

for (size, name) in variants {
    let data = drawIcon(size: CGFloat(size))
    let url = URL(fileURLWithPath: outputDir).appendingPathComponent(name)
    try? data.write(to: url)
}
