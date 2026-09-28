import SwiftUI

/// Content drawn around the closed notch. `leading` sits left of the camera housing, `trailing`
/// right of it; `below` (optional) extends the black shape downward by `belowHeight` points.
struct LiveActivity {
    /// Identity for replace-in-place, e.g. "hud.volume", "charging", "calendar.upcoming".
    var key: String
    var leading: AnyView
    var trailing: AnyView
    /// Total width added to the notch (split evenly between both sides).
    var extraWidth: CGFloat = 90
    var below: AnyView? = nil
    var belowHeight: CGFloat = 0
    /// Has clickable content (e.g. a Join button): hovering won't auto-open the notch over it.
    var isInteractive = false

    init<L: View, T: View>(key: String, extraWidth: CGFloat = 90,
                           @ViewBuilder leading: () -> L, @ViewBuilder trailing: () -> T) {
        self.key = key
        self.extraWidth = extraWidth
        self.leading = AnyView(leading())
        self.trailing = AnyView(trailing())
    }

    func withBelow<B: View>(height: CGFloat, @ViewBuilder _ content: () -> B) -> LiveActivity {
        var copy = self
        copy.below = AnyView(content())
        copy.belowHeight = height
        return copy
    }

    func interactive() -> LiveActivity {
        var copy = self
        copy.isInteractive = true
        return copy
    }
}
