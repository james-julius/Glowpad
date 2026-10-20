// Renders AppIcon.icns: a glowing DualSense light bar on a dark squircle. Run via build.sh when the icon is missing.
import SwiftUI

struct Icon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 230, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
            RadialGradient(colors: [Color(red: 0.55, green: 0.3, blue: 1).opacity(0.75), .clear], center: .center, startRadius: 0, endRadius: 420)
                .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 500))
                .foregroundStyle(LinearGradient(colors: [.white, Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
            Capsule()
                .fill(LinearGradient(colors: [.pink, .purple, .blue, .cyan], startPoint: .leading, endPoint: .trailing))
                .frame(width: 300, height: 24)
                .shadow(color: .purple, radius: 18)
                .shadow(color: .pink.opacity(0.8), radius: 44)
                .offset(y: -215)
        }
        .frame(width: 824, height: 824)
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
