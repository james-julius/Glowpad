// Glowpad — small window app that controls the DualSense light bar over Bluetooth or USB:
// off, solid colour, or animated modes, re-applied automatically whenever a controller connects.
import Cocoa
import SwiftUI
import IOKit.hid

let sonyVID = 0x054C
let dualSensePIDs = [0x0CE6, 0x0DF2] // DualSense, DualSense Edge

// MARK: - CRC32 (zlib polynomial), needed for Bluetooth output reports

let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
    var c = UInt32(i)
    for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
    return c
}

func crc32(_ bytes: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFFFFFF
    for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
    return c ^ 0xFFFFFFFF
}

// MARK: - DualSense output report

struct RGB: Equatable, Codable {
    var r = 0.0, g = 0.0, b = 0.0
    static let black = RGB()
    func scaled(_ k: Double) -> RGB { RGB(r: r * k, g: g * k, b: b * k) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b) }
    init(r: Double = 0, g: Double = 0, b: Double = 0) { self.r = r; self.g = g; self.b = b }
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(n.redComponent), g: Double(n.greenComponent), b: Double(n.blueComponent))
    }
}

struct LightState: Equatable {
    var r: UInt8 = 0, g: UInt8 = 0, b: UInt8 = 0
    var playerLEDs = false
}

var outputSeq: UInt8 = 0

/// The 47-byte "common" block shared by USB and BT reports (layout from Linux hid-playstation).
func commonBlock(_ s: LightState, lightOut: Bool) -> [UInt8] {
    var c = [UInt8](repeating: 0, count: 47)
    c[1] = 0x04 | 0x10 // valid_flag1: lightbar control + player indicator control
    if lightOut {
        c[38] = 0x02   // valid_flag2: lightbar setup control
        c[41] = 0x02   // lightbar_setup: light out (ends the connect animation)
    }
    c[43] = s.playerLEDs ? 0x04 : 0x00 // centre player LED, or none
    c[44] = s.r; c[45] = s.g; c[46] = s.b
    return c
}

func send(_ s: LightState, to device: IOHIDDevice, lightOut: Bool = false) -> Bool {
    let transport = IOHIDDeviceGetProperty(device, kIOHIDTransportKey as CFString) as? String ?? ""
    var report: [UInt8]
    if transport.lowercased() == "bluetooth" {
        report = [0x31, outputSeq << 4, 0x10] + commonBlock(s, lightOut: lightOut) + [UInt8](repeating: 0, count: 24)
        outputSeq = (outputSeq + 1) & 0x0F
        let crc = crc32([0xA2] + report)
        report += [UInt8(crc & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8((crc >> 16) & 0xFF), UInt8(crc >> 24)]
    } else {
        report = [0x02] + commonBlock(s, lightOut: lightOut) + [UInt8](repeating: 0, count: 15)
    }
    return IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(report[0]), report, report.count) == kIOReturnSuccess
}

// MARK: - Modes

enum Mode: String, CaseIterable, Identifiable {
    case off = "Off", solid = "Solid", breathe = "Breathe", rainbow = "Rainbow", police = "Police", fire = "Fire"
    var id: String { rawValue }
    var animated: Bool { ![.off, .solid].contains(self) }
    var usesColour: Bool { [.solid, .breathe].contains(self) }
    var symbol: String {
        switch self {
        case .off: "moon.zzz.fill"
        case .solid: "circle.fill"
        case .breathe: "wind"
        case .rainbow: "rainbow"
        case .police: "light.beacon.max.fill"
        case .fire: "flame.fill"
        }
    }
}

let swatches: [RGB] = [
    RGB(r: 1, g: 0.18, b: 0.25), RGB(r: 1, g: 0.5, b: 0.05), RGB(r: 1, g: 0.85, b: 0.1),
    RGB(r: 0.2, g: 0.95, b: 0.4), RGB(r: 0.1, g: 0.85, b: 1), RGB(r: 0.15, g: 0.35, b: 1),
    RGB(r: 0.6, g: 0.25, b: 1), RGB(r: 1, g: 0.3, b: 0.75), RGB(r: 1, g: 1, b: 1),
]

// MARK: - Model

final class LightModel: ObservableObject {
    private let defaults = UserDefaults.standard
    @Published var mode: Mode { didSet { defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var colour: RGB { didSet { defaults.set(try? JSONEncoder().encode(colour), forKey: "rgb") } }
    @Published var brightness: Double { didSet { defaults.set(brightness, forKey: "brightness") } }
    @Published var speed: Double { didSet { defaults.set(speed, forKey: "speed") } }
    @Published var playerLED: Bool { didSet { defaults.set(playerLED, forKey: "playerLEDs") } }
    @Published var connected = 0
    /// What the light bar is showing right now, for the on-screen preview.
    @Published var output = RGB.black

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var devices = Set<IOHIDDevice>()
    private var lastSent: LightState?
    private var phase = 0.0
    private var fireLevel = 0.7

    init() {
        mode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .off
        colour = defaults.data(forKey: "rgb").flatMap { try? JSONDecoder().decode(RGB.self, from: $0) } ?? swatches[6]
        brightness = defaults.object(forKey: "brightness") as? Double ?? 1
        speed = defaults.object(forKey: "speed") as? Double ?? 0.5
        playerLED = defaults.bool(forKey: "playerLEDs")
        startHID()
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    private func currentRGB() -> RGB {
        switch mode {
        case .off:
            return .black
        case .solid:
            return colour.scaled(brightness)
        case .breathe:
            return colour.scaled((0.08 + 0.92 * (0.5 - 0.5 * cos(phase * 2 * .pi))) * brightness)
        case .rainbow:
            let c = NSColor(hue: phase.truncatingRemainder(dividingBy: 1), saturation: 1, brightness: brightness, alpha: 1)
            return RGB(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent))
        case .police:
            let half = (phase * 4).truncatingRemainder(dividingBy: 2) // red, then blue, alternating
            if half.truncatingRemainder(dividingBy: 1) > 0.75 { return .black } // short gap between flashes
            return half < 1 ? RGB(r: brightness) : RGB(b: brightness)
        case .fire:
            return RGB(r: fireLevel, g: fireLevel * 0.28).scaled(brightness)
        }
    }

    private func tick() {
        phase += (0.05 + speed * 0.95) / 30 // ~20s to ~1s per cycle
        if phase > 1000 { phase = 0 }
        if mode == .fire { fireLevel = max(0.35, min(1, fireLevel + Double.random(in: -0.15...0.15) * speed * 2)) }
        let rgb = currentRGB()
        if rgb != output { output = rgb }
        let s = state(rgb)
        guard s != lastSent else { return }
        lastSent = s
        devices.forEach { _ = send(s, to: $0) }
    }

    private func state(_ c: RGB) -> LightState {
        func byte(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        return LightState(r: byte(c.r), g: byte(c.g), b: byte(c.b), playerLEDs: playerLED)
    }

    private func startHID() {
        let matches = dualSensePIDs.map { [kIOHIDVendorIDKey: sonyVID, kIOHIDProductIDKey: $0] as CFDictionary }
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, device in
            let m = Unmanaged<LightModel>.fromOpaque(ctx!).takeUnretainedValue()
            m.devices.insert(device)
            m.connected = m.devices.count
            m.applyOnConnect(device)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, device in
            let m = Unmanaged<LightModel>.fromOpaque(ctx!).takeUnretainedValue()
            m.devices.remove(device)
            m.connected = m.devices.count
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    /// Sends a few times spaced out, since the controller's own connect animation can override the first one.
    private func applyOnConnect(_ device: IOHIDDevice) {
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 1.2) { [weak self] in
                guard let self, self.devices.contains(device) else { return }
                let ok = send(self.state(self.currentRGB()), to: device, lightOut: true)
                NSLog("Glowpad: send %@", ok ? "ok" : "failed")
            }
        }
    }
}

// MARK: - Controller illustration

/// A stylised DualSense outline in a 300×200 space.
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

struct ControllerPreview: View {
    var light: RGB
    var playerLED: Bool

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / 300
            ZStack(alignment: .topLeading) {
                ControllerBody()
                    .fill(LinearGradient(colors: [Color(white: 0.97), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.5), radius: 18 * s, y: 12 * s)
                // dark centre panel
                RoundedRectangle(cornerRadius: 22 * s)
                    .fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 128 * s, height: 66 * s)
                    .offset(x: 86 * s, y: 86 * s)
                // touchpad
                RoundedRectangle(cornerRadius: 10 * s)
                    .fill(LinearGradient(colors: [.white, Color(white: 0.86)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 10 * s).stroke(Color.black.opacity(0.12), lineWidth: 1))
                    .frame(width: 104 * s, height: 58 * s)
                    .offset(x: 98 * s, y: 28 * s)
                // light bars either side of the touchpad
                ForEach([92.0, 204.0], id: \.self) { x in
                    Capsule()
                        .fill(light.color)
                        .frame(width: 4 * s, height: 48 * s)
                        .shadow(color: light.color, radius: 4 * s)
                        .shadow(color: light.color.opacity(0.8), radius: 12 * s)
                        .offset(x: x * s, y: 34 * s)
                }
                // player LED
                Capsule()
                    .fill(playerLED ? Color.white : Color(white: 0.35))
                    .shadow(color: playerLED ? .white : .clear, radius: 3 * s)
                    .frame(width: 10 * s, height: 2.5 * s)
                    .offset(x: 145 * s, y: 90 * s)
                // sticks
                ForEach([118.0, 182.0], id: \.self) { x in
                    Circle()
                        .fill(RadialGradient(colors: [Color(white: 0.3), Color(white: 0.08)], center: .topLeading, startRadius: 0, endRadius: 24 * s))
                        .overlay(Circle().stroke(Color(white: 0.4), lineWidth: 1))
                        .frame(width: 30 * s, height: 30 * s)
                        .offset(x: (x - 15) * s, y: 104 * s)
                }
                // PS button
                Circle().fill(Color(white: 0.2)).frame(width: 10 * s, height: 10 * s).offset(x: 145 * s, y: 128 * s)
                // d-pad
                Image(systemName: "dpad.fill")
                    .font(.system(size: 34 * s))
                    .foregroundStyle(Color(white: 0.55))
                    .offset(x: 41 * s, y: 54 * s)
                // face buttons
                ForEach(Array([(0.0, -13.0), (13.0, 0.0), (0.0, 13.0), (-13.0, 0.0)].enumerated()), id: \.offset) { _, d in
                    Circle()
                        .fill(Color(white: 0.6))
                        .frame(width: 10 * s, height: 10 * s)
                        .offset(x: (242 + d.0 - 5) * s, y: (70 + d.1 - 5) * s)
                }
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
    }
}

// MARK: - Views

/// Translucent rounded card, Liquid Glass on macOS 26.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            content.padding(16).glassEffect(.regular, in: .rect(cornerRadius: 20))
        } else {
            content.padding(16).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: LightModel

    /// Accent for selections/sliders — the live colour at full strength, or the chosen colour when the bar is dark.
    var accent: Color {
        let o = model.output
        let peak = max(o.r, o.g, o.b)
        if peak < 0.15 { return model.mode == .off ? .white : model.colour.color }
        return o.scaled(1 / peak).color
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            ControllerPreview(light: model.output, playerLED: model.playerLED)
                .frame(width: 250)
                .padding(.vertical, 6)
            modeGrid
            Card { settings }
        }
        .padding(.horizontal, 24)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 380)
        .background(background)
        .ignoresSafeArea() // top padding already clears the transparent titlebar; also avoids a resize feedback loop
        .animation(.spring(duration: 0.35), value: model.mode)
        .preferredColorScheme(.dark)
        .tint(accent)
    }

    var background: some View {
        ZStack {
            VisualEffect()
            LinearGradient(colors: [Color.black.opacity(0.35), Color.black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [model.output.color.opacity(0.6), .clear], center: UnitPoint(x: 0.5, y: 0.22), startRadius: 0, endRadius: 260)
        }
        .ignoresSafeArea()
    }

    var header: some View {
        HStack {
            Text("Glowpad")
                .font(.system(size: 22, weight: .bold, design: .rounded))
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(model.connected > 0 ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                    .shadow(color: model.connected > 0 ? .green : .clear, radius: 4)
                Text(model.connected > 0 ? "Connected" : "Not connected")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: Capsule())
        }
    }

    var modeGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(Mode.allCases) { mode in
                let selected = model.mode == mode
                Button { model.mode = mode } label: {
                    VStack(spacing: 6) {
                        Image(systemName: mode.symbol)
                            .font(.system(size: 18, weight: .semibold))
                            .symbolRenderingMode(mode == .rainbow ? .multicolor : .monochrome)
                            .frame(height: 22)
                        Text(mode.rawValue)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(selected ? .white : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(selected ? AnyShapeStyle(accent.opacity(0.28).gradient) : AnyShapeStyle(Color.white.opacity(0.06)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(selected ? accent.opacity(0.9) : Color.white.opacity(0.08), lineWidth: selected ? 1.5 : 1)
                    )
                    .shadow(color: selected ? accent.opacity(0.45) : .clear, radius: 10)
                    .contentShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
        }
    }

    var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, c in
                        let selected = model.colour == c
                        Circle()
                            .fill(c.color)
                            .frame(width: 22, height: 22)
                            .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0), lineWidth: 2).padding(-4))
                            .shadow(color: c.color.opacity(selected ? 0.8 : 0.3), radius: selected ? 6 : 2)
                            .onTapGesture { model.colour = c }
                    }
                    Spacer(minLength: 0)
                    ColorPicker("", selection: Binding(get: { model.colour.color }, set: { model.colour = RGB($0) }), supportsOpacity: false)
                        .labelsHidden()
            }
            .dimmed(!model.mode.usesColour)
            SliderRow(low: "sun.min.fill", high: "sun.max.fill", value: $model.brightness, range: 0.05...1)
                .dimmed(model.mode == .off)
            SliderRow(low: "tortoise.fill", high: "hare.fill", value: $model.speed, range: 0.05...1)
                .dimmed(!model.mode.animated)
            Toggle(isOn: $model.playerLED) {
                Label("Player light", systemImage: "light.min")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }
}

extension View {
    /// Fades and disables controls that don't apply to the current mode, keeping the layout fixed.
    func dimmed(_ on: Bool) -> some View { opacity(on ? 0.3 : 1).disabled(on) }
}

struct SliderRow: View {
    var low: String, high: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: low).foregroundStyle(.white.opacity(0.6)).frame(width: 18)
            Slider(value: $value, in: range)
            Image(systemName: high).foregroundStyle(.white.opacity(0.6)).frame(width: 18)
        }
        .font(.system(size: 12))
    }
}

/// Drags the window only from empty background, so sliders and buttons keep their clicks.
final class DragBackgroundView: NSVisualEffectView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = DragBackgroundView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LightModel()
    var window: NSWindow!
    lazy var host = NSHostingController(rootView: ContentView(model: model))

    func applicationDidFinishLaunching(_ n: Notification) {
        host.sizingOptions = [] // automatic sizing loops with macOS 26 corner insets; the layout is fixed-size anyway
        window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize()), styleMask: [], backing: .buffered, defer: false)
        window.contentView = host.view
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.title = "Glowpad"
        window.center()
        window.setFrameAutosaveName("Main") // reopen where it was last left
        window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu = mainMenu()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The standard app, Edit and Window menus, so the usual shortcuts (⌘Q, ⌘H, ⌘W, ⌘M…) work.
    func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            top.submenu = menu
            return top
        }

        let services = NSMenu(title: "Services")
        NSApp.servicesMenu = services
        let servicesItem = item("Services", nil)
        servicesItem.submenu = services

        let appMenu = submenu("Glowpad", [
            item("About Glowpad", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            servicesItem,
            .separator(),
            item("Hide Glowpad", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Glowpad", #selector(NSApplication.terminate(_:)), "q"),
        ])
        let editMenu = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let windowMenu = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))),
        ])
        NSApp.windowsMenu = windowMenu.submenu

        let main = NSMenu()
        [appMenu, editMenu, windowMenu].forEach(main.addItem)
        return main
    }

    func contentSize() -> NSSize { host.sizeThatFits(in: NSSize(width: 380, height: 10_000)) }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
