import AppKit

/// macOS 26 "Liquid Glass" gated chrome helpers.
///
/// The deployment target stays macOS 14 (`Package.swift`) — Liquid Glass is
/// gated on the *linked SDK*, not the minimum OS, and macOS 14/15 must render
/// byte-identical Aqua chrome regardless of what SDK a build links. So every
/// 26-only code path lives behind an explicit `@available(macOS 26.0, *)`
/// here rather than being assumed at the call site.
@MainActor
enum GlassChrome {

    /// `-debug.forceLegacyChrome YES` makes every `#available(macOS 26.0, *)`
    /// gate in this migration take its pre-26 branch even when actually
    /// running on 26+ — the only way to exercise and capture the legacy
    /// chrome on a machine whose SDK/OS are both 26. Always checked alongside
    /// `#available`, never instead of it: Swift's availability checking is
    /// syntactic, so a call site still needs the real `#available` wrapping
    /// it to use a 26-only API — this flag only decides which side of that
    /// check callers take.
    static var forceLegacyChrome: Bool {
        UserDefaults.standard.bool(forKey: "debug.forceLegacyChrome")
    }

    /// Wraps `bar` as a bottom titlebar accessory so it becomes part of the
    /// same continuous glass surface as the toolbar — "always avoid glass on
    /// glass" (WWDC25 "Meet Liquid Glass") rules out a second material layer
    /// stacked under it.
    ///
    /// The accessory's own `view` is an `NSGlassEffectView`, not `bar`
    /// directly. Confirmed live, by a controlled same-geometry A/B capture
    /// (`glass-09` vs. `glass-07`/`glass-08`): hosting `bar` directly gives it
    /// no occlusion of its own — scrolled text passed through the icon row
    /// sharp and fully legible. Wrapping it in `NSGlassEffectView` turns that
    /// into the frosted, blurred pass-through real Liquid Glass shows. `bar`
    /// becomes its `contentView`; `bar` itself still paints no material of
    /// its own (`ChromeBarView.isGlass`), since the glass now lives one level
    /// up. Default `.regular` style — `.clear` was tried and is barely
    /// distinguishable from no wrapper at all, since it's the low-occlusion
    /// variant.
    ///
    /// `automaticallyAdjustsSize = false`: the default snaps a bottom
    /// accessory to a fixed system height, which would clip the find bar's
    /// taller Replace row and override the format bar's deliberate 28pt.
    /// Height is driven by `bar.preferredHeight` instead, kept current by
    /// `sync(bar:accessory:)` on every layout pass.
    @available(macOS 26.0, *)
    static func makeAccessory(for bar: ChromeBarView) -> NSTitlebarAccessoryViewController {
        let glass = NSGlassEffectView()
        glass.contentView = bar

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = glass
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = false
        accessory.isHidden = bar.isHidden
        // Kept as correct configuration for a scroll-edge accessory, though
        // measured live to make no visible difference on its own — the
        // `NSGlassEffectView` wrapper above is what actually stops the
        // bleed-through. 26.1-only, a narrower gate than the rest of this
        // migration.
        if #available(macOS 26.1, *) {
            accessory.preferredScrollEdgeEffectStyle = .soft
        }
        return accessory
    }

    /// Re-reads `bar`'s current height/visibility into its accessory.
    ///
    /// Also sets `fullScreenMinHeight`, which defaults to 0 — designed for
    /// cosmetic accessories, not a bar the user just opened with ⌘F. Without
    /// this, an open find/format bar is fully clipped the moment full screen
    /// auto-hides the menu bar.
    @available(macOS 26.0, *)
    static func sync(bar: ChromeBarView, accessory: NSTitlebarAccessoryViewController) {
        accessory.isHidden = bar.isHidden
        let height = bar.isHidden ? 0 : bar.preferredHeight
        // `accessory.view` is the `NSGlassEffectView` wrapper, not `bar`.
        // Both are resized explicitly here rather than leaning on `bar`'s
        // autoresizing mask — that mask is `[.width, .minYMargin]`, set by
        // `Document`/`FindController` to pin the bar pre-26, and is load-
        // bearing there; this path must not depend on overwriting it.
        var frame = accessory.view.frame
        frame.size.height = height
        accessory.view.frame = frame
        bar.frame = NSRect(origin: .zero, size: frame.size)
        accessory.fullScreenMinHeight = height
    }
}
