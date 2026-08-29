import AppKit

/// macOS 26 "Liquid Glass" gated chrome helpers.
///
/// The deployment target stays macOS 14 (`Package.swift`) — Liquid Glass is
/// gated on the *linked SDK*, not the minimum OS, and macOS 14/15 must render
/// byte-identical Aqua chrome regardless of what SDK a build links. So every
/// 26-only code path lives behind an explicit `@available(macOS 26.0, *)`
/// here rather than being assumed at the call site.
///
/// **Hosting.** Both bars are plain `containerView` subviews, the same way as
/// pre-26 — **not** `NSTitlebarAccessoryViewController`s, despite that being
/// the first approach tried here, and despite the capsules below making them
/// look like toolbar items. Measured live in full screen with a repro script
/// (`-debug.reproScript`'s `logglass`, extended to print each accessory's
/// screen-space frame and ancestor chain): an accessory's view gets
/// reparented into a separate `NSToolbarFullScreenWindow` along with the rest
/// of the titlebar/toolbar, and that window parks off-screen above the
/// display whenever the system auto-hides the toolbar
/// (`AppSettings.autoHideToolbar`, on by default) — so an open find/format
/// bar vanished completely, with the reserved `additionalTopInset` left as
/// blank space where it used to be.
/// `NSTitlebarAccessoryViewController.fullScreenMinHeight` does not prevent
/// this: set either at construction or on every layout pass, the accessory's
/// screen-space origin measured identical to the retracted toolbar window's
/// either way. A `containerView` child is immune to the whole mechanism,
/// exactly as it was pre-26.
///
/// **The titlebar keeps its own material.** `titlebarAppearsTransparent`
/// stays `false` (see `Document.makeWindowControllers`) even though Notes and
/// Pages let body text run sharp through the titlebar between their capsules.
/// Their windows have opaque sidebars and short toolbars; Edmund's body text
/// runs edge to edge under the *whole* titlebar, and that is precisely the
/// unreadable-smear the capsules here were adopted to fix. Adopting Apple's
/// capsules is not a reason to also adopt that flag.
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

    // MARK: - Metrics
    //
    // Proportions read off macOS 26's own apps (Mail, Notes, Pages, Photos,
    // Calendar): chrome is not a bar, it is a row of floating rounded glass
    // capsules with the document visible between them. Everything below is
    // one place so the format bar and the find bar stay on the same grid.

    /// A capsule's height. The bar controls are 18pt, so this is that plus
    /// 6pt of glass above and below — the ratio Apple's toolbar groups use.
    static let capsuleHeight: CGFloat = 30

    /// Glass to the left and right of a capsule's first and last control.
    static let capsulePadding: CGFloat = 9

    /// The gap between two adjacent capsules.
    static let capsuleGap: CGFloat = 10

    /// Clearance between a floating capsule row and whatever is above and
    /// below it, so the row reads as hovering over the document rather than
    /// as a strip welded to the chrome.
    static let barMargin: CGFloat = 7

    /// The find bar's panel is inset from the window's side edges the way
    /// Mail's is, rather than running edge to edge.
    static let panelSideInset: CGFloat = 10

    /// A wide panel gets a rounded rectangle, not a capsule: at find-bar
    /// width and two-row height, `height / 2` would bow the short edges into
    /// something that reads as a lozenge.
    static let panelCornerRadius: CGFloat = 14

    // MARK: - Construction

    /// One floating glass capsule around `content`.
    ///
    /// `.regular`, not `.clear`: clear glass is for content that supplies its
    /// own contrast (a video scrubber), and over black-on-white body text it
    /// vanishes. The frosting that makes text passing underneath unreadable
    /// is what `.regular` is for.
    ///
    /// Capsules are also *why* the chrome reads as glass at all. The
    /// full-bleed `NSGlassEffectView` this replaced spanned the whole window
    /// width and had almost no edge specular or corner highlight per unit
    /// area, so scrolled text passed through it near-legible — the reported
    /// bug. A 100pt capsule is nearly all edge.
    @available(macOS 26.0, *)
    static func capsule(_ content: NSView, cornerRadius: CGFloat) -> NSGlassEffectView {
        let glass = NSGlassEffectView()
        glass.contentView = content
        glass.cornerRadius = cornerRadius
        glass.style = .regular
        return glass
    }

    /// Groups sibling capsules so AppKit renders them in a single pass.
    ///
    /// `spacing` stays at its default zero — the value that batches the
    /// capsules without fusing them. A first attempt set it above
    /// `capsuleGap` on the theory that merging is the point of the container;
    /// captured live, that welded all five groups into one continuous pill
    /// with faint necks between them, losing the grouping that tells Bold
    /// from Bulleted List at a glance. Merging is for capsules that *move*
    /// toward each other; a static row wants batching only.
    @available(macOS 26.0, *)
    static func container(_ content: NSView) -> NSGlassEffectContainerView {
        let container = NSGlassEffectContainerView()
        container.contentView = content
        return container
    }

    /// Wraps `view` in a plain box that holds it `inset` from every edge.
    ///
    /// Required, not stylistic: `NSGlassEffectView` sizes its `contentView` to
    /// its own bounds and ignores constraints pinning that content inside the
    /// glass — captured live, the find bar's search field ran flush into the
    /// panel's left edge with its rounded bezel clipped. The inset has to come
    /// from a view the glass does not manage.
    static func padded(_ view: NSView, by inset: NSEdgeInsets) -> NSView {
        let box = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset.left),
            view.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset.right),
            view.topAnchor.constraint(equalTo: box.topAnchor, constant: inset.top),
            view.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset.bottom),
        ])
        return box
    }

    /// Click-through for the empty glass-free area of a floating bar.
    ///
    /// A floating capsule row still needs a full-width host view to centre
    /// itself in, and that host would otherwise eat every click landing in
    /// the document *beside* the capsules — a 44pt-tall invisible dead strip
    /// across the window, which is worse than the full-bleed bar it replaced
    /// (at least that one looked like it was there). Returns `nil` unless
    /// `point` is inside a descendant that actually draws.
    ///
    /// The hosting is why this can't just be `NSView.hitTest`'s default:
    /// both `ChromeBarView` and the `NSGlassEffectContainerView` inside it
    /// span the full width, so the capsules' own frames are the only honest
    /// answer to "is there chrome here".
    @available(macOS 26.0, *)
    static func hit(_ point: NSPoint, inCapsulesOf view: NSView) -> Bool {
        for capsule in capsules(in: view)
        where capsule.convert(capsule.bounds, to: view.superview).contains(point) {
            return true
        }
        return false
    }

    /// Every glass view in `view`'s subtree — the capsules of a format bar,
    /// or the single panel of a find bar.
    @available(macOS 26.0, *)
    static func capsules(in view: NSView) -> [NSGlassEffectView] {
        var found: [NSGlassEffectView] = []
        var stack = view.subviews
        while let next = stack.popLast() {
            if let glass = next as? NSGlassEffectView { found.append(glass) }
            else { stack.append(contentsOf: next.subviews) }
        }
        return found
    }
}
