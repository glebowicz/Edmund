import Testing
import AppKit
@testable import edmd

/// A hidden bar must not leave its glass behind.
///
/// `Document.layoutTopBars()` stacks the bars by their *host* — the bar itself
/// pre-26, an `NSGlassEffectView` wrapping it on 26+ (`GlassChrome.wrap`).
/// Visibility used to be set on the bar alone, which pre-26 hid the host too
/// because they were the same object. On 26+ it only empties the wrapper's
/// `contentView`: the wrapper keeps painting a bar-shaped slab of glass with
/// no controls in it, parked by its `.minYMargin` autoresizing mask at its
/// distance from the top of the window it was added to — a frosted band
/// floating across the middle of the document as the window grows (reported
/// live, with the find bar closed, on a resized window).
@MainActor
@Suite("Glass bar visibility")
struct GlassBarVisibilityTests {

    /// Drives a real document window through the format bar's on/off states
    /// and asserts the host tracks the bar every time.
    @Test("A hidden bar hides its host, a shown one shows it")
    func hostTracksBarVisibility() throws {
        let showFormatBar = AppSettings.showFormatBar
        defer { AppSettings.showFormatBar = showFormatBar }

        let doc = Document()
        doc.makeWindowControllers()
        let formatHost = try #require(doc.formatBarHost)
        let findHost = try #require(doc.findController.barHost)

        // The find bar starts closed, so its host must start hidden — this is
        // the state the ghost band was reported in.
        #expect(findHost.isHidden)

        AppSettings.showFormatBar = true
        doc.refreshFormatBar()
        // On 26+ the format controls are toolbar items (`FormatToolbarGroups`),
        // so the bar itself never shows however the setting reads — that is the
        // whole point of the move, and a bar that unhides here has taken its
        // 44pt band back.
        #expect(formatHost.isHidden == FormatToolbar.usesToolbarFormatGroups)

        AppSettings.showFormatBar = false
        doc.refreshFormatBar()
        #expect(formatHost.isHidden)
        #expect(findHost.isHidden)
    }

    /// The format bar's five control groups each get their own capsule on
    /// 26+ — the grouping *is* the glass, so a change that collapses them
    /// into one pill (which a too-large container `spacing` did once, live)
    /// or drops a group has to fail here.
    @Test("The format bar is five separate capsules on 26+, none pre-26")
    func formatBarIsFiveCapsules() throws {
        guard #available(macOS 26.0, *) else { return }
        let bar = FormatBarView(frame: NSRect(x: 0, y: 0, width: 800, height: 44))
        bar.layoutSubtreeIfNeeded()
        let capsules = GlassChrome.capsules(in: bar)

        guard ChromeBarView.isGlass else {
            #expect(capsules.isEmpty, "legacy chrome must carry no glass")
            return
        }
        #expect(capsules.count == 5)
        for capsule in capsules {
            // Fully rounded: a capsule, not a rounded rectangle.
            #expect(capsule.cornerRadius == GlassChrome.capsuleHeight / 2)
            #expect(capsule.frame.height == GlassChrome.capsuleHeight)
        }
        // Laid out in one row with a real gap, not overlapping or fused.
        let frames = capsules.map { $0.convert($0.bounds, to: bar) }
            .sorted { $0.minX < $1.minX }
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(right.minX - left.maxX == GlassChrome.capsuleGap)
        }
    }

    /// A floating capsule row spans the window but only *owns* the capsules.
    /// Without the `hitTest` override the bar is a full-width invisible dead
    /// strip: the pointer stops being an I-beam and a click that visibly
    /// lands on a paragraph moves no caret. Pre-26 the bar is an opaque strip
    /// that legitimately owns every point in it, so it must still swallow.
    @Test("Clicks beside the capsules fall through to the document")
    func emptyBarAreaIsClickThrough() throws {
        guard #available(macOS 26.0, *) else { return }
        let width: CGFloat = 800
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 400))
        let bar = FormatBarView(frame: NSRect(x: 0, y: 0, width: width,
                                              height: FormatBarView.glassBarHeight))
        container.addSubview(bar)
        bar.layoutSubtreeIfNeeded()

        let midY = bar.frame.midY
        // Far left of a centred row: document, on 26+.
        let outside = NSPoint(x: 8, y: midY)
        // Dead centre lands in the middle capsule.
        let inside = NSPoint(x: bar.frame.midX, y: midY)

        guard ChromeBarView.isGlass else {
            #expect(bar.hitTest(outside) != nil, "the legacy strip owns its whole width")
            return
        }
        #expect(bar.hitTest(outside) == nil)
        #expect(bar.hitTest(inside) != nil)
    }
}
