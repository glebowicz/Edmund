import Testing
import AppKit
import EdmundCore
@testable import edmd

/// The format bar's controls, after the move into the toolbar row on 26+
/// (`FormatToolbarGroups`). Two things have to hold: nothing the bar could do
/// got dropped on the way, and the bar's 44pt band is genuinely gone rather
/// than merely emptied.
@MainActor
@Suite("Format toolbar groups")
struct FormatToolbarGroupsTests {

    private let viewMode = NSToolbarItem.Identifier("viewMode")

    /// Every control the format bar draws has a counterpart in the toolbar: six
    /// inline styles, highlight, three list kinds, thematic break and block
    /// quote, plus the two pull-downs. Fourteen, the same fourteen.
    @Test func everyBarControlSurvivedTheMove() {
        guard FormatToolbar.usesToolbarFormatGroups else { return }
        let segments = FormatToolbar.formatGroups.flatMap(\.segments)
        #expect(segments.count + 2 == 14)
        for segment in segments {
            #expect(EditorTextView.formattingActions.contains(segment.action),
                    "\(segment.title) fires a selector the editor doesn't format with")
        }
        // The pull-downs are the two that cannot ride inside a segmented group.
        let ids = FormatToolbar.formatGroupIdentifiers
        #expect(ids.first == FormatToolbar.headingItem)
        #expect(ids.last == FormatToolbar.calloutItem)
    }

    /// Each segmented item is built by the convenience constructor, so AppKit
    /// makes one subitem per image — and `actions` has to line up with them or
    /// a click fires the wrong command.
    @Test func segmentsLineUpWithTheirActions() throws {
        guard FormatToolbar.usesToolbarFormatGroups else { return }
        let doc = Document()
        let bar = FormatToolbar(document: doc)
        for group in FormatToolbar.formatGroups {
            let item = try #require(bar.makeItem(group.id) as? NSToolbarItemGroup)
            #expect(bar.segmentActions[group.id] == group.segments.map(\.action))
            #expect(item.subitems.count == group.segments.count)
            #expect(bar.segmentPushed[group.id]?.count == group.segments.count)
            #expect(item.subitems.map(\.label) == group.segments.map(\.title))
        }
        // Both pull-downs carry a real menu, or the item draws an indicator
        // that opens nothing.
        for id in [FormatToolbar.headingItem, FormatToolbar.calloutItem] {
            let item = try #require(bar.makeItem(id) as? NSMenuToolbarItem)
            #expect(!(item.menu.items.isEmpty))
        }
    }

    /// Which segment was clicked is a diff against the last pushed selection,
    /// not `selectedIndex`. The case that forces it is turning a style *off*:
    /// `.selectAny`'s `selectedIndex` is "the most recently selected item, or
    /// -1", so a deselecting click reports either nothing or some other lit
    /// segment, and Bold-off would fire Italic or nothing at all.
    @Test func theDeselectingClickIsIdentifiedToo() {
        #expect(FormatToolbar.changedSegment(selected: [false, true, false],
                                             pushed: [false, false, false]) == 1)
        #expect(FormatToolbar.changedSegment(selected: [true, false, false],
                                             pushed: [true, true, false]) == 1)
        #expect(FormatToolbar.changedSegment(selected: [true], pushed: [true]) == nil)
        #expect(FormatToolbar.changedSegment(selected: [true], pushed: []) == nil)
    }

    /// The point of the move: turning the format controls on costs the editor
    /// nothing. Before, the same flip took a 44pt band of floating capsules off
    /// the top of the document.
    ///
    /// The inset is not zero either way — on 26+ the window is
    /// `.fullSizeContentView`, so `layoutTopBars` still reserves the toolbar's
    /// own height. What matters is that the two states are equal.
    @Test func showingTheFormatControlsCostsTheEditorNoHeight() throws {
        guard FormatToolbar.usesToolbarFormatGroups else { return }
        let original = AppSettings.showFormatBar
        defer { AppSettings.showFormatBar = original }

        let doc = Document()
        doc.makeWindowControllers()

        AppSettings.showFormatBar = false
        doc.refreshFormatBar()
        let off = doc.editor.additionalTopInset

        AppSettings.showFormatBar = true
        doc.refreshFormatBar()

        #expect(doc.editor.additionalTopInset == off)
        #expect(doc.formatBarHost.isHidden)
    }

    /// `View ▸ Show Format Bar` reaches the toolbar items rather than the bar.
    /// They stay *in* the toolbar either way — hiding, not removing, is what
    /// keeps `autosavesConfiguration` from rewriting the user's arrangement on
    /// every toggle.
    @Test func theToggleHidesTheToolbarItemsInPlace() throws {
        guard #available(macOS 26.0, *), FormatToolbar.usesToolbarFormatGroups else { return }
        let original = AppSettings.showFormatBar
        defer { AppSettings.showFormatBar = original }

        let doc = Document()
        doc.makeWindowControllers()
        let toolbar = try #require(doc.windowControllers.first?.window?.toolbar)
        let ids = Set(FormatToolbar.formatGroupIdentifiers)

        func formatItems() -> [NSToolbarItem] {
            toolbar.items.filter { ids.contains($0.itemIdentifier) }
        }

        AppSettings.showFormatBar = true
        doc.refreshFormatBar()
        #expect(formatItems().count == ids.count, "a format item left the toolbar")
        #expect(formatItems().allSatisfy { !$0.isHidden })

        AppSettings.showFormatBar = false
        doc.refreshFormatBar()
        #expect(formatItems().count == ids.count, "hiding removed items instead")
        #expect(formatItems().allSatisfy { $0.isHidden })
    }
}
