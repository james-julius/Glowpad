// Renders AppIcon.icns: a DualSense with glowing light bars on a dark squircle. Run via build.sh when the icon is missing.
import SwiftUI

/// Same outline as ControllerBody in main.swift, in a 300×200 space.
struct ControllerBody: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 300, sy = rect.height / 200
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: p(78, 22))
        path.addLine(to: p(222, 22))
        path.addCurve(to: p(284, 68), control1: p(258, 22), control2: p(276, 40))
        path.addCurve(to: p(292, 176), control1: p(294, 104), control2: p(302, 150))
        path.addCurve(to: p(246, 194), control1: p(286, 192), control2: p(262, 200))
        path.addCurve(to: p(204, 146), control1: p(228, 188), control2: p(220, 156))
        path.addLine(to: p(96, 146))
        path.addCurve(to: p(54, 194), control1: p(80, 156), control2: p(72, 188))
        path.addCurve(to: p(8, 176), control1: p(38, 200), control2: p(14, 192))
        path.addCurve(to: p(16, 68), control1: p(-2, 150), control2: p(6, 104))
        path.addCurve(to: p(78, 22), control1: p(24, 40), control2: p(42, 22))
        path.closeSubpath()
        return path
    }
}

let pink = Color(red: 1, green: 0.2, blue: 0.6)
let violet = Color(red: 0.55, green: 0.3, blue: 1)
let cyan = Color(red: 0.1, green: 0.85, blue: 1)

struct Controller: View {
    let s: Double // points per controller unit
    var body: some View {
        ZStack(alignment: .topLeading) {
            ControllerBody()
                .fill(LinearGradient(colors: [.white, Color(white: 0.8)], startPoint: .top, endPoint: .bottom))
                .frame(width: 300 * s, height: 200 * s)
                .shadow(color: .black.opacity(0.55), radius: 16 * s, y: 12 * s)
            // dark centre panel
            RoundedRectangle(cornerRadius: 22 * s)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.05)], startPoint: .top, endPoint: .bottom))
                .frame(width: 128 * s, height: 66 * s)
                .offset(x: 86 * s, y: 86 * s)
            // touchpad
            RoundedRectangle(cornerRadius: 10 * s)
                .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                .frame(width: 104 * s, height: 58 * s)
                .offset(x: 98 * s, y: 28 * s)
            // light bars either side of the touchpad
            ForEach([(88.0, pink), (204.0, cyan)], id: \.0) { x, c in
                Capsule()
                    .fill(LinearGradient(colors: [c, violet], startPoint: .top, endPoint: .bottom))
                    .frame(width: 9 * s, height: 54 * s)
                    .shadow(color: c, radius: 4 * s)
                    .shadow(color: c, radius: 14 * s)
                    .shadow(color: c.opacity(0.9), radius: 30 * s)
                    .offset(x: (x - 0.5) * s, y: 30 * s)
            }
            // sticks
            ForEach([118.0, 182.0], id: \.self) { x in
                Circle()
                    .fill(RadialGradient(colors: [Color(white: 0.32), Color(white: 0.08)], center: .topLeading, startRadius: 0, endRadius: 26 * s))
                    .frame(width: 32 * s, height: 32 * s)
                    .offset(x: (x - 16) * s, y: 103 * s)
            }
            // d-pad
            Image(systemName: "dpad.fill")
                .font(.system(size: 38 * s))
                .foregroundStyle(Color(white: 0.6))
                .offset(x: 38 * s, y: 50 * s)
            // face buttons
            ForEach(Array([(0.0, -14.0), (14.0, 0.0), (0.0, 14.0), (-14.0, 0.0)].enumerated()), id: \.offset) { _, d in
                Circle()
                    .fill(Color(white: 0.62))
                    .frame(width: 12 * s, height: 12 * s)
                    .offset(x: (242 + d.0 - 6) * s, y: (70 + d.1 - 6) * s)
            }
        }
        .frame(width: 300 * s, height: 200 * s, alignment: .topLeading)
    }
}

struct Icon: View {
    var body: some View {
        let squircle = RoundedRectangle(cornerRadius: 185, style: .continuous)
        ZStack {
            squircle.fill(LinearGradient(colors: [Color(red: 0.1, green: 0.07, blue: 0.18), Color(red: 0.02, green: 0.01, blue: 0.05)], startPoint: .top, endPoint: .bottom))
            // colour wash spilling from the light bars
            ZStack {
                Circle().fill(pink.opacity(0.55)).frame(width: 520).blur(radius: 110).offset(x: -170, y: -40)
                Circle().fill(cyan.opacity(0.5)).frame(width: 520).blur(radius: 110).offset(x: 170, y: -40)
                Circle().fill(violet.opacity(0.5)).frame(width: 460).blur(radius: 120).offset(y: 150)
            }
            .frame(width: 824, height: 824)
            Controller(s: 2.3).offset(y: 24)
            squircle.strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom), lineWidth: 3)
        }
        .frame(width: 824, height: 824)
        .clipShape(squircle)
        .frame(width: 1024, height: 1024)
    }
}

MainActor.assumeIsolated {
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let r = ImageRenderer(content: Icon())
        r.scale = Double(size * scale) / 1024
        let rep = NSBitmapImageRep(cgImage: r.cgImage!)
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
}
