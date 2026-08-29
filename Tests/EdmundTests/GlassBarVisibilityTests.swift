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
        #expect(!formatHost.isHidden)

        AppSettings.showFormatBar = false
        doc.refreshFormatBar()
        #expect(formatHost.isHidden)
        #expect(findHost.isHidden)
    }
}
