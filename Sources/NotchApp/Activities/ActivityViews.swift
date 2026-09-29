import SwiftUI

/// LiveActivity builders for the Activities module. All keys start with `activity.`.
enum ActivityViews {
    static let symbolSize: CGFloat = 13.5
    static let textFont = Font.system(size: 12, weight: .semibold)
    static let charging = Color(red: 0.30, green: 0.85, blue: 0.39)
    static let low = Color(red: 1.0, green: 0.27, blue: 0.23)

    /// ActivitySettings "Animated device visuals"; off = the static symbol views.
    static var animated: Bool { ActivitySettings.shared.animatedVisuals }

    static func batterySymbol(_ level: Int) -> String {
        switch level {
        case 88...: "battery.100"
        case 63..<88: "battery.75"
        case 38..<63: "battery.50"
        case 13..<38: "battery.25"
        default: "battery.0"
        }
    }

    // MARK: Power

    static let lowPowerYellow = Color(red: 1.0, green: 0.80, blue: 0.0)
    static let focusIndigo = Color(red: 0.49, green: 0.47, blue: 1.0)

    /// "3h 24m", "24m".
    static func duration(minutes m: Int) -> String {
        m >= 60 ? "\(m / 60)h \(String(format: "%02d", m % 60))m" : "\(m)m"
    }

    /// Width for a trailing value group: percent and/or time.
    private static func powerWidth(percent: Bool, time: Bool) -> CGFloat {
        switch (percent, time) {
        case (true, true): 170
        case (false, true): 120
        case (true, false): 100
        case (false, false): 60
        }
    }

    static func charging(level: Int, minutesToFull: Int?, hidePercent: Bool) -> LiveActivity {
        LiveActivity(key: "activity.power",
                     extraWidth: powerWidth(percent: !hidePercent, time: minutesToFull != nil)) {
            if animated {
                BatteryVisual(level: level, tint: charging, bolt: true).id("power.charging")
            } else {
                Symbol(name: "battery.100.bolt", color: charging)
            }
        } trailing: {
            PowerValue(level: hidePercent ? nil : level, minutes: minutesToFull, color: charging)
        }
    }

    static func unplugged(level: Int, minutesToEmpty: Int?, hidePercent: Bool) -> LiveActivity {
        LiveActivity(key: "activity.power",
                     extraWidth: powerWidth(percent: !hidePercent, time: minutesToEmpty != nil)) {
            if animated {
                BatteryVisual(level: level, tint: .white).id("power.unplugged")
            } else {
                Symbol(name: batterySymbol(level), color: .white)
            }
        } trailing: {
            PowerValue(level: hidePercent ? nil : level, minutes: minutesToEmpty, color: .white)
        }
    }

    /// 100%, or charging paused at a charge limit (e.g. Optimized Charging at 80%).
    static func fullyCharged(level: Int, hidePercent: Bool) -> LiveActivity {
        LiveActivity(key: "activity.power", extraWidth: hidePercent ? 180 : 220) {
            HStack(spacing: 6) {
                if animated {
                    BatteryVisual(level: level, tint: charging, bolt: true).id("power.full")
                } else {
                    Symbol(name: "battery.100.bolt", color: charging)
                }
                Text(level >= 100 ? "Fully Charged" : "Charged").font(textFont).foregroundStyle(charging)
                    .lineLimit(1).fixedSize()
            }
        } trailing: {
            if !hidePercent { Percent(level: level, color: charging) }
        }
    }

    static func lowBattery(level: Int, critical: Bool, minutesToEmpty: Int?, hidePercent: Bool) -> LiveActivity {
        LiveActivity(key: "activity.lowbattery",
                     extraWidth: 170 + powerWidth(percent: !hidePercent, time: minutesToEmpty != nil) - 30) {
            HStack(spacing: 6) {
                if animated {
                    BatteryVisual(level: level, tint: low, pulse: true).id("power.low.\(critical)")
                } else {
                    Symbol(name: batterySymbol(level), color: low)
                }
                Text(critical ? "Battery Critical" : "Low Battery").font(textFont).foregroundStyle(low)
                    .lineLimit(1).fixedSize()
            }
        } trailing: {
            PowerValue(level: hidePercent ? nil : level, minutes: minutesToEmpty, color: low)
        }
    }

    static func lowPowerMode(on: Bool) -> LiveActivity {
        LiveActivity(key: "activity.lowpower", extraWidth: 200) {
            HStack(spacing: 6) {
                Symbol(name: "battery.50", color: on ? lowPowerYellow : .white)
                Text("Low Power").font(textFont).lineLimit(1).fixedSize()
            }
        } trailing: {
            StateLabel(on: on)
        }
    }

    // MARK: Focus

    static func focus(on: Bool, name: String?, symbol: String?) -> LiveActivity {
        let title = name ?? "Focus"
        // ~7pt per character at 12pt semibold, plus symbol, "On/Off" and padding.
        let width = min(320, 110 + CGFloat(title.count) * 7)
        return LiveActivity(key: "activity.focus", extraWidth: width) {
            HStack(spacing: 6) {
                Symbol(name: symbol ?? "moon.fill", color: on ? focusIndigo : .white)
                Text(title).font(textFont).lineLimit(1).fixedSize()
            }
        } trailing: {
            StateLabel(on: on)
        }
    }

    // MARK: Lock

    static func unlocked() -> LiveActivity {
        LiveActivity(key: "activity.unlock", extraWidth: 60) {
            Symbol(name: "lock.open.fill", color: .white)
        } trailing: {
            EmptyView()
        }
    }

    // MARK: Bluetooth

    static func bluetooth(_ d: BluetoothMonitor.Device, connected: Bool) -> LiveActivity {
        guard animated else {
            return LiveActivity(key: "activity.bluetooth", extraWidth: 230) {
                Symbol(name: d.kind.symbol, color: .white)
            } trailing: {
                DeviceLabel(name: d.name, battery: connected ? d.battery : nil)
            }
            .dimmed(!connected)
        }
        // AirPods with per-bud readings: L / R / case row below, name alone on the right.
        let buds = connected ? d.buds.flatMap { $0.hasBuds ? $0 : nil } : nil
        let activity = LiveActivity(key: "activity.bluetooth", extraWidth: 230) {
            DeviceVisual(kind: d.kind, entrance: connected).id("bt.\(d.address).\(connected)")
        } trailing: {
            DeviceLabel(name: d.name, battery: connected && buds == nil ? d.battery : nil)
        }
        guard let buds else { return activity.dimmed(!connected) }
        return activity.withBelow(height: 24) { BudsBatteryRow(kind: d.kind, buds: buds) }
    }

    static func deviceLowBattery(_ d: BluetoothMonitor.Device, level: Int) -> LiveActivity {
        LiveActivity(key: "activity.devicebattery", extraWidth: 250) {
            if animated {
                DeviceVisual(kind: d.kind, tint: low, pulse: true).id("btlow.\(d.address)")
            } else {
                Symbol(name: d.kind.symbol, color: low)
            }
        } trailing: {
            HStack(spacing: 5) {
                Text(d.name).font(textFont).lineLimit(1).truncationMode(.tail)
                Text("\(level)%").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(low).fixedSize()
            }
        }
    }

    // MARK: Track change

    static func trackPeek(_ np: NowPlaying) -> LiveActivity {
        LiveActivity(key: "activity.track", extraWidth: 100) {
            TrackArtwork(np: np)
        } trailing: {
            Equalizer().frame(width: 18, height: 12)
        }
        .withBelow(height: 34) {
            VStack(spacing: 1) {
                Text(np.title).font(.system(size: 12, weight: .semibold))
                Text(np.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
        }
    }
}

private extension LiveActivity {
    func dimmed(_ on: Bool) -> LiveActivity {
        guard on else { return self }
        var copy = self
        copy.leading = AnyView(leading.opacity(0.45))
        copy.trailing = AnyView(trailing.opacity(0.45))
        return copy
    }
}

private struct Symbol: View {
    let name: String
    let color: Color

    var body: some View {
        Image(systemName: name)
            .font(.system(size: ActivityViews.symbolSize, weight: .medium))
            .foregroundStyle(color)
            .fixedSize()
    }
}

/// Device name, plus battery % when given.
private struct DeviceLabel: View {
    let name: String
    let battery: Int?

    var body: some View {
        HStack(spacing: 5) {
            Text(name).font(ActivityViews.textFont).lineLimit(1).truncationMode(.tail)
            if let b = battery {
                Text("\(b)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(b <= 20 ? ActivityViews.low : .white.opacity(0.6))
                    .fixedSize()
            }
        }
    }
}

private struct Percent: View {
    let level: Int
    let color: Color

    var body: some View {
        Text("\(level)%")
            .font(ActivityViews.textFont)
            .monospacedDigit()
            .foregroundStyle(color)
            .fixedSize()
    }
}

/// Percent and/or time remaining ("88%  3h 24m"); either may be absent.
private struct PowerValue: View {
    let level: Int?
    let minutes: Int?
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            if let level { Percent(level: level, color: color) }
            if let minutes {
                Text(ActivityViews.duration(minutes: minutes))
                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.55)).fixedSize()
            }
        }
    }
}

private struct StateLabel: View {
    let on: Bool

    var body: some View {
        Text(on ? "On" : "Off").font(ActivityViews.textFont)
            .foregroundStyle(.white.opacity(on ? 1 : 0.55)).fixedSize()
    }
}

/// Artwork (or player icon) that follows NowPlaying, in case the artwork lands after the title.
private struct TrackArtwork: View {
    @ObservedObject var np: NowPlaying

    var body: some View {
        Group {
            if let img = np.artwork ?? np.appIcon {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}
