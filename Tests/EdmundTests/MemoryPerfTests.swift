import Testing
import AppKit
import Darwin
@testable import EdmundCore

/// Memory growth measurements, gated behind `MD_PERF=1` like the other timing
/// harnesses — local trend tracking, never a CI gate. `.serialized` because
/// Swift Testing runs tests in one process in parallel by default and
/// `phys_footprint` is whole-process state: a concurrently-running test would
/// contaminate every reading here. Also run in your own process
/// (`swift test --filter MemoryPerf`) to keep the rest of the suite's
/// allocations out of the baseline entirely.
///
/// Metric is `phys_footprint` via `task_info(TASK_VM_INFO)`, not RSS — RSS
/// overstates via shared/purgeable pages; footprint is what macOS actually
/// accounts to this process (and what Xcode's memory gauge shows).
@Suite("Memory perf (MD_PERF)", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["MD_PERF"] != nil))
struct MemoryPerfTests {

    private func mark(_ s: String) {
        FileHandle.standardError.write(Data("[MD_MEM] …\(s)\n".utf8))
    }

    /// Current phys_footprint in bytes, or 0 if the call fails (never happens
    /// in practice — kept non-throwing so callers can use it in arithmetic
    /// without unwrapping).
    private func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    /// Drains the run loop briefly so deferred deallocation (TextKit 2
    /// fragments, CoreGraphics backing stores) settles before a reading —
    /// same technique as `settleCPUMS` in `SettingsPerfComparisonTests`.
    private func settle() {
        autoreleasepool {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func mb(_ bytes: some BinaryInteger) -> Double {
        Double(bytes) / 1_048_576
    }

    /// `fixtureURL` sets `document.fileURL` so the fixture's relative local
    /// image paths (`resolveImageURL`) actually resolve — without it every
    /// image reference is `.blocked(.notFound)` and `imageDisplay` never
    /// reaches the decode/cache line at all, silently.
    @MainActor
    private func windowedEditor(loading source: String, fixtureURL: URL) -> EditorTextView {
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

    // MARK: - undoStack unbounded-growth hypothesis

    /// `undoStack` (`EditorTextView.swift:131`) is cleared only in
    /// `loadContent`, and each entry holds a full copy of `rawSource`.
    /// Coalescing groups by (edit type, active block), and `"\n"` always
    /// classifies as `.other`, opening a fresh group — so a scripted session
    /// of many short lines should push roughly one whole-document copy per
    /// line. This test measures whether that's true; it does not fix it —
    /// any fix is separate future work on its own branch (see the plan this
    /// was built from).
    @Test("undoStack growth across a scripted typing session")
    @MainActor func undoStackGrowth() throws {
        let fixtureURL = fixturesDirectory.appendingPathComponent("perf-real-40k.md")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let editor = windowedEditor(loading: source, fixtureURL: fixtureURL)

        let docBytesBefore = (editor.rawSource as NSString).length
        settle()
        let before = physFootprintBytes()

        // 40 lines, each its own undo group (typed text, then Enter). The
        // hypothesis is confirmed by counting bytes actually held in
        // undoStack (below), not by session length — a longer session only
        // buys slower iteration.
        let length = (editor.rawSource as NSString).length
        editor.setSelectedRange(NSRange(location: length, length: 0))
        editor.recomposeIncremental(cursorInRaw: length)
        mark("typing 40 lines")
        for i in 0..<40 {
            type("Scripted session line \(i) — some ordinary prose to type.", into: editor)
            pressEnter(in: editor)
        }

        settle()
        let after = physFootprintBytes()

        let undoCount = editor.undoStack.count
        let redoCount = editor.redoStack.count
        let docBytesAfter = (editor.rawSource as NSString).length
        // The actual claim, counted directly rather than inferred from
        // phys_footprint: phys_footprint after a churny session is the
        // allocator's high-water mark (malloc doesn't return freed pages
        // promptly), not live retained bytes — not a signal to assert on
        // here. This is deterministic and allocator-noise-free.
        let retainedBytes = editor.undoStack.reduce(0) { $0 + $1.rawSource.utf8.count }
        let growthMB = mb(after) - mb(before)

        print("""
        [MD_MEM] undoStack entries:      \(undoCount)
        [MD_MEM] redoStack entries:      \(redoCount)
        [MD_MEM] document size before:   \(String(format: "%8.2f", mb(docBytesBefore))) MB
        [MD_MEM] document size after:    \(String(format: "%8.2f", mb(docBytesAfter))) MB
        [MD_MEM] undoStack retained:     \(String(format: "%8.2f", mb(retainedBytes))) MB (\(retainedBytes) bytes, summed rawSource copies)
        [MD_MEM] phys_footprint before:  \(String(format: "%8.2f", mb(before))) MB
        [MD_MEM] phys_footprint after:   \(String(format: "%8.2f", mb(after))) MB  (high-water mark, informational only)
        [MD_MEM] footprint growth:       \(String(format: "%8.2f", growthMB)) MB  (informational only)
        """)

        // Sanity only — this is a measurement, not a budget. undoCount should
        // be on the order of the number of lines typed (each Enter opens a
        // fresh group); a huge multiple would mean coalescing broke, a huge
        // undershoot would mean snapshots aren't being pushed at all.
        #expect(undoCount > 20, "expected roughly one undo group per typed line, got \(undoCount)")
        #expect(undoCount < 120, "expected roughly one undo group per typed line, got \(undoCount)")
        // Confirms the hypothesis structurally, not statistically: the
        // document only grows during this session, so every retained
        // snapshot's rawSource is at least as large as the document was
        // before typing started — this bound holds exactly, with zero
        // allocator noise, whether or not it's ever fixed.
        #expect(retainedBytes >= undoCount * docBytesBefore,
                "undoStack holds \(retainedBytes) bytes across \(undoCount) entries — expected at least \(undoCount * docBytesBefore) if each retains a full document-sized rawSource copy")
    }

    // MARK: - imageCache unbounded-growth hypothesis

    /// `imageCache` (`EditorTextView+ImageRendering.swift:31`) is a
    /// process-global `[String: NSImage]`, intentionally not `NSCache`
    /// (evicting an already-loaded remote badge flashed it back to a
    /// placeholder and re-triggered a fetch, tripping shields.io rate
    /// limits — a real, sound reason). The consequence: once an editor loads
    /// an image, it stays decoded in memory for the rest of the process, even
    /// after every editor that ever displayed it is deallocated. This
    /// measures that consequence; the reasoning for keeping it is sound, so
    /// this is not a "fix on sight" — see the plan this was built from.
    @Test("imageCache outlives the editor that populated it")
    @MainActor func imageCacheOutlivesEditor() throws {
        let fixtureURL = fixturesDirectory.appendingPathComponent("perf-real-40k.md")
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        // DebugMetrics.global.imageDecodes and imageCache are both
        // process-global and NOT reset here — a prior test in this same
        // process (undoStackGrowth also loads this fixture) may already have
        // decoded and cached these exact images, in which case this test's
        // own "first" load finds them already cached and adds no new
        // decodes. That's not a broken measurement; it's the same
        // unbounded-retention signature this test exists to show, just
        // observed one editor generation earlier than expected. So the
        // decode-happened check below is deliberately an absolute, whole-
        // process count ("has decoding happened at all by now"), not a delta
        // scoped to this test's own first load.
        settle()
        let before = physFootprintBytes()

        autoreleasepool {
            _ = windowedEditor(loading: source, fixtureURL: fixtureURL)
        }
        let decodesAfterFirstLoad = DebugMetrics.global.imageDecodes

        settle()
        let afterEditorReleased = physFootprintBytes()

        mark("loading the same corpus in a second, throwaway editor")
        autoreleasepool {
            _ = windowedEditor(loading: source, fixtureURL: fixtureURL)
        }
        let decodesAfterSecondLoad = DebugMetrics.global.imageDecodes
        settle()
        let afterSecondEditorReleased = physFootprintBytes()

        print("""
        [MD_MEM] imageDecodes after 1st load:       \(decodesAfterFirstLoad)
        [MD_MEM] imageDecodes after 2nd load:       \(decodesAfterSecondLoad)
        [MD_MEM] phys_footprint before:             \(String(format: "%8.2f", mb(before))) MB  (informational only — see below)
        [MD_MEM] phys_footprint after 1st released: \(String(format: "%8.2f", mb(afterEditorReleased))) MB
        [MD_MEM] phys_footprint after 2nd released: \(String(format: "%8.2f", mb(afterSecondEditorReleased))) MB
        """)

        // If the fixture's images were never decoded at all (e.g. document
        // path resolution broken), the second assertion below would pass
        // vacuously (0 == 0) without proving anything — check decode
        // actually happened first — an absolute, whole-process count (see
        // the comment above): it may be > 0 from this test's own first load,
        // or already > 0 from an earlier test's load of the same fixture.
        // Either way it proves the decode path is reachable at all.
        #expect(decodesAfterFirstLoad > 0,
                "expected the fixture's local images to have decoded by now; imageDisplay never reached the decode path")

        // The cache is keyed by resolved file path, and both editors load the
        // exact same fixture — a second editor should find every image
        // already cached (zero new decodes) despite the first editor being
        // fully deallocated. That's the unbounded-retention signature: the
        // decode work isn't repeated because the decoded NSImages never left.
        #expect(decodesAfterSecondLoad == decodesAfterFirstLoad,
                "second load of the same images re-decoded \(decodesAfterSecondLoad - decodesAfterFirstLoad) of them — cache did not retain across editor deallocation")

        // phys_footprint is deliberately not asserted on here — it's the
        // allocator's high-water mark (see undoStackGrowth above), and two
        // freshly-allocated-then-released NSWindow/NSScrollView/EditorTextView
        // graphs churn enough that the images' few MB is lost in the noise.
        // The decode-count assertions above are the actual, deterministic
        // proof that the cache outlives its editor.
    }
}
