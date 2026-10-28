// DMG 窗口的背景图：两个图标之间一支箭头，下面一行「拖进应用程序」的提示。
// 用法：swift scripts/dmg/background.swift <输出目录>，写出 background.png 和 background@2x.png，
// dmgbuild 看到同目录的 @2x 会用 tiffutil 合成一张 Finder 认得的双分辨率 .background.tiff。
// 尺寸和图标位置要和 settings.py 对上：窗口 640×400，两个图标中心在 (160, 180) 和 (480, 180)（从左上角量）；
// 标题栏会挤掉图下面 28 点左右，字放在 370 点以内。
import AppKit

let width: CGFloat = 640, height: CGFloat = 400
let iconY: CGFloat = 180
let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

func draw() {
    color(0xF5F5F7).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // 箭头：AppKit 的 y 从下往上，换算一下
    let y = height - iconY
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 252, y: y))
    arrow.line(to: NSPoint(x: 384, y: y))
    arrow.move(to: NSPoint(x: 370, y: y + 13))
    arrow.line(to: NSPoint(x: 386, y: y))
    arrow.line(to: NSPoint(x: 370, y: y - 13))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    color(0x5460D2).setStroke()
    arrow.stroke()

    func line(_ text: String, size: CGFloat, weight: NSFont.Weight, hex: UInt32, centerY: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color(hex),
        ]
        let s = NSAttributedString(string: text, attributes: attrs)
        let b = s.size()
        s.draw(at: NSPoint(x: (width - b.width) / 2, y: height - centerY - b.height / 2))
    }
    line("把 GetNewWord 拖进「应用程序」，再从那里打开", size: 14, weight: .medium, hex: 0x18181C, centerY: 312)
    line("Drag GetNewWord to Applications, then open it from there", size: 12, weight: .regular, hex: 0x6B6B71, centerY: 335)
}

for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
