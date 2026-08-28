import Testing
import AppKit
@testable import EdmundCore

/// Per-frame scroll cost on a real document, gated behind `MD_PERF=1`.
///
/// Unlike `PerfHarnessTests` (which measures edit-pipeline latency), this
/// harness measures what a scroll frame actually costs: viewport layout **and
/// rasterization**. Forcing the draw matters — `DecoratedTextLayoutFragment.draw`
/// is where overlays (images, callout boxes, list guides) are painted, and a
/// layout-only benchmark never runs it, so it cannot see draw-path regressions
/// at all.
///
///   MD_PERF=1 MD_PERF_FILE=/path/to/doc.md swift test --filter ScrollPerf
///   MD_PERF_NO_IMAGES=1   strip `![...](...)` lines — the A/B that says
///                         whether images or text decoration dominate
@Suite("Scroll perf harness (MD_PERF)",
       .enabled(if: ProcessInfo.processInfo.environment["MD_PERF"] != nil))
struct ScrollPerfHarnessTests {

    static let env = ProcessInfo.processInfo.environment
    /// 120 fps leaves 8.33 ms for layout + draw of one frame.
    static let frameBudgetMS = 1000.0 / 120.0

    private func mark(_ s: String) {
        FileHandle.standardError.write(Data("[MD_SCROLL] …\(s)\n".utf8))
    }

    /// Rewrites relative image destinations to absolute paths. The editor
    /// resolves relative images against `document?.fileURL`, which a test
    /// editor has no business owning — absolute paths load the very same files.
    private func absolutizeImages(_ source: String, relativeTo dir: URL) -> String {
        var out = source
        let pattern = #"!\[([^\]]*)\]\(([^)]+)\)"#
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = source as NSString
        for m in re.matches(in: source, range: NSRange(location: 0, length: ns.length)).reversed() {
            let dest = ns.substring(with: m.range(at: 2))
            guard !dest.hasPrefix("/"), !dest.contains("://") else { continue }
            let abs = dir.appendingPathComponent(dest).path
            let alt = ns.substring(with: m.range(at: 1))
            out = (out as NSString).replacingCharacters(in: m.range, with: "![\(alt)](\(abs))")
        }
        return out
    }

    private func stripImages(_ source: String) -> String {
        let re = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
        let ns = source as NSString
        return re.stringByReplacingMatches(
            in: source, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    @Test("Per-frame scroll cost (layout + rasterization)")
    @MainActor func scrollFrameCost() throws {
        guard let path = Self.env["MD_PERF_FILE"] else {
            Issue.record("set MD_PERF_FILE to the document to scroll")
            return
        }
        let url = URL(fileURLWithPath: path)
        var source = try String(contentsOf: url, encoding: .utf8)
        source = absolutizeImages(source, relativeTo: url.deletingLastPathComponent())
        let imagesStripped = Self.env["MD_PERF_NO_IMAGES"] != nil
        if imagesStripped { source = stripImages(source) }

        // A realistic editor window.
        let viewport = NSSize(width: 900, height: 800)
        let win = NSWindow(contentRect: NSRect(origin: .zero, size: viewport),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        let editor = makeEditor()
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

        mark("loading \(source.count) chars")
        editor.loadContent(source)
        mark("draining styling")
        drainAllStyling(editor, maxSlices: 100_000)
        editor.layout()

        let docHeight = max(editor.frame.height, viewport.height)
        let clip = scroll.contentView

        // One reusable backing store, so allocation isn't inside the timed
        // region. Its pixel size tells us the backing scale we actually got —
        // an offscreen window can be 1x, which would understate resampling
        // cost roughly fourfold against a Retina display.
        let visible = NSRect(origin: .zero, size: viewport)
        guard let rep = editor.bitmapImageRepForCachingDisplay(in: visible) else {
            Issue.record("no bitmap rep for caching display")
            return
        }
        let backingScale = CGFloat(rep.pixelsWide) / visible.width

        let clock = ContinuousClock()
        func ms(_ body: () -> Void) -> Double {
            let d = clock.measure(body)
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }
        var frames: [Double] = []
        var scrollMS: [Double] = [], layoutMS: [Double] = [], drawMS: [Double] = []
        let step: CGFloat = 40          // ~ one trackpad scroll tick
        // Repeat the sweep to give an external profiler (`sample <pid>`) a long
        // enough window; one pass over a 3000 pt document is under two seconds.
        let repeats = Self.env["MD_SCROLL_REPEAT"].flatMap(Int.init) ?? 1
        var y: CGFloat = 0
        mark("scrolling \(Int(docHeight)) pt x\(repeats)")
        for _ in 0..<repeats {
        y = 0
        while y + viewport.height < docHeight {
            let a = ms {
                clip.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
            }
            let b = ms { editor.layout() }
            let c = ms {
                editor.cacheDisplay(in: NSRect(x: 0, y: y, width: viewport.width,
                                               height: viewport.height), to: rep)
            }
            scrollMS.append(a); layoutMS.append(b); drawMS.append(c)
            frames.append(a + b + c)
            y += step
        }
        }

        guard !frames.isEmpty else {
            Issue.record("document too short to scroll")
            return
        }
        let sorted = frames.sorted()
        func pct(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
        let over = frames.filter { $0 > Self.frameBudgetMS }.count
        func med(_ xs: [Double]) -> Double {
            let s = xs.sorted(); return s[s.count / 2]
        }

        print("""
        [MD_SCROLL] file:            \(url.lastPathComponent)\(imagesStripped ? "  (IMAGES STRIPPED)" : "")
        [MD_SCROLL] chars:           \(source.count), blocks: \(editor.blocks.count)
        [MD_SCROLL] doc height:      \(Int(docHeight)) pt, viewport \(Int(viewport.width))x\(Int(viewport.height))
        [MD_SCROLL] backing scale:   \(backingScale)x  (rep \(rep.pixelsWide)x\(rep.pixelsHigh) px)
        [MD_SCROLL] frames:          \(frames.count)
        [MD_SCROLL] median:          \(String(format: "%8.2f", pct(0.50))) ms
        [MD_SCROLL] p95:             \(String(format: "%8.2f", pct(0.95))) ms
        [MD_SCROLL] max:             \(String(format: "%8.2f", sorted.last!)) ms
        [MD_SCROLL] mean:            \(String(format: "%8.2f", frames.reduce(0,+) / Double(frames.count))) ms
        [MD_SCROLL] over 8.33ms:     \(over)/\(frames.count) frames (\(Int(100.0 * Double(over) / Double(frames.count)))%)
        [MD_SCROLL] --- median split of one frame ---
        [MD_SCROLL] scroll+notify:   \(String(format: "%8.2f", med(scrollMS))) ms
        [MD_SCROLL] layout():        \(String(format: "%8.2f", med(layoutMS))) ms
        [MD_SCROLL] rasterize:       \(String(format: "%8.2f", med(drawMS))) ms
        """)

        #expect(frames.count > 0)
    }
}
