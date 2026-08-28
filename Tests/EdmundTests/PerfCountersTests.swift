import Testing
import AppKit
@testable import EdmundCore

/// The CI perf-regression gate. Unlike `PerfHarnessTests` / `ScrollPerfHarnessTests`
/// / `SettingsPerfComparisonTests` (all `MD_PERF`-gated, all report milliseconds,
/// none fail), this suite runs on every `swift test` and asserts on counted
/// work — integers, immune to thermal state, machine, and backing scale — never
/// on elapsed time. See the design note at the top of `DebugMetrics.swift`.
///
/// Every scenario uses `makePerfEditor()` (the pinned "maximal" settings
/// profile) and the real, feature-dense `perf-real-40k.md` corpus — never
/// `makeEditor()`'s empty defaults domain, which measures the shipped
/// defaults and nothing else.
///
/// Bounds below were measured directly against this fixture on 2026-08-28
/// (three repeats, identical each time — these are deterministic counts, not
/// noisy timings). A bound with real headroom is intentional: it exists to
/// catch a step-function regression (an incremental path silently falling
/// back to a full one), not to pin the exact number forever.
@Suite("Perf counters (CI gate)")
struct PerfCountersTests {

    /// Loads the pinned corpus into a windowed, maximal-profile editor and
    /// drains styling to convergence — the same shape `PerfHarnessTests` and
    /// `ScrollPerfHarnessTests` use, minus the MD_PERF gate.
    @MainActor
    private func loadedEditor() throws -> EditorTextView {
        let fixtureURL = fixturesDirectory.appendingPathComponent("perf-real-40k.md")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let editor = makePerfEditor()
        let doc = NSDocument()
        doc.fileURL = fixtureURL
        editor.document = doc

        let viewport = NSSize(width: 700, height: 800)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: viewport),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.frame = NSRect(origin: .zero, size: viewport)
        editor.textContainer?.size = NSSize(width: viewport.width, height: .greatestFiniteMagnitude)

        editor.loadContent(source)
        drainAllStyling(editor, maxSlices: 100_000)
        editor.layout()
        return editor
    }

    /// Places the caret/selection at the start of the block nearest the
    /// document's midpoint and primes `activeBlockIndex` there, so the first
    /// measured edit isn't also paying for the initial cursor-move restyle.
    @MainActor
    private func seekToMiddle(_ editor: EditorTextView) -> Int {
        let length = (editor.rawSource as NSString).length
        let midBlock = editor.blockIndexForRawOffset(length / 2) ?? 0
        let loc = editor.blocks[midBlock].range.location
        editor.setSelectedRange(NSRange(location: loc, length: 0))
        editor.recomposeIncremental(cursorInRaw: loc)
        return loc
    }

    // MARK: - Scenario 1: steady-state typing

    @Test("Typing 50 characters mid-document stays incremental")
    @MainActor func steadyStateTyping() throws {
        let editor = try loadedEditor()
        _ = seekToMiddle(editor)

        editor.debugMetrics.reset()
        for _ in 0..<50 { type("x", into: editor) }
        let m = editor.debugMetrics

        #expect(m.fullRecomposes == 0)
        // One recomposeDirty per keystroke; the caret never leaves the block,
        // so it's always a 1-block dirty set. Measured 50/50.
        #expect(m.dirtyRecomposes == 50)
        #expect(m.blocksRestyled <= 100, "blocksRestyled=\(m.blocksRestyled), measured 50")
    }

    // MARK: - Scenario 2: Enter mid-document

    @Test("Enter mid-document splits a block without a full recompose")
    @MainActor func enterMidDocument() throws {
        let editor = try loadedEditor()
        let loc = seekToMiddle(editor) + 5
        editor.setSelectedRange(NSRange(location: loc, length: 0))
        editor.recomposeIncremental(cursorInRaw: loc)

        editor.debugMetrics.reset()
        pressEnter(in: editor)
        let m = editor.debugMetrics

        #expect(m.fullRecomposes == 0)
        #expect(m.blocksRestyled <= 10, "blocksRestyled=\(m.blocksRestyled), measured 2")
        // "\n" always classifies as .other in classifyEdit, so Enter always
        // opens a fresh undo group.
        #expect(m.undoSnapshotsPushed == 1)
    }

    // MARK: - Scenario 3: undo coalescing

    @Test("A run of keystrokes in one block coalesces into one undo snapshot")
    @MainActor func undoCoalescing() throws {
        let editor = try loadedEditor()
        _ = seekToMiddle(editor)

        editor.debugMetrics.reset()
        for _ in 0..<50 { type("x", into: editor) }

        // Guards recordUndoIfNeeded's (edit type, active block) coalescing key
        // — a change that breaks it turns every keystroke into a full
        // document copy on the undo stack.
        #expect(editor.debugMetrics.undoSnapshotsPushed == 1)
    }

    // MARK: - Scenario 4 & 6: paste formatted markdown, then undo it

    @Test("Pasting ~10KB of formatted markdown mid-document, then undoing it")
    @MainActor func pasteFormattedMarkdownAndUndo() throws {
        let editor = try loadedEditor()
        _ = seekToMiddle(editor)

        // Deliberately formatted, not flat prose: a table, a fenced code
        // block, a nested list, a callout, and inline emphasis — so the paste
        // engages the block parser and the styling path, not just a
        // paragraph append. Repeated to reach ~10KB.
        var chunk = "\n\n"
        for i in 0..<40 {
            chunk += """
            ## Pasted section \(i)

            | Col A | Col B | Col C |
            |---|---|---|
            | \(i) | \(i * 2) | \(i * 3) |

            - top level \(i)
              - nested \(i)
                - deep \(i)

            > [!tip]
            > A callout, pasted, number \(i).

            ```swift
            let value\(i) = \(i) * 2
            print(value\(i))
            ```

            Some **bold** and *italic* text with `inline code` number \(i).

            """
        }
        #expect((chunk as NSString).length > 9_000)

        editor.debugMetrics.reset()
        paste(chunk, into: editor)
        let pasteMetrics = (
            fullRecomposes: editor.debugMetrics.fullRecomposes,
            dirtyBlocksRequested: editor.debugMetrics.dirtyBlocksRequested,
            dirtyBlocksDeferred: editor.debugMetrics.dirtyBlocksDeferred,
            blocksRestyled: editor.debugMetrics.blocksRestyled,
            undoSnapshotsPushed: editor.debugMetrics.undoSnapshotsPushed
        )

        #expect(pasteMetrics.fullRecomposes == 0)
        // ~40 pasted sections parse into several hundred new blocks, all
        // requested for styling at once (most deferred to the idle drain).
        // Bounded well below "every block in the document" (680).
        #expect(pasteMetrics.dirtyBlocksRequested <= 600,
                "dirtyBlocksRequested=\(pasteMetrics.dirtyBlocksRequested), measured 523")
        // Pins the dirty.count > 8 sync/defer split in recomposeDirty: only a
        // small synchronous slice restyles immediately, the rest defers to the
        // idle drain. Without the split, dirtyBlocksDeferred collapses to 0 and
        // blocksRestyled jumps to match dirtyBlocksRequested.
        #expect(pasteMetrics.dirtyBlocksDeferred > 400,
                "dirtyBlocksDeferred=\(pasteMetrics.dirtyBlocksDeferred), measured 522")
        #expect(pasteMetrics.blocksRestyled <= 20,
                "blocksRestyled=\(pasteMetrics.blocksRestyled), measured 1")
        #expect(pasteMetrics.undoSnapshotsPushed == 1)

        // Undo of the paste must route through recomposeReplacing, not a full
        // recompose — a full recompose there resets every TextKit 2 fragment
        // to an estimate and the follow-up scroll lands wrong (the contract
        // fixed in commit 5bb2b40).
        editor.debugMetrics.reset()
        editor.performUndo()
        let undoMetrics = editor.debugMetrics
        #expect(undoMetrics.rangedRecomposes == 1)
        #expect(undoMetrics.fullRecomposes == 0)
    }

    // MARK: - Scenario 5: formatting commands

    @Test("Bold/italic/list-toggle/indent/outdent each do exactly one ranged recompose")
    @MainActor func formattingCommands() throws {
        let editor = try loadedEditor()
        let loc = seekToMiddle(editor)

        func assertOneRangedRecompose(_ label: String, _ body: () -> Void,
                                      sourceLocation: SourceLocation = #_sourceLocation) {
            editor.debugMetrics.reset()
            body()
            let m = editor.debugMetrics
            #expect(m.fullRecomposes == 0, "\(label): fullRecomposes", sourceLocation: sourceLocation)
            #expect(m.rangedRecomposes == 1, "\(label): rangedRecomposes", sourceLocation: sourceLocation)
            #expect(m.undoSnapshotsPushed == 1, "\(label): undoSnapshotsPushed", sourceLocation: sourceLocation)
        }

        editor.setSelectedRange(NSRange(location: loc, length: 4))
        assertOneRangedRecompose("bold") { editor.formatBold(nil) }

        editor.setSelectedRange(NSRange(location: loc, length: 4))
        assertOneRangedRecompose("italic") { editor.formatItalic(nil) }

        editor.setSelectedRange(NSRange(location: loc, length: 0))
        assertOneRangedRecompose("list toggle") { editor.formatBulletedList(nil) }

        // Tab/Shift-Tab only route through the indent path (recomposeReplacing)
        // when every block the selection covers is a list line — find a real
        // consecutive run of list items in the fixture rather than assume
        // the midpoint lands on one.
        var listStart: Int?, listEnd: Int?
        for (i, b) in editor.blocks.enumerated() {
            if case .listItem = b.kind {
                if listStart == nil { listStart = i }
                listEnd = i
                if listEnd! - listStart! >= 3 { break }
            } else if listStart != nil {
                break
            }
        }
        guard let ls = listStart, let le = listEnd else {
            Issue.record("no consecutive list-item run found in perf-real-40k.md")
            return
        }
        let listSel = NSRange(location: editor.blocks[ls].range.location,
                              length: editor.blocks[le].range.upperBound - editor.blocks[ls].range.location)

        editor.setSelectedRange(listSel)
        assertOneRangedRecompose("tab indent (multi-line)") { editor.insertTab(nil) }

        assertOneRangedRecompose("shift-tab outdent (multi-line)") { editor.insertBacktab(nil) }
    }

    // MARK: - Scenario 7: scroll promotion

    @Test("Scrolling into unstyled territory restyles only the viewport window")
    @MainActor func scrollPromotionStaysBounded() throws {
        let editor = try loadedEditor()
        guard let scroll = editor.enclosingScrollView else {
            Issue.record("no enclosing scroll view")
            return
        }
        let totalHeight = editor.frame.height
        #expect(totalHeight > 1000, "expected a laid-out multi-screen document")

        // Simulate scrolling into territory the idle drain hasn't reached yet.
        for i in editor.blocks.indices where i > editor.blocks.count / 2 {
            editor.blocks[i].isStyled = false
        }
        let unstyledBefore = editor.blocks.filter { !$0.isStyled }.count

        let clip = scroll.contentView
        clip.scroll(to: NSPoint(x: 0, y: totalHeight * 0.65))
        scroll.reflectScrolledClipView(clip)

        editor.debugMetrics.reset()
        editor.promoteVisibleUnstyledBlocks()
        let m = editor.debugMetrics

        // Bounded by the viewport window, not the whole unstyled tail — and
        // must actually do something (promotion silently no-op'ing, e.g. from
        // an unlaid-out viewport, would satisfy the upper bound vacuously).
        // Measured 45 restyled out of 234 unstyled — well under half.
        #expect(m.blocksRestyled > 0, "promotion restyled nothing")
        #expect(m.blocksRestyled < unstyledBefore / 2,
                "blocksRestyled=\(m.blocksRestyled) of \(unstyledBefore) unstyled — promotion should not style the whole tail")
    }

    // MARK: - Scenario 8: typing while the drain is still running

    @Test("Typing while the idle drain is mid-flight stays incremental")
    @MainActor func typingDuringDrain() throws {
        let fixtureURL = fixturesDirectory.appendingPathComponent("perf-real-40k.md")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let editor = makePerfEditor()
        let doc = NSDocument()
        doc.fileURL = fixtureURL
        editor.document = doc

        let viewport = NSSize(width: 700, height: 800)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: viewport),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        scroll.documentView = editor
        win.contentView = scroll
        win.makeFirstResponder(editor)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.frame = NSRect(origin: .zero, size: viewport)
        editor.textContainer?.size = NSSize(width: viewport.width, height: .greatestFiniteMagnitude)

        editor.loadContent(source)
        // Only a few slices — leaves most blocks unstyled, drain still pending.
        for _ in 0..<3 { editor.drainStylingSlice() }
        let unstyled = editor.blocks.filter { !$0.isStyled }.count
        #expect(unstyled > 0, "expected the drain to still have work left")

        let length = (editor.rawSource as NSString).length
        editor.setSelectedRange(NSRange(location: length, length: 0))
        editor.recomposeIncremental(cursorInRaw: length)

        editor.debugMetrics.reset()
        type("x", into: editor)
        let m = editor.debugMetrics

        // The edit path must stay incremental — it must not fall back to a
        // full recompose (which would re-mark every block unstyled and
        // restart the drain from scratch) just because a drain is in flight.
        #expect(m.fullRecomposes == 0)
        #expect(m.rangedRecomposes == 0)
        #expect(m.dirtyRecomposes == 1)
    }
}
