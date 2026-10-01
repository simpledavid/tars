import SwiftUI
import AppKit

/// TARS 机器人信息屏与状态灯的调色板。
///
/// 设计：用户只调主色一种，其他派生色（顶高光、底阴影）由主色自动 HSB lighten/darken 派生，
/// 这样既能给桌宠换色，又不要求用户对每个色板都手工调一遍。
///
/// 派生规则：
/// - `derivedTop`：主色 +12% brightness（左上光源高光）
/// - `derivedBottom`：主色 -15% brightness（底部阴影 / 体积感）
///
struct PetPalette: Codable, Equatable {
    /// 主色（16 进制 hex，无 # 前缀，如 "DE886D"）
    var primaryHex: String

    init(primaryHex: String) {
        self.primaryHex = primaryHex
    }

    /// 主色 SwiftUI Color
    var primary: Color {
        Color(hex: primaryHex) ?? Self.fallbackColor
    }

    /// 顶部高光（主色 +12% brightness）
    var derivedTop: Color {
        primary.lightened(by: 0.12)
    }

    /// 底部阴影（主色 -15% brightness）
    var derivedBottom: Color {
        primary.darkened(by: 0.15)
    }

    // —— 默认 palette ——

    /// 冷蓝信息屏；金属机体的颜色由统一绘制器独立定义。
    static let tarsDefault = PetPalette(primaryHex: "8DDCFF")

    private static let fallbackColor = Color.gray
}

// MARK: - PetPaletteStore

/// 全局调色板存储 —— UserDefaults JSON 持久化
@MainActor
@Observable
final class PetPaletteStore {
    static let shared = PetPaletteStore()

    var tarsPalette: PetPalette

    private init() {
        let stored: PetPalette? = {
            guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return nil }
            return try? JSONDecoder().decode(PetPalette.self, from: data)
        }()
        // 只迁移历史默认色，保留用户自定义的信息屏颜色。
        let legacyDefaults = ["DE886D", "59D0FF"]
        if let stored, legacyDefaults.contains(stored.primaryHex.uppercased()) {
            self.tarsPalette = .tarsDefault
            save()
        } else {
            self.tarsPalette = stored ?? .tarsDefault
        }
    }

    func palette(for mode: AgentMode) -> PetPalette {
        return tarsPalette
    }

    func updatePalette(for mode: AgentMode, _ palette: PetPalette) {
        tarsPalette = palette
        save()
    }

    func updatePrimary(for mode: AgentMode, color: Color) {
        var p = tarsPalette
        p.primaryHex = color.hexString
        tarsPalette = p
        save()
    }

    func resetToDefault(for mode: AgentMode) {
        tarsPalette = .tarsDefault
        save()
    }

    // —— 持久化 ——

    private static let storageKey = "petPalette.v2"

    private func save() {
        if let data = try? JSONEncoder().encode(tarsPalette) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Color hex / HSB 派生

extension Color {
    /// 从 16 进制 hex 字符串创建 Color（支持 "#RRGGBB" 或 "RRGGBB"）
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hexSanitized.hasPrefix("#") {
            hexSanitized.removeFirst()
        }
        guard hexSanitized.count == 6 else { return nil }
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >>  8) / 255
        let b = Double( rgb & 0x0000FF)        / 255
        self.init(red: r, green: g, blue: b)
    }

    /// 取 Color 的 hex 字符串（无 # 前缀，大写，如 "DE886D"）
    /// ColorPicker 修改 Color 后用这个转回 hex 存到 palette
    var hexString: String {
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return "808080" }
        let r = Int(round(rgb.redComponent   * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent  * 255))
        return String(format: "%02X%02X%02X", r, g, b)
    }

    /// 调亮（HSB 空间 brightness +amount，clamp 到 [0,1]）
    func lightened(by amount: Double) -> Color {
        adjustBrightness(by: amount)
    }

    /// 调暗
    func darkened(by amount: Double) -> Color {
        adjustBrightness(by: -amount)
    }

    private func adjustBrightness(by delta: Double) -> Color {
        let ns = NSColor(self)
        guard let rgb = ns.usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newB = max(0, min(1, b + CGFloat(delta)))
        return Color(
            hue: Double(h),
            saturation: Double(s),
            brightness: Double(newB),
            opacity: Double(a)
        )
    }
}

// MARK: - PetWalkSizeScale

/// 桌面漫步桌宠缩放因子。
///
/// **只影响桌面漫步 sprite**（TarsWalkController 的窗口大小 + 内部 sprite 高度），
/// 不影响灵动岛 sprite（受刘海物理高度约束，加 scale 反而不协调）。
///
/// 状态：UserDefaults 持久化（key = `petWalkSizeScale`），默认 1.0。
/// 访问：`@AppStorage("petWalkSizeScale")` 在 TarsWalkOverlay / SettingsView 都能用。
enum PetWalkSizeScale {
    static let storageKey = "petWalkSizeScale"

    /// 五档缩放：70% / 85% / 100% / 120% / 150%
    /// 设计：跟 ChatFontScale 同款 5 档风格，档差 ~15-30% 让差异肉眼可见
    static let presets: [Double] = [0.7, 0.85, 1.0, 1.2, 1.5]

    static let `default`: Double = 1.0

    /// 缩放变化时广播 —— TarsWalkController 监听后 setFrame 已显示的桌宠窗口
    static let didChangeNotification = Notification.Name("HermesPetWalkSizeScaleChanged")

    /// 找到当前 scale 最接近的预设档位 index（容差 0.02）；找不到返回 -1
    static func currentIndex(for scale: Double) -> Int {
        for (i, p) in presets.enumerated() where abs(p - scale) < 0.02 {
            return i
        }
        return -1
    }

    /// 档位的显示标签（segmented Picker 用）
    static func label(for scale: Double) -> String {
        switch scale {
        case 0.7:  return "迷你"
        case 0.85: return "小"
        case 1.0:  return "默认"
        case 1.2:  return "大"
        case 1.5:  return "特大"
        default:   return "\(Int(scale * 100))%"
        }
    }

    /// 把基础尺寸按 scale 缩放
    static func scaled(_ base: CGFloat, by scale: Double) -> CGFloat {
        base * CGFloat(scale)
    }
}
