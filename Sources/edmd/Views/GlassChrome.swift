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
    /// `automaticallyAdjustsSize = false`: the default snaps a bottom
    /// accessory to a fixed system height, which would clip the find bar's
    /// taller Replace row and override the format bar's deliberate 28pt.
    /// Height is driven by `bar.preferredHeight` instead, kept current by
    /// `sync(bar:accessory:)` on every layout pass.
    @available(macOS 26.0, *)
    static func makeAccessory(for bar: ChromeBarView) -> NSTitlebarAccessoryViewController {
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = bar
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = false
        accessory.isHidden = bar.isHidden
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
        var frame = bar.frame
        frame.size.height = height
        bar.frame = frame
        accessory.fullScreenMinHeight = height
    }
}
