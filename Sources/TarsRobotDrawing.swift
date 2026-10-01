import AppKit
import SwiftUI

/// 方柱的整体姿态；没有独立的头、手臂或表情。
enum TarsPose {
    case rest, lookLeft, lookRight, armsUp
}

/// 四根方柱持续轮转，各自的起转时间依次延迟；启动后四轮同时运动。
enum TarsWheelMotion {
    static let viewYaw = 38.0 * Double.pi / 180
    static let scale = 0.90
    static let hingeHeight = 10.3
    private static let columnHeight = 20.6
    private static let halfDepth = 1.325
    // 相邻轮延迟八分之一圈。方柱每半圈形状重复，这样四轮的朝向
    // 均匀错开 45°，同时转动时也不会一起横倒。
    private static let startDelay = 0.125

    /// 仅启动前等待；起转后连续转动，圈与圈之间没有停驻段。
    static func rotation(phase: Double, column: Int) -> Double {
        let localPhase = max(0, phase - Double(column) * startDelay)
        return localPhase * 2 * .pi
    }

    static func rotations(phase: Double) -> [Double] {
        (0..<4).map { rotation(phase: phase, column: $0) }
    }

    /// 由当下最低的柱端决定轴高，保持轮子在地面上方。
    static func supportHeight(rotations: [Double]) -> Double {
        rotations.map { angle in
            hingeHeight * abs(cos(angle)) + halfDepth * abs(sin(angle))
        }.max() ?? hingeHeight
    }

    /// 四轮的共同节奏随桌面实际位移推进，启动延迟也按此进度计算。
    static func cycleDistance(height: CGFloat) -> CGFloat {
        CGFloat(4 * columnHeight * scale * sin(viewYaw)) * height / 24
    }
}

private struct TarsPoint {
    let x: Double
    let y: Double
    let z: Double
    func depth(_ yaw: Double) -> Double { -x * sin(yaw) + z * cos(yaw) }
}

private struct TarsFace {
    let points: [TarsPoint]
    let color: Color
    let metal: Bool
    var surfaceCenter: TarsPoint? = nil
    func depth(_ yaw: Double) -> Double {
        // 同一平面的屏幕和字行按所属柱的中心排序，不能因字行较短
        // 而被算到屏幕底色后方。
        surfaceCenter?.depth(yaw) ?? points.reduce(0) { $0 + $1.depth(yaw) } / Double(points.count)
    }
}

/// 全应用共用的 TARS。颜色只作用于信息屏，机体始终保持黑银金属。
struct TarsView: View {
    let pose: TarsPose
    let height: CGFloat
    var isWalking: Bool = false
    /// 桌面位移驱动的四轮循环；各轮分别计算自身转角，其他窗口使用时间驱动。
    var motionPhase: Double? = nil
    var facingRight: Bool = true
    var followMouse: Bool = false
    var palette: PetPalette = .tarsDefault

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            TarsFigure(pose: pose, height: height, isWalking: isWalking,
                       palette: palette, time: timeline.date.timeIntervalSinceReferenceDate,
                       mouseLean: followMouse ? Self.mouseLean() : 0, motionPhase: motionPhase,
                       walkAmount: isWalking ? 1 : 0, heading: facingRight ? 1 : -1)
                .animation(.easeInOut(duration: 0.22), value: isWalking)
                .animation(.easeInOut(duration: 0.28), value: facingRight)
        }
        .frame(width: height, height: height)
    }

    private static func mouseLean() -> Double {
        let location = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main
        guard let screen, screen.frame.contains(location) else { return 0 }
        let normalized = max(-1, min(1, (location.x - screen.frame.midX) / (screen.frame.width / 2)))
        return Double(normalized) * 3
    }
}

/// 确定时刻的矢量绘制，供实时动画和静态预览共用。
struct TarsFigure: View, Animatable {
    let pose: TarsPose
    let height: CGFloat
    let isWalking: Bool
    var palette: PetPalette = .tarsDefault
    let time: TimeInterval
    var mouseLean: Double = 0
    var motionPhase: Double? = nil
    var walkAmount: Double? = nil
    var heading: Double = 1

    nonisolated var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(walkAmount ?? (isWalking ? 1 : 0), heading) }
        set { walkAmount = newValue.first; heading = newValue.second }
    }

    private static let columnXs: [CGFloat] = [4.0, 6.9, 9.8, 12.7]
    private static let columnWidth: CGFloat = 2.65
    private static let columnHeight: CGFloat = 20.6

    var body: some View {
        Canvas(rendersAsynchronously: false) { context, size in
            draw(context: context, size: size)
        }
        .frame(width: height, height: height)
        .accessibilityLabel("TARS 机器人")
    }

    private func draw(context sourceContext: GraphicsContext, size: CGSize) {
        let unit = min(size.width / 24, size.height / 24)
        var context = sourceContext
        // 展开与迈步的左右端点也完整留在 Canvas 内，避免小尺寸时削掉柱脚。
        context.translateBy(x: 2 * unit, y: 0)
        let pulse = 0.8 + 0.2 * (sin(time * 1.8) + 1) / 2

        let shadow = CGRect(x: 3.0 * unit, y: 23.0 * unit, width: 13.8 * unit, height: 0.65 * unit)
        context.fill(Path(ellipseIn: shadow), with: .color(.black.opacity(0.24)))

        let movement = max(0, min(1, walkAmount ?? (isWalking ? 1 : 0)))
        if movement > 0 {
            var walkingContext = sourceContext
            walkingContext.opacity = movement
            drawWheelMotion(context: walkingContext, unit: unit, pulse: pulse)
            if movement >= 1 { return }
            context.opacity = 1 - movement
        }

        var body = context
        let lean: Double = switch pose {
        case .lookLeft: -3
        case .lookRight: 3
        case .armsUp: 0
        case .rest: mouseLean
        }
        body.translateBy(x: 10 * unit, y: 22.8 * unit)
        body.rotate(by: .degrees(lean))
        body.translateBy(x: -10 * unit, y: -22.8 * unit)

        // 接缝后的横向轴承让四根柱体读作同一个机器，而非四条悬浮的色条。
        body.fill(Path(CGRect(x: 5.3 * unit, y: 8.6 * unit,
                              width: 8.5 * unit, height: 0.9 * unit)),
                  with: .color(Color(hex: "252B31")!))

        // 静止时四柱并拢。
        for index in [3, 2, 1, 0] {
            let outer = index == 0 || index == 3
            let unfolded = pose == .armsUp && outer
            let unfoldAngle: Double = unfolded ? (index == 0 ? 16 : -16) : 0
            let unfoldOffset: CGFloat = unfolded ? (index == 0 ? -0.5 : 0.5) : 0
            let angle = unfoldAngle
            let pivotY: CGFloat = 7.0
            let rect = CGRect(x: (Self.columnXs[index] + unfoldOffset) * unit,
                              y: (2.15 - (unfolded ? 0.8 : 0)) * unit,
                              width: Self.columnWidth * unit, height: Self.columnHeight * unit)

            body.drawLayer { column in
                let hinge = CGPoint(x: rect.midX, y: rect.minY + pivotY * unit)
                column.translateBy(x: hinge.x, y: hinge.y)
                column.rotate(by: .degrees(angle))
                column.translateBy(x: -hinge.x, y: -hinge.y)
                drawColumn(context: column, rect: rect, unit: unit, index: index, pulse: pulse)
            }
        }
    }

    /// 轴心并列，四根方柱使用错开起转时间的连续转角。
    private func drawWheelMotion(context: GraphicsContext, unit: CGFloat, pulse: Double) {
        let phase = motionPhase ?? time / 6.0
        let yaw = TarsWheelMotion.viewYaw * heading
        let rotations = TarsWheelMotion.rotations(phase: phase)
        let axisHeight = TarsWheelMotion.supportHeight(rotations: rotations)
        var faces: [TarsFace] = []
        func project(_ point: TarsPoint) -> CGPoint {
            CGPoint(x: (12 + point.x * cos(yaw) + point.z * sin(yaw)) * unit,
                    y: (22.8 - point.y - point.depth(yaw) * 0.055) * unit)
        }

        for index in 0..<4 {
            let pitch = rotations[index]
            let centerX = (Double(index) - 1.5) * 2.9
            func world(_ x: Double, _ y: Double, _ z: Double) -> TarsPoint {
                let relativeY = y - TarsWheelMotion.hingeHeight
                return TarsPoint(x: (centerX + x) * TarsWheelMotion.scale,
                                 y: (axisHeight + relativeY * cos(pitch) - z * sin(pitch)) * TarsWheelMotion.scale,
                                 z: (relativeY * sin(pitch) + z * cos(pitch)) * TarsWheelMotion.scale)
            }
            func box(_ bottom: Double, _ top: Double, width: Double = 2.65, depth: Double = 2.65,
                     dark: Bool = false) {
                let w = width / 2, d = depth / 2
                let vertices = [world(-w, bottom, -d), world(w, bottom, -d),
                                world(w, top, -d), world(-w, top, -d),
                                world(-w, bottom, d), world(w, bottom, d),
                                world(w, top, d), world(-w, top, d)]
                let sides = [[0, 1, 2, 3], [1, 5, 6, 2], [4, 0, 3, 7],
                             [5, 4, 7, 6], [3, 2, 6, 7], [4, 5, 1, 0]]
                let shades = dark ? ["252D35", "10161C", "151B21", "172027", "3B4650", "10161C"]
                                  : ["AAB4BE", "55626F", "687581", "778591", "D3D9DE", "303B45"]
                for faceIndex in sides.indices {
                    faces.append(TarsFace(points: sides[faceIndex].map { vertices[$0] },
                                          color: Color(hex: shades[faceIndex])!, metal: !dark))
                }
            }
            func front(_ left: Double, _ bottom: Double, _ right: Double, _ top: Double, color: Color,
                       z: Double = -1.35) {
                faces.append(TarsFace(points: [world(left, bottom, z), world(right, bottom, z),
                                              world(right, top, z), world(left, top, z)],
                                      color: color, metal: false,
                                      surfaceCenter: world(0, (bottom + top) / 2, z)))
            }

            // 黑色内轴连续连接三段方柱，整根柱体绕横向轴滚转。
            box(0, 20.6, width: 2.2, depth: 2.2, dark: true)
            box(14.05, 20.6)
            box(6.95, 13.85)
            box(0, 6.75)
            for x in [-0.95, -0.50, 0.05, 0.65, 1.02] {
                for range in [(14.15, 20.5), (7.05, 13.75), (0.1, 6.65)] {
                    front(x, range.0, x + 0.025, range.1, color: .white.opacity(0.18))
                }
            }
            if index == 1 {
                front(-1.05, 9.0, 1.05, 12.95, color: Color(hex: "253442")!, z: -1.38)
                front(-0.87, 9.2, 0.87, 12.75, color: Color(hex: "061522")!, z: -1.4)
                for row in 0..<6 {
                    let y = 12.25 - Double(row) * 0.48
                    front(-0.68, y, row % 2 == 0 ? 0.65 : 0.25, y + (row == 0 ? 0.22 : 0.09),
                          color: palette.primary.opacity(pulse * (row == 0 ? 1 : 0.7)), z: -1.42)
                }
            } else if index == 2 {
                front(-0.78, 17.25, 0.78, 17.45, color: palette.primary.opacity(pulse), z: -1.38)
            }
        }
        // 同一深度排序同时处理机体和屏幕，远柱不会盖到近柱上。
        for face in faces.sorted(by: { $0.depth(yaw) > $1.depth(yaw) }) {
            let points = face.points.map(project)
            let path = polygon(points)
            if face.metal {
                context.fill(path, with: .linearGradient(
                    Gradient(colors: [face.color, face.color, face.color]),
                    startPoint: points[0], endPoint: points[1]))
                context.stroke(path, with: .color(Color(hex: "1D2730")!), lineWidth: max(0.35, unit * 0.07))
            } else {
                context.fill(path, with: .color(face.color))
            }
        }
    }

    private func drawColumn(context: GraphicsContext, rect: CGRect, unit: CGFloat,
                            index: Int, pulse: Double) {
        let depth = CGSize(width: 0.75 * unit, height: -0.65 * unit)
        let side = polygon([CGPoint(x: rect.maxX, y: rect.minY),
                            CGPoint(x: rect.maxX + depth.width, y: rect.minY + depth.height),
                            CGPoint(x: rect.maxX + depth.width, y: rect.maxY + depth.height),
                            CGPoint(x: rect.maxX, y: rect.maxY)])
        context.fill(side, with: .linearGradient(
            Gradient(colors: [Color(hex: "4B535C")!, Color(hex: "171C22")!]),
            startPoint: CGPoint(x: rect.maxX, y: rect.minY),
            endPoint: CGPoint(x: rect.maxX + depth.width, y: rect.maxY)))

        let top = polygon([rect.origin, CGPoint(x: rect.minX + depth.width, y: rect.minY + depth.height),
                           CGPoint(x: rect.maxX + depth.width, y: rect.minY + depth.height),
                           CGPoint(x: rect.maxX, y: rect.minY)])
        context.fill(top, with: .color(Color(hex: "D3D9DE")!))
        context.stroke(top, with: .color(.black.opacity(0.55)), lineWidth: max(0.35, unit * 0.08))

        let front = Path(rect)
        context.fill(front, with: .linearGradient(
            Gradient(stops: [
                .init(color: Color(hex: "707B85")!, location: 0),
                .init(color: Color(hex: "BCC4CB")!, location: 0.24),
                .init(color: Color(hex: "9AA4AE")!, location: 0.72),
                .init(color: Color(hex: "737F8A")!, location: 1)
            ]), startPoint: rect.origin, endPoint: CGPoint(x: rect.maxX, y: rect.minY)))
        context.stroke(front, with: .color(Color(hex: "161C22")!), lineWidth: max(0.4, unit * 0.12))

        // 细纵纹与窄高光，保留方柱的硬边和拉丝铝质感。
        for line in 1..<7 {
            let x = rect.minX + rect.width * CGFloat(line) / 7
            context.fill(Path(CGRect(x: x, y: rect.minY + 0.2 * unit,
                                     width: max(0.15, unit * 0.035), height: rect.height - 0.4 * unit)),
                         with: .color(.white.opacity(line % 2 == 0 ? 0.12 : 0.05)))
        }
        context.fill(Path(CGRect(x: rect.minX + 0.08 * unit, y: rect.minY + 0.1 * unit,
                                 width: max(0.3, unit * 0.10), height: rect.height - 0.2 * unit)),
                     with: .color(.white.opacity(0.55)))

        // 三段模块间是黑色机械关节，侧面也延续同一接缝。
        for offset: CGFloat in [6.7, 13.9] {
            let y = rect.minY + offset * unit
            context.fill(Path(CGRect(x: rect.minX, y: y, width: rect.width, height: 0.30 * unit)),
                         with: .color(Color(hex: "11171D")!))
            context.fill(polygon([CGPoint(x: rect.maxX, y: y),
                                  CGPoint(x: rect.maxX + depth.width, y: y + depth.height),
                                  CGPoint(x: rect.maxX + depth.width, y: y + depth.height + 0.3 * unit),
                                  CGPoint(x: rect.maxX, y: y + 0.3 * unit)]),
                         with: .color(.black.opacity(0.85)))
            context.fill(Path(CGRect(x: rect.minX, y: y + 0.3 * unit,
                                     width: rect.width, height: 0.08 * unit)),
                         with: .color(.white.opacity(0.65)))
        }

        if index == 1 {
            drawDisplay(context: context, rect: rect, unit: unit, pulse: pulse)
            if height >= 45 {
                let label = Text("TARS").font(.system(size: 0.67 * unit, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: "303B45")!)
                context.draw(label, at: CGPoint(x: rect.midX, y: rect.minY + 1.55 * unit), anchor: .center)
            }
        } else if index == 2 {
            let indicator = CGRect(x: rect.minX + 0.5 * unit, y: rect.minY + 3.2 * unit,
                                   width: rect.width - 1.0 * unit, height: 0.20 * unit)
            context.fill(Path(indicator), with: .color(palette.primary.opacity(pulse * 0.85)))
        }

        context.fill(Path(CGRect(x: rect.minX + 0.12 * unit, y: rect.maxY - 0.5 * unit,
                                 width: rect.width - 0.24 * unit, height: 0.4 * unit)),
                     with: .color(Color(hex: "252C33")!))
    }

    private func drawDisplay(context: GraphicsContext, rect: CGRect, unit: CGFloat, pulse: Double) {
        let screen = CGRect(x: rect.minX + 0.32 * unit, y: rect.minY + 7.8 * unit,
                            width: rect.width - 0.64 * unit, height: 3.65 * unit)
        context.fill(Path(screen.insetBy(dx: -0.12 * unit, dy: -0.12 * unit)),
                     with: .color(Color(hex: "343F49")!))
        context.fill(Path(screen), with: .color(Color(hex: "07121D")!))
        context.stroke(Path(screen), with: .color(palette.primary.opacity(0.45)),
                       lineWidth: max(0.35, unit * 0.07))

        let header = CGRect(x: screen.minX + 0.2 * unit, y: screen.minY + 0.32 * unit,
                            width: screen.width - 0.4 * unit, height: 0.28 * unit)
        context.fill(Path(header), with: .color(palette.primary.opacity(pulse)))
        for row in 0..<5 {
            let width: CGFloat = row % 2 == 0 ? 1.45 : 0.95
            let line = CGRect(x: screen.minX + 0.2 * unit,
                              y: screen.minY + (1.05 + CGFloat(row) * 0.43) * unit,
                              width: min(width * unit, screen.width - 0.4 * unit),
                              height: max(0.25, unit * 0.10))
            context.fill(Path(line), with: .color(row == 2 ? .white.opacity(pulse) : palette.primary.opacity(0.72)))
        }
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            path.closeSubpath()
        }
    }
}
