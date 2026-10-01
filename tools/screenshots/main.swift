import AppKit
import SwiftUI

// README screenshot renderer. Offscreen windows only; every piece of data below is invented.
// Usage: perchshots <outdir> [only-name,...]
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
let only = args.count > 2 ? Set(args[2].split(separator: ",").map(String.init)) : nil

// Probe-only defaults (this binary has its own defaults domain, wiped at exit).
let ud = UserDefaults.standard
for (k, v) in [("waveform.useRealAudio", false), ("media.explicitBadge", false), ("media.artworkFlip", false),
               ("calendarEnabled", true), ("cal.showWeather", true), ("activities.animatedVisuals", true)] as [(String, Bool)] {
    ud.set(v, forKey: k)
}
ud.set("week", forKey: "cal.layout")

/// Reports itself active so controls draw in their active (accent) state; nothing is actually activated.
final class ProbeApp: NSApplication {
    override var isActive: Bool { true }
}
let app = ProbeApp.shared
app.setActivationPolicy(.prohibited)
app.appearance = NSAppearance(named: .darkAqua)

func pump(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

func render<V: View>(_ name: String, _ size: CGSize, wait: Double = 1.2, @ViewBuilder _ v: () -> V) {
    if let only, !only.contains(name) { return }
    let h = NSHostingController(rootView: v().frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark))
    h.sizingOptions = []
    let w = KeyWindow(contentViewController: h)
    w.styleMask = [.borderless]
    w.appearance = NSAppearance(named: .darkAqua)
    w.setContentSize(size); w.setFrameOrigin(NSPoint(x: -9000, y: -9000)); w.makeKeyAndOrderFront(nil)
    pump(wait)
    let view = w.contentView!
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png"))
    w.orderOut(nil)
    print("wrote", name, rep.pixelsWide, "x", rep.pixelsHigh)
}

// MARK: Fake artwork (drawn here, no external images)

func makeArtwork() -> NSImage {
    NSImage(size: NSSize(width: 600, height: 600), flipped: false) { r in
        let ctx = NSGraphicsContext.current!.cgContext
        let cs = CGColorSpaceCreateDeviceRGB()
        let sky = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1),
            CGColor(red: 0.93, green: 0.34, blue: 0.47, alpha: 1),
            CGColor(red: 0.36, green: 0.20, blue: 0.55, alpha: 1),
        ] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: 260), end: CGPoint(x: 0, y: 600), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        // Sun.
        ctx.setFillColor(CGColor(red: 1, green: 0.88, blue: 0.62, alpha: 0.95))
        ctx.fillEllipse(in: CGRect(x: 190, y: 250, width: 220, height: 220))
        // Layered hills.
        let hills: [(CGFloat, CGColor)] = [
            (300, CGColor(red: 0.45, green: 0.18, blue: 0.45, alpha: 1)),
            (220, CGColor(red: 0.28, green: 0.12, blue: 0.36, alpha: 1)),
            (140, CGColor(red: 0.14, green: 0.07, blue: 0.24, alpha: 1)),
        ]
        for (i, (y, c)) in hills.enumerated() {
            let p = CGMutablePath()
            p.move(to: CGPoint(x: 0, y: 0))
            p.addLine(to: CGPoint(x: 0, y: y))
            let phase = CGFloat(i) * 1.7
            for x in stride(from: 0, through: 600, by: 10) {
                let xx = CGFloat(x)
                p.addLine(to: CGPoint(x: xx, y: y + 34 * sin(xx / 95 + phase) + 18 * sin(xx / 37 + phase * 2)))
            }
            p.addLine(to: CGPoint(x: 600, y: 0))
            p.closeSubpath()
            ctx.addPath(p); ctx.setFillColor(c); ctx.fillPath()
        }
        _ = r
        return true
    }
}

// MARK: Backdrop

struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.07, green: 0.07, blue: 0.20), Color(red: 0.17, green: 0.10, blue: 0.30),
                                    Color(red: 0.06, green: 0.15, blue: 0.25)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            GeometryReader { g in
                let w = g.size.width
                ZStack {
                    RadialGradient(colors: [Color(red: 0.95, green: 0.45, blue: 0.40).opacity(0.55), .clear],
                                   center: UnitPoint(x: 0.12, y: 1.05), startRadius: 0, endRadius: w * 0.42)
                    RadialGradient(colors: [Color(red: 0.25, green: 0.65, blue: 0.85).opacity(0.45), .clear],
                                   center: UnitPoint(x: 0.92, y: 0.95), startRadius: 0, endRadius: w * 0.38)
                    RadialGradient(colors: [Color(red: 0.55, green: 0.35, blue: 0.95).opacity(0.35), .clear],
                                   center: UnitPoint(x: 0.55, y: 0.1), startRadius: 0, endRadius: w * 0.3)
                }
            }
        }
        .clipped()
    }
}

struct MenuBar: View {
    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "circle.hexagongrid.fill").font(.system(size: 14))
            Text("Finder").fontWeight(.bold)
            ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0) }
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Text(Date().formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + "  " + Date().formatted(date: .omitted, time: .shortened))
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(Color.black.opacity(0.22))
    }
}

/// Desktop strip: wallpaper + menu bar, with the real `NotchView` hanging from the top center.
struct Desktop<C: View>: View {
    @ViewBuilder var content: C
    var body: some View {
        ZStack(alignment: .top) {
            Wallpaper()
            MenuBar()
            content
        }
    }
}

// MARK: Fake state

let model = NotchModel()
model.notchSize = CGSize(width: 185, height: 32)
let screen = NotchScreen(displayID: 0, notchSize: CGSize(width: 185, height: 32), isSimulated: false)

var st = MediaRemoteSource.State()
st.title = "Midnight Lanterns"; st.artist = "The Paper Orchards"; st.album = "Low Tide Radio"
st.isPlaying = true; st.duration = 214; st.elapsed = 83; st.rate = 1; st.timestamp = Date()
st.artwork = .some(makeArtwork())
st.shuffleMode = 1; st.repeatMode = 1; st.isLiked = true
st.commands = [0, 1, 2, 4, 5, 6, 7, 21, 24, 25, 26]
let np = NowPlaying(probe: st)

let battery = Battery()
let shelf = Shelf()
let ctx = NotchContext(model: model, nowPlaying: np, battery: battery, shelf: shelf, settings: AppSettings.shared, panel: NSPanel())
let calendar = CalendarService(context: ctx)

let cal = Calendar.current
let today = cal.startOfDay(for: Date())
func at(_ h: Int, _ m: Int = 0, day: Int = 0) -> Date {
    cal.date(byAdding: .minute, value: (day * 24 + h) * 60 + m, to: today)!
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }
let blue = color(0.25, 0.55, 1), orange = color(1, 0.6, 0.2), green = color(0.3, 0.8, 0.45), purple = color(0.68, 0.45, 1)
// Upcoming relative to the render time (the clock in the shots is real), so nothing shows as past.
let base = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 1800).rounded(.up) * 1800)
func rel(_ minutes: Int) -> Date { base.addingTimeInterval(Double(minutes) * 60) }
calendar.probeSeed([
    CalendarEvent(id: "a", title: "Launch week", start: today, end: at(24), isAllDay: true, color: purple, joinURL: nil),
    CalendarEvent(id: "c", title: "Design review: onboarding", start: rel(0), end: rel(45), isAllDay: false, color: blue,
                  joinURL: URL(string: "https://example.com/meet/design")),
    CalendarEvent(id: "d", title: "Coffee with Priya", start: rel(60), end: rel(90), isAllDay: false, color: green, joinURL: nil,
                  location: "Corner Café"),
    CalendarEvent(id: "e", title: "Release sync", start: rel(120), end: rel(150), isAllDay: false, color: orange, joinURL: nil),
    CalendarEvent(id: "g", title: "Team offsite", start: at(10, day: 2), end: at(16, day: 2), isAllDay: false, color: orange, joinURL: nil),
    CalendarEvent(id: "h", title: "Dentist", start: at(8, day: 3), end: at(9, day: 3), isAllDay: false, color: green, joinURL: nil),
    CalendarEvent(id: "i", title: "Sprint planning", start: at(10, day: -2), end: at(11, day: -2), isAllDay: false, color: blue, joinURL: nil),
])
WeatherService.shared.probeSeed(WeatherSnapshot(temperature: 19, high: 22, low: 13, symbol: "cloud.sun.fill",
                                                summary: "Partly cloudy", precipitationChance: 0.1,
                                                sunrise: at(7, 12), sunset: at(18, 54), locationName: "Springfield"))

func fakeBattery(_ level: Int, charging: Bool = false) {
    battery.hasBattery = true; battery.level = level; battery.isCharging = charging
}

func notch() -> some View {
    NotchView()
        .environmentObject(model).environmentObject(np).environmentObject(shelf).environmentObject(calendar)
        .environmentObject(DisplaySettings.shared).environmentObject(screen).environmentObject(battery)
        .environmentObject(AppSettings.shared)
}

let wide = CGSize(width: 1000, height: 240)
let strip = CGSize(width: 900, height: 96)

// MARK: Clips (perchshots --clips <framesdir>): PNG frame sequences on pure black for the website.
// Frames are captured in real time (SwiftUI animations and TimelineViews run on the wall clock),
// held in memory, then written as <framesdir>/<name>/0000.png… for tools/screenshots/clips.sh.

/// Notch on pure black, no desktop: the clip blends into a black page section.
func onBlack(_ player: NowPlaying) -> some View {
    ZStack(alignment: .top) {
        Color.black
        NotchView()
            .environmentObject(model).environmentObject(player).environmentObject(shelf).environmentObject(calendar)
            .environmentObject(DisplaySettings.shared).environmentObject(screen).environmentObject(battery)
            .environmentObject(AppSettings.shared)
    }
}

/// Records `seconds` of frames at `fps`. `step(t)` runs before each frame (t in seconds).
/// `order` maps the captured frames to the written sequence (ping-pong, rotation for posters).
func record<V: View>(_ dir: URL, _ name: String, _ size: CGSize, seconds: Double, fps: Double = 30,
                     settle: Double = 1.2, step: (Double) -> Void = { _ in },
                     order: ([NSBitmapImageRep]) -> [NSBitmapImageRep] = { $0 }, _ v: V) {
    let h = NSHostingController(rootView: v.frame(width: size.width, height: size.height).environment(\.colorScheme, .dark))
    h.sizingOptions = []
    let w = KeyWindow(contentViewController: h)
    w.styleMask = [.borderless]
    w.appearance = NSAppearance(named: .darkAqua)
    w.backgroundColor = .black
    w.setContentSize(size); w.setFrameOrigin(NSPoint(x: -9000, y: -9000)); w.makeKeyAndOrderFront(nil)
    pump(settle)
    let view = w.contentView!
    var frames: [NSBitmapImageRep] = []
    let n = Int(seconds * fps)
    let t0 = Date()
    var late = 0.0
    for i in 0..<n {
        let t = Double(i) / fps
        step(t)
        let target = t0.addingTimeInterval(t)
        late = max(late, -target.timeIntervalSinceNow)
        RunLoop.main.run(until: target)
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        frames.append(rep)
    }
    w.orderOut(nil)
    let d = dir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: d)
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    for (i, rep) in order(frames).enumerated() {
        try! rep.representation(using: .png, properties: [:])!.write(to: d.appendingPathComponent(String(format: "%04d.png", i)))
    }
    print("clip", name, frames[0].pixelsWide, "x", frames[0].pixelsHigh, order(frames).count, "frames, max lag",
          String(format: "%.0fms", late * 1000))
}

/// Forward then backward (without repeating the end frames): seamless for motion with no direction.
func pingPong(_ f: [NSBitmapImageRep]) -> [NSBitmapImageRep] { f + f.dropFirst().dropLast().reversed() }
/// Start the loop at `at` seconds (so frame 0, the poster, shows the activity, not an empty notch).
func rotated(_ at: Double, fps: Double = 30) -> ([NSBitmapImageRep]) -> [NSBitmapImageRep] {
    { f in let k = Int(at * fps) % f.count; return Array(f[k...] + f[..<k]) }
}

if args.count > 2, args[1] == "--clips" {
    let dir = URL(fileURLWithPath: args[2])
    let only = args.count > 3 ? Set(args[3].split(separator: ",").map(String.init)) : nil
    func want(_ n: String) -> Bool { only?.contains(n) ?? true }
    let idle = NowPlaying(probe: MediaRemoteSource.State())
    let closedSize = CGSize(width: 480, height: 72)
    let activitySize = CGSize(width: 640, height: 72)
    fakeBattery(82)

    // Closed notch, music playing: synthetic visualizer (2 s forward + reverse = ~4 s loop).
    model.isExpanded = false
    if want("visualizer") {
        record(dir, "visualizer", closedSize, seconds: 2.0, order: pingPong, onBlack(np))
    }

    // Volume HUD: level eases up and back down; one cosine period = seamless.
    HUDSettings.shared.showLabel = false
    HUDSettings.shared.showPercentage = true
    HUDSettings.shared.linkStyles = false
    HUDSettings.shared.volumeStyle = .gradient
    if want("volume") {
        let s = HUDLevel(kind: .volume); s.level = 0.25
        model.present(LiveActivity(key: HUDKind.volume.key, extraWidth: HUDLayout.extraWidth(settings: HUDSettings.shared)) {
            HUDLeading(state: s)
        } trailing: { HUDTrailing(state: s) }, duration: nil)
        record(dir, "volume", activitySize, seconds: 3.0, step: { t in
            let v = 0.25 + 0.6 * (1 - cos(2 * .pi * t / 3.0)) / 2
            s.level = (v * 16).rounded() / 16 // key-press steps, like the real volume keys
        }, onBlack(idle))
        model.dismissActivity(key: HUDKind.volume.key)
        pump(0.8)
    }

    // Activities: appear, hold, close, empty, then loop; rotated so frame 0 shows the activity.
    func activityClip(_ name: String, _ a: LiveActivity, size: CGSize, seconds: Double = 3.6, hold: Double = 2.4) {
        guard want(name) else { return }
        var shown = false, gone = false
        record(dir, name, size, seconds: seconds, step: { t in
            if !shown, t >= 0.1 { shown = true; model.present(a, duration: nil) }
            if !gone, t >= 0.1 + hold { gone = true; model.dismissActivity(key: a.key) }
        }, order: rotated(1.0), onBlack(idle))
        model.dismissActivity(key: a.key)
        pump(0.8)
    }
    activityClip("charging", ActivityViews.charging(level: 76, minutesToFull: 38, hidePercent: false), size: activitySize)
    let pods = BluetoothMonitor.Device(address: "00-00-00-00-00-01", name: "AirPods Pro", kind: .airpodsPro, battery: nil,
                                       buds: BluetoothMonitor.Buds(left: 84, right: 79, chargingCase: 62))
    activityClip("airpods", ActivityViews.bluetooth(pods, connected: true), size: activitySize)
    let otp = NotificationItem(record: NotificationRecord(recID: 2, bundleID: "it.bloop.airmail2", title: "Lumen Bank",
                                                          subtitle: "Your sign-in code",
                                                          body: "Your verification code is 482913. It expires in 10 minutes.",
                                                          delivered: Date()), detectCodes: true)
    activityClip("notification", NotificationViews.activity(.single(otp), expanded: false, locked: false, redact: false,
                                                            actions: NotificationActions()),
                 size: CGSize(width: 640, height: 130))

    // Expanded Home, music playing. Rate 4 so the seek bar visibly advances (one 4 s step per second).
    if want("home") {
        var s2 = st
        s2.rate = 4; s2.elapsed = 62; s2.timestamp = Date()
        let fast = NowPlaying(probe: s2)
        model.tab = .home
        model.isExpanded = true
        // Re-pin the fake battery every frame: the live monitor would otherwise show this Mac's real level.
        fakeBattery(82)
        record(dir, "home", CGSize(width: 680, height: 190), seconds: 5.0, settle: 2.5,
               step: { _ in fakeBattery(82) }, onBlack(fast))
        model.isExpanded = false
    }

    UserDefaults.standard.removePersistentDomain(forName: "perchshots")
    exit(0)
}

// a. Expanded, Home tab.
fakeBattery(82)
model.tab = .home
model.isExpanded = true
render("home", wide, wait: 2) { Desktop { notch() } }

// f. Calendar tab.
model.tab = .calendar
render("calendar", wide, wait: 1.5) { Desktop { notch() } }

// b. Closed, music playing.
model.isExpanded = false
render("closed-music", strip, wait: 1.5) { Desktop { notch() } }

// c. HUDs.
HUDSettings.shared.showLabel = false
HUDSettings.shared.showPercentage = true
func hud(_ kind: HUDKind, _ level: Double) -> LiveActivity {
    let s = HUDLevel(kind: kind); s.level = level
    return LiveActivity(key: kind.key, extraWidth: HUDLayout.extraWidth(settings: HUDSettings.shared)) {
        HUDLeading(state: s)
    } trailing: { HUDTrailing(state: s) }
}
HUDSettings.shared.linkStyles = false
HUDSettings.shared.volumeStyle = .gradient
HUDSettings.shared.brightnessStyle = .segmented
model.present(hud(.volume, 0.62), duration: nil)
render("hud-volume", strip) { Desktop { notch() } }
model.present(hud(.brightness, 0.75), duration: nil)
render("hud-brightness", strip) { Desktop { notch() } }
model.dismissActivity(key: "hud.brightness")

// d. Live activities.
let charging = ActivityViews.charging(level: 76, minutesToFull: 38, hidePercent: false)
model.present(charging, duration: nil)
render("charging", strip, wait: 2) { Desktop { notch() } }
model.dismissActivity(key: charging.key)
let pods = BluetoothMonitor.Device(address: "00-00-00-00-00-01", name: "AirPods Pro", kind: .airpodsPro, battery: nil,
                                   buds: BluetoothMonitor.Buds(left: 84, right: 79, chargingCase: 62))
let bt = ActivityViews.bluetooth(pods, connected: true)
model.present(bt, duration: nil)
render("airpods", strip, wait: 2.5) { Desktop { notch() } }
model.dismissActivity(key: bt.key)

// e. Notification with a one-time code.
let otp = NotificationItem(record: NotificationRecord(recID: 2, bundleID: "it.bloop.airmail2", title: "Lumen Bank",
                                                      subtitle: "Your sign-in code",
                                                      body: "Your verification code is 482913. It expires in 10 minutes.",
                                                      delivered: Date()), detectCodes: true)
let note = NotificationViews.activity(.single(otp), expanded: false, locked: false, redact: false, actions: NotificationActions())
model.present(note, duration: nil)
render("notification", CGSize(width: 900, height: 150), wait: 1.5) { Desktop { notch() } }
model.dismissActivity(key: note.key)

// g. Settings window, composed (sidebar + pane) on the wallpaper.
SettingsNavigation.shared.pane = .huds
struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { c in
                Circle().fill(c).frame(width: 12, height: 12)
            }
        }
    }
}
render("settings", CGSize(width: 1000, height: 660), wait: 1.5) {
    ZStack {
        Wallpaper()
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TrafficLights().padding(.leading, 20).frame(height: 52)
                SettingsSidebar()
            }
            .frame(width: 220)
            .background(Color(white: 0.16))
            Rectangle().fill(Color.black.opacity(0.6)).frame(width: 1)
            SettingsPaneView(pane: .huds)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Color(white: 0.12))
        }
        .environmentObject(AppSettings.shared).environmentObject(LaunchAtLogin.shared)
        .environmentObject(GestureSettings.shared).environmentObject(SettingsNavigation.shared)
        .environment(\.controlActiveState, .key)
        .frame(width: 820, height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
    }
}

UserDefaults.standard.removePersistentDomain(forName: "perchshots")
