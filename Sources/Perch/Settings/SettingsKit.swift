import AppKit
import SwiftUI

// Shared building blocks for the Settings panes. Every pane is
// `SettingsPage(pane) { Section … }` so headers, rows, sliders and spacing stay consistent.

enum SettingsMetrics {
    /// Readable column width; wider windows get symmetric side margins instead of a stretched form.
    static let maxContentWidth: CGFloat = 680
    static let minSideMargin: CGFloat = 8
    static let detailFont: Font = .system(size: 11)
    static let sidebarWidth: CGFloat = 220
}

/// White SF Symbol on a colored rounded square, like System Settings.
struct SettingsIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: .black.opacity(size > 30 ? 0.18 : 0), radius: 2, y: 1)
    }
}

/// A pane: grouped Form with a header card on top, capped to a readable width.
struct SettingsPage<Content: View, Accessory: View>: View {
    let pane: SettingsPane
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ pane: SettingsPane, @ViewBuilder accessory: @escaping () -> Accessory,
         @ViewBuilder content: @escaping () -> Content) {
        self.pane = pane
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        GeometryReader { geo in
            let margin = max(SettingsMetrics.minSideMargin, (geo.size.width - SettingsMetrics.maxContentWidth) / 2)
            Form {
                Section {
                    SettingsPaneHeader(pane: pane, accessory: accessory)
                }
                content()
            }
            .formStyle(.grouped)
            .contentMargins(.horizontal, margin, for: .scrollContent)
        }
    }
}

extension SettingsPage where Accessory == EmptyView {
    init(_ pane: SettingsPane, @ViewBuilder content: @escaping () -> Content) {
        self.init(pane, accessory: { EmptyView() }, content: content)
    }
}

/// Top-of-pane card: large icon, title, one-line subtitle, optional trailing control (a master switch).
struct SettingsPaneHeader<Accessory: View>: View {
    let pane: SettingsPane
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: pane.symbol, color: pane.color, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(pane.title).font(.system(size: 17, weight: .semibold))
                Text(pane.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 6)
    }
}

/// Title with an optional secondary line underneath. Used as the label of rows and controls.
struct SettingLabel: View {
    let title: String
    var detail: String?
    var symbol: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(SettingsMetrics.detailFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Switch row with an optional description line.
struct SettingToggle: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) { SettingLabel(title: title, detail: detail) }
            .toggleStyle(.switch)
    }
}

/// Row with a label (title + detail) and arbitrary trailing content.
struct SettingRow<Trailing: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing
    }

    var body: some View {
        LabeledContent {
            trailing()
        } label: {
            SettingLabel(title: title, detail: detail)
        }
    }
}

/// Picker row. `.menu` for long lists, `.segmented` for 2–4 short choices.
struct SettingPicker<Value: Hashable, Options: View>: View {
    let title: String
    var detail: String?
    @Binding var selection: Value
    var segmented = false
    @ViewBuilder var options: () -> Options

    init(_ title: String, detail: String? = nil, selection: Binding<Value>, segmented: Bool = false,
         @ViewBuilder options: @escaping () -> Options) {
        self.title = title
        self.detail = detail
        _selection = selection
        self.segmented = segmented
        self.options = options
    }

    var body: some View {
        if segmented {
            LabeledContent {
                Picker(title, selection: $selection, content: options)
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
            } label: {
                SettingLabel(title: title, detail: detail)
            }
        } else {
            Picker(selection: $selection, content: options) {
                SettingLabel(title: title, detail: detail)
            }
            .pickerStyle(.menu)
        }
    }
}

/// Continuous slider (no tick marks) with a live value label and a reset button that appears
/// only when the value differs from its default. Values snap to `step`.
struct SettingSlider: View {
    let title: String
    var detail: String?
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let defaultValue: Double
    /// Shown instead of the formatted value while at the default (e.g. "Default").
    var defaultLabel: String?
    var minLabel: String?
    var maxLabel: String?
    let format: (Double) -> String

    init(_ title: String, detail: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double = 1, default defaultValue: Double, defaultLabel: String? = nil,
         minLabel: String? = nil, maxLabel: String? = nil, format: @escaping (Double) -> String) {
        self.title = title
        self.detail = detail
        _value = value
        self.range = range
        self.step = step
        self.defaultValue = defaultValue
        self.defaultLabel = defaultLabel
        self.minLabel = minLabel
        self.maxLabel = maxLabel
        self.format = format
    }

    private var isDefault: Bool { abs(value - defaultValue) < step / 2 }

    private var snapped: Binding<Double> {
        Binding(get: { value }, set: { v in
            let s = (v / step).rounded() * step
            let clamped = min(max(s, range.lowerBound), range.upperBound)
            if clamped != value { value = clamped }
        })
    }

    var body: some View {
        // Plain HStack (not LabeledContent) so a long description wraps instead of pushing the
        // slider onto its own line.
        HStack(alignment: .center, spacing: 12) {
            SettingLabel(title: title, detail: detail)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Slider(value: snapped, in: range) {
                    Text(title)
                } minimumValueLabel: {
                    Text(minLabel ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                } maximumValueLabel: {
                    Text(maxLabel ?? "").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .labelsHidden()
                .frame(width: 180)
                Text(isDefault ? (defaultLabel ?? format(value)) : format(value))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 54, alignment: .trailing)
                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Reset to default")
                .opacity(isDefault ? 0 : 1)
                .disabled(isDefault)
                .accessibilityHidden(isDefault)
            }
            .fixedSize()
        }
    }
}

/// Integer stepper row with the value shown next to it.
struct SettingStepper: View {
    let title: String
    var detail: String?
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let format: (Int) -> String

    init(_ title: String, detail: String? = nil, value: Binding<Int>, in range: ClosedRange<Int>, step: Int = 1,
         format: @escaping (Int) -> String = { "\($0)" }) {
        self.title = title
        self.detail = detail
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
                Stepper(title, value: $value, in: range, step: step).labelsHidden()
            }
        } label: {
            SettingLabel(title: title, detail: detail)
        }
    }
}

/// Small "+4 pt" style formatter for signed offsets.
func signedPoints(_ v: Double) -> String { "\(v > 0 ? "+" : "")\(Int(v.rounded())) pt" }

/// Section header with an optional secondary line (inside `Section { } header: { }`).
struct SectionHeader: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.system(size: 11, weight: .regular)).foregroundStyle(.secondary)
            }
        }
    }
}

/// Section footer text (secondary, wraps).
struct SectionFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(SettingsMetrics.detailFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Colored dot + label capsule, e.g. "Allowed" / "Not allowed".
struct StatusBadge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            } else {
                Circle().frame(width: 6, height: 6)
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Inline note row with an icon (info, warning) for context inside a section.
struct SettingNote: View {
    let text: String
    var symbol = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(SettingsMetrics.detailFont)
    }
}

/// Rounded "desktop" backdrop used by live previews (a sliver of wallpaper under the menu bar).
struct PreviewBackdrop<Content: View>: View {
    var height: CGFloat = 96
    var menuBarHeight: CGFloat = 24
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.30, green: 0.36, blue: 0.62),
                                    Color(red: 0.62, green: 0.42, blue: 0.62),
                                    Color(red: 0.93, green: 0.62, blue: 0.52)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar strip.
            Rectangle().fill(.white.opacity(0.18)).frame(height: menuBarHeight)
            content()
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.black.opacity(0.08)))
    }
}
