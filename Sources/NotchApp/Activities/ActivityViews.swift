import SwiftUI

/// LiveActivity builders for the Activities module. All keys start with `activity.`.
enum ActivityViews {
    static let symbolSize: CGFloat = 13.5
    static let textFont = Font.system(size: 12, weight: .semibold)
    static let charging = Color(red: 0.30, green: 0.85, blue: 0.39)
    static let low = Color(red: 1.0, green: 0.27, blue: 0.23)

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

    static func charging(level: Int) -> LiveActivity {
        LiveActivity(key: "activity.power", extraWidth: 100) {
            Symbol(name: "battery.100.bolt", color: charging)
        } trailing: {
            Percent(level: level, color: charging)
        }
    }

    static func unplugged(level: Int) -> LiveActivity {
        LiveActivity(key: "activity.power", extraWidth: 100) {
            Symbol(name: batterySymbol(level), color: .white)
        } trailing: {
            Percent(level: level, color: .white)
        }
    }

    static func lowBattery(level: Int) -> LiveActivity {
        LiveActivity(key: "activity.lowbattery", extraWidth: 240) {
            HStack(spacing: 6) {
                Symbol(name: batterySymbol(level), color: low)
                Text("Low Battery").font(textFont).foregroundStyle(low).lineLimit(1).fixedSize()
            }
        } trailing: {
            Percent(level: level, color: low)
        }
    }

    // MARK: Bluetooth

    static func bluetooth(_ d: BluetoothMonitor.Device, connected: Bool) -> LiveActivity {
        LiveActivity(key: "activity.bluetooth", extraWidth: 230) {
            Symbol(name: d.kind.symbol, color: .white)
        } trailing: {
            HStack(spacing: 5) {
                Text(d.name).font(textFont).lineLimit(1).truncationMode(.tail)
                if connected, let b = d.battery {
                    Text("\(b)%").font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .foregroundStyle(b <= 20 ? low : .white.opacity(0.6))
                        .fixedSize()
                }
            }
        }
        .dimmed(!connected)
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
