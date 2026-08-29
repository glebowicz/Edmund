import AppKit

// MARK: - Shared chrome bar base

/// A top bar that reads as window chrome: the titlebar material the toolbar
/// uses, plus a hairline along the bottom edge matching the toolbar separator.
/// Shared by the find bar and the format bar.
class ChromeBarView: NSVisualEffectView {

    /// The hairline along the bottom edge, matching the toolbar's separator so
    /// the bar reads as window chrome. A subview, not a `draw(_:)` override:
    /// `NSVisualEffectView` renders its material through layers and never calls
    /// through to a custom `draw`. Pinned to the bottom.
    private let bottomBorder = NSView()

    /// One device pixel. The hairline's thickness, and the amount by which the
    /// bar's visible interior is shorter than its bounds.
    static var hairlineHeight: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }

    /// The separator that lands on the bar's top edge — the toolbar's above the
    /// format bar, the format bar's own hairline above the find bar. It is not
    /// drawn by this view but it covers its first point, so the strip that
    /// reads as the bar starts below it.
    private static let topSeparatorHeight: CGFloat = 1

    /// The strip that actually reads as the bar. Pre-26 this is bounds less the
    /// separator on the top edge and the hairline drawn along the bottom —
    /// anything centred on the bar centres on this, since centring on `bounds`
    /// looks a point high (a point of those bounds is covered at the top and
    /// only half a point at the bottom). On 26+ this view draws neither, so
    /// there is nothing to subtract.
    var interior: NSRect {
        guard !Self.isGlass else { return bounds }
        return NSRect(x: 0, y: Self.hairlineHeight, width: bounds.width,
               height: max(0, bounds.height - Self.hairlineHeight - Self.topSeparatorHeight))
    }

    /// The bar's height for its active state (drives the content inset).
    /// `fittingSize` already carries the layout's top/bottom insets.
    var preferredHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    /// Whether this bar draws none of its own chrome and puts its controls in
    /// floating glass capsules instead (see `init` and `GlassChrome`).
    /// Internal, not private: both subclasses build a different control layout
    /// on each side of it.
    static var isGlass: Bool {
        if #available(macOS 26.0, *), !GlassChrome.forceLegacyChrome { return true }
        return false
    }

    /// A 1×1 fully transparent image. `NSVisualEffectView.maskImage` stretches
    /// across the view and masks only the *material* it draws — never
    /// subviews — so an all-clear image is the documented way to turn a
    /// visual-effect view's own backdrop off while keeping its content.
    private static let transparentMaskImage: NSImage = {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        image.lockFocus()
        NSColor.clear.set()
        // `.copy`, not the default `.sourceOver`: compositing clear color
        // *over* an already-opaque freshly-locked-focus bitmap would leave it
        // opaque. `.copy` overwrites the pixel (and its alpha) outright.
        NSRect(x: 0, y: 0, width: 1, height: 1).fill(using: .copy)
        image.unlockFocus()
        return image
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        if Self.isGlass {
            // The bar is a frame for floating glass, not a surface: its
            // controls ride in `NSGlassEffectView` capsules (see
            // `GlassChrome`) and the document shows through everywhere else.
            // Masking out this view's own material is what makes that "everywhere
            // else" actually transparent — a second material layer under the
            // capsules would be glass on glass (WWDC25 "Meet Liquid Glass"),
            // and it is also what turned a full-width strip into the smear the
            // capsules replaced. No hairline either, for the same reason.
            maskImage = Self.transparentMaskImage
            return
        }
        material = .titlebar
        // `.withinWindow`, not `.behindWindow`: behind-window blending samples
        // what is behind the *window* — the desktop — so the bar tracked the
        // wallpaper instead of the chrome. It looked right only because this
        // wallpaper happens to be near the light-mode chrome colour; in dark
        // mode the bar measured 40 levels lighter than the toolbar above it.
        blendingMode = .withinWindow
        // Follows the window, so the bar dims with the toolbar when the window
        // stops being key. `.active` pinned it bright on inactive windows.
        state = .followsWindowActiveState

        bottomBorder.wantsLayer = true
        bottomBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        bottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomBorder)
        NSLayoutConstraint.activate([
            bottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: Self.hairlineHeight),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Clicks landing in the bar's transparent area belong to the document
    /// underneath, not to the bar. Without this the floating capsule row is a
    /// full-width invisible dead strip: the pointer stops being an I-beam and
    /// a click that visibly lands on a paragraph moves no caret.
    ///
    /// Pre-26 the bar is an opaque strip that legitimately owns every point in
    /// it, so this defers to `super` there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard #available(macOS 26.0, *), Self.isGlass else { return super.hitTest(point) }
        guard GlassChrome.hit(point, inCapsulesOf: self) else { return nil }
        return super.hitTest(point)
    }

    /// Keeps the hairline's colour correct across a light/dark switch — a
    /// `cgColor` snapshot doesn't follow the appearance on its own. No-op on
    /// 26+, where there is no hairline.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard !Self.isGlass else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bottomBorder.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }
}
