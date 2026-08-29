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

    /// Wraps `bar` in an `NSGlassEffectView` for real glass occlusion —
    /// confirmed live, by a controlled same-geometry A/B capture, that a
    /// bare `ChromeBarView` gets no occlusion of its own: scrolled text
    /// passed through it sharp and fully legible, where the wrapper turns
    /// that into the frosted, blurred pass-through real Liquid Glass shows.
    /// `bar` becomes its `contentView`; `bar` itself still paints no
    /// material of its own (`ChromeBarView.isGlass`), since the glass now
    /// lives one level up — a single glass layer, not glass-on-glass.
    ///
    /// The wrapper is hosted as a plain `containerView` subview (see
    /// `Document`/`FindController`), the same way as pre-26 — **not** as an
    /// `NSTitlebarAccessoryViewController`, despite that being the first
    /// approach tried here. Measured live in full screen with a repro
    /// script (`-debug.reproScript`'s `logglass`, extended to print each
    /// accessory's screen-space frame and ancestor chain): an accessory's
    /// view gets reparented into a separate `NSToolbarFullScreenWindow`
    /// along with the rest of the titlebar/toolbar, and that window parks
    /// off-screen above the display whenever the system auto-hides the
    /// toolbar (`AppSettings.autoHideToolbar`, on by default) — so an open
    /// find/format bar vanished completely, with the reserved
    /// `additionalTopInset` left as blank space where it used to be.
    /// `NSTitlebarAccessoryViewController.fullScreenMinHeight` does not
    /// prevent this: set either at construction or on every layout pass,
    /// the accessory's screen-space origin measured identical to the
    /// retracted toolbar window's either way. A `containerView` child is
    /// immune to the whole mechanism, exactly as it was pre-26.
    @available(macOS 26.0, *)
    static func wrap(_ bar: ChromeBarView) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.contentView = bar
        return glass
    }
}
