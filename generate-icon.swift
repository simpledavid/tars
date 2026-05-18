#!/usr/bin/env swift
import AppKit
import CoreGraphics

// HermesPet App 图标生成器
// 输出 1024×1024 PNG → 后续由 make-icon.sh 切 .icns

let SIZE: CGFloat = 1024

// 颜色（柔和三段式，明度接近避免视觉断层）
let hermesBlue  = NSColor(srgbRed:  91/255, green: 141/255, blue: 239/255, alpha: 1)  // #5B8DEF
let claudeOrange = NSColor(srgbRed: 215/255, green: 119/255, blue:  87/255, alpha: 1)  // #D77757
let codexGreen  = NSColor(srgbRed:  88/255, green: 182/255, blue: 143/255, alpha: 1)  // #58B68F

func generateIcon() -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(SIZE), pixelsHigh: Int(SIZE),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    // 1) macOS Big Sur 圆角方形剪裁（squircle 半径 ≈ 22.37%）
    let cornerRadius: CGFloat = SIZE * 0.2237
    let outer = CGRect(x: 0, y: 0, width: SIZE, height: SIZE)
    let clipPath = CGPath(roundedRect: outer, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    cg.addPath(clipPath); cg.clip()

    // 2) 三段背景（CG 坐标 y 朝上：0 是底）
    let third = SIZE / 3.0

    cg.setFillColor(codexGreen.cgColor)     // 下：Codex 绿
    cg.fill(CGRect(x: 0, y: 0,        width: SIZE, height: third))

    cg.setFillColor(claudeOrange.cgColor)   // 中：Claude 橘
    cg.fill(CGRect(x: 0, y: third,    width: SIZE, height: third))

    cg.setFillColor(hermesBlue.cgColor)     // 上：Hermes 蓝
    cg.fill(CGRect(x: 0, y: third*2,  width: SIZE, height: third))

    // 3) 段间分隔：极细白色高光（1.5pt）—— 让交界处显得"刻"出来
    cg.setFillColor(NSColor.white.withAlphaComponent(0.18).cgColor)
    cg.fill(CGRect(x: 0, y: third - 0.75,    width: SIZE, height: 1.5))
    cg.fill(CGRect(x: 0, y: third*2 - 0.75,  width: SIZE, height: 1.5))

    // 4) 中央白色小宠物（占图 ~40%）
    let petR: CGFloat = 220
    let cx: CGFloat = SIZE / 2
    let cy: CGFloat = SIZE / 2

    // 4a) 头部主圆 —— 偏椭圆，更"萌"
    let headRect = CGRect(x: cx - petR, y: cy - petR * 0.92, width: petR*2, height: petR*1.84)
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: headRect)
    cg.setShadow(offset: .zero, blur: 0, color: nil)  // 关阴影避免影响后面

    // 4b) 两只小尖耳朵（三角形）—— 更像桌宠
    let earH: CGFloat = 90
    let earW: CGFloat = 80
    let earOffsetX: CGFloat = 110
    let earBaseY: CGFloat = cy + petR * 0.55
    cg.setFillColor(NSColor.white.cgColor)
    // 左耳
    cg.beginPath()
    cg.move(to: CGPoint(x: cx - earOffsetX - earW/2, y: earBaseY))
    cg.addLine(to: CGPoint(x: cx - earOffsetX + earW/2, y: earBaseY))
    cg.addLine(to: CGPoint(x: cx - earOffsetX, y: earBaseY + earH))
    cg.closePath()
    cg.fillPath()
    // 右耳
    cg.beginPath()
    cg.move(to: CGPoint(x: cx + earOffsetX - earW/2, y: earBaseY))
    cg.addLine(to: CGPoint(x: cx + earOffsetX + earW/2, y: earBaseY))
    cg.addLine(to: CGPoint(x: cx + earOffsetX, y: earBaseY + earH))
    cg.closePath()
    cg.fillPath()

    // 4c) 两只圆眼（大眼睛 + 高光）
    let eyeR: CGFloat = 30
    let eyeY: CGFloat = cy + 20
    let eyeOffsetX: CGFloat = 75
    cg.setFillColor(NSColor.black.cgColor)
    cg.fillEllipse(in: CGRect(x: cx - eyeOffsetX - eyeR, y: eyeY - eyeR, width: eyeR*2, height: eyeR*2))
    cg.fillEllipse(in: CGRect(x: cx + eyeOffsetX - eyeR, y: eyeY - eyeR, width: eyeR*2, height: eyeR*2))
    // 眼睛高光（小白点，让眼神有灵气）
    let hl: CGFloat = 10
    cg.setFillColor(NSColor.white.cgColor)
    cg.fillEllipse(in: CGRect(x: cx - eyeOffsetX + 8, y: eyeY + 6, width: hl, height: hl))
    cg.fillEllipse(in: CGRect(x: cx + eyeOffsetX + 8, y: eyeY + 6, width: hl, height: hl))

    // 4d) 弧形笑嘴（嘴角微翘）
    cg.setStrokeColor(NSColor.black.cgColor)
    cg.setLineWidth(11)
    cg.setLineCap(.round)
    cg.beginPath()
    let mouthCenter = CGPoint(x: cx, y: cy - 50)
    cg.addArc(center: mouthCenter, radius: 38, startAngle: .pi * 1.05, endAngle: .pi * 1.95, clockwise: false)
    cg.strokePath()

    // 4e) 两个粉色小腮红（点缀，增加可爱感）
    let blushR: CGFloat = 22
    let blushOffsetX: CGFloat = 130
    let blushY: CGFloat = cy - 30
    cg.setFillColor(NSColor(srgbRed: 1, green: 0.62, blue: 0.65, alpha: 0.55).cgColor)
    cg.fillEllipse(in: CGRect(x: cx - blushOffsetX - blushR, y: blushY - blushR/2, width: blushR*2, height: blushR))
    cg.fillEllipse(in: CGRect(x: cx + blushOffsetX - blushR, y: blushY - blushR/2, width: blushR*2, height: blushR))

    // 5) 顶部 ✨ sparkle（呼应"AI 桌宠"灵性 + 菜单栏图标 sparkle）
    let sparkY: CGFloat = SIZE - 170
    let sparkX: CGFloat = SIZE - 200
    drawSparkle(cg: cg, center: CGPoint(x: sparkX, y: sparkY), size: 70, color: NSColor.white.withAlphaComponent(0.88))
    // 小一点的副 sparkle
    drawSparkle(cg: cg, center: CGPoint(x: sparkX - 90, y: sparkY - 60), size: 30, color: NSColor.white.withAlphaComponent(0.7))

    // 6) 整体内描边（极细玻璃边）
    cg.addPath(CGPath(roundedRect: outer.insetBy(dx: 1, dy: 1),
                      cornerWidth: cornerRadius - 1, cornerHeight: cornerRadius - 1,
                      transform: nil))
    cg.setStrokeColor(NSColor.white.withAlphaComponent(0.12).cgColor)
    cg.setLineWidth(2)
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

/// 画一个四角星（sparkle）—— 类似 SF Symbol "sparkle"
func drawSparkle(cg: CGContext, center: CGPoint, size: CGFloat, color: NSColor) {
    cg.setFillColor(color.cgColor)
    let s = size
    let thin = s * 0.18  // 腰部细度
    cg.beginPath()
    cg.move(to: CGPoint(x: center.x, y: center.y + s))            // 上
    cg.addQuadCurve(to: CGPoint(x: center.x + s, y: center.y), control: CGPoint(x: center.x + thin, y: center.y + thin))  // 右
    cg.addQuadCurve(to: CGPoint(x: center.x, y: center.y - s), control: CGPoint(x: center.x + thin, y: center.y - thin))  // 下
    cg.addQuadCurve(to: CGPoint(x: center.x - s, y: center.y), control: CGPoint(x: center.x - thin, y: center.y - thin))  // 左
    cg.addQuadCurve(to: CGPoint(x: center.x, y: center.y + s), control: CGPoint(x: center.x - thin, y: center.y + thin))
    cg.closePath()
    cg.fillPath()
}

// 输出
let png = generateIcon()
let outPath = "/Users/mac01/Desktop/HermesPet/AppIcon-1024.png"
try png.write(to: URL(fileURLWithPath: outPath))
print("✅ 已生成 \(outPath)")
