import AppKit
import SwiftUI

// 运行 ./generate-icon.sh；复用应用内 TarsFigure，避免图标与桌宠外形漂移。
private struct TarsAppIcon: View {
    let edge: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: edge * 0.195, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: "303C48")!, Color(hex: "0B1016")!],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: edge * 0.875, height: edge * 0.875)
                .overlay {
                    RoundedRectangle(cornerRadius: edge * 0.195, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.025)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing),
                                      lineWidth: max(0.5, edge * 0.0025))
                        .frame(width: edge * 0.875, height: edge * 0.875)
                }
                .shadow(color: .black.opacity(0.32), radius: edge * 0.016, y: edge * 0.008)

            Ellipse()
                .fill(Color(hex: "62BDE8")!.opacity(0.12))
                .frame(width: edge * 0.43, height: edge * 0.57)
                .blur(radius: edge * 0.055)

            TarsFigure(pose: .rest, height: edge * 0.74, isWalking: false, time: 0)
                .offset(y: -edge * 0.012)
                .shadow(color: .black.opacity(0.45), radius: edge * 0.012, x: edge * 0.005, y: edge * 0.008)
        }
        .frame(width: edge, height: edge)
    }
}

@main
@MainActor
private struct IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "TarsIcon", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "用法：generate-icon <项目目录>"])
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let iconset = root.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let master = try png(edge: 1024)
        try master.write(to: root.appendingPathComponent("AppIcon-1024.png"), options: .atomic)
        try master.write(to: root.appendingPathComponent("docs/app-icon.png"), options: .atomic)

        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try png(edge: points * scale).write(to: iconset.appendingPathComponent(name), options: .atomic)
            }
        }
        print("已生成 TARS 图标：1024 PNG、文档预览、10 个 iconset 尺寸")
    }

    private static func png(edge: Int) throws -> Data {
        let renderer = ImageRenderer(content: TarsAppIcon(edge: CGFloat(edge)))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TarsIcon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "图标渲染失败：\(edge)px"])
        }
        return data
    }
}
