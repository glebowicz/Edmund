import Testing
import AppKit
@testable import EdmundCore

/// Does the *user's* settings profile cost more than the shipped defaults?
///
/// `makeEditor()` deliberately gives every test an empty theme domain, so every
/// other perf harness here measures the **default** profile and nothing else.
/// This one loads a real exported `UserDefaults` plist and replays the same
/// workload under both, alternating rounds so drift and thermal state hit both
/// profiles equally.
///
///   MD_PERF=1 MD_PERF_FILE=/path/doc.md MD_PERF_USER_PLIST=/path/prod.plist \
///     swift test --filter SettingsPerfComparison
///
/// What it varies is exactly what the app layer pushes into an editor
/// (`AppSettings.applyEditSettings` + `EditorTheme.load` + `maxContentWidthPoints`),
/// reproduced here because `AppSettings` lives in the app target, not EdmundCore.
@Suite("Settings perf comparison (MD_PERF)",
       .enabled(if: ProcessInfo.processInfo.environment["MD_PERF"] != nil))
struct SettingsPerfComparisonTests {

    static let env = ProcessInfo.processInfo.environment
    static let frameBudgetMS = 1000.0 / 120.0

    /// The fallback in `NSScreen.physicalPPI`. Used here because a test process
    /// has no meaningful screen, and the cm→pt conversion has to come from
    /// somewhere; only the *ratio* between the two profiles matters.
    static let ppi: Double = 109

    private func mark(_ s: String) {
        FileHandle.standardError.write(Data("[MD_CMP] …\(s)\n".utf8))
    }

    struct Profile {
        let name: String
        let theme: EditorTheme
        let spellCheck: Bool
        let grammarCheck: Bool
        let contentWidthCm: Double
        let logging: Bool

        var contentWidthPoints: CGFloat {
            CGFloat(contentWidthCm) / 2.54 * CGFloat(SettingsPerfComparisonTests.ppi)
        }
    }

    struct Sample {
        var loadMS = 0.0
        var drainMS = 0.0
        var scrollMedianMS = 0.0
        var scrollP95MS = 0.0
        var scrollOver = 0
        var scrollFrames = 0
        var keystrokeMedianMS = 0.0
        var blocks = 0
        var docHeight = 0.0
        /// Whether `isContinuousSpellCheckingEnabled` actually stuck on the text
        /// view. AppKit silently refuses it in some configurations, which would
        /// make a null spell-check result meaningless rather than reassuring.
        var spellFlagStuck = false
        /// CPU burned during a fixed 0.5 s run-loop spin after load — where
        /// asynchronous spell/grammar checking would land if it runs at all.
        var settleCPUMS = 0.0
    }

    // MARK: - Profile construction

    /// A `UserDefaults` suite populated from an exported plist, so the user's
    /// real values go through the very same `EditorTheme.load` the app uses.
    private func defaultsSuite(named name: String, from plistPath: String?) -> UserDefaults {
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        if let plistPath,
           let dict = NSDictionary(contentsOf: URL(fileURLWithPath: plistPath)) as? [String: Any] {
            suite.setPersistentDomain(dict, forName: name)
        }
        return suite
    }

    private func makeProfiles() -> (defaults: Profile, user: Profile, userDomain: [String: Any]) {
        let defaultSuite = defaultsSuite(named: "EdmundCmp.default.\(UUID().uuidString)",
                                         from: nil)
        let userPlist = Self.env["MD_PERF_USER_PLIST"]
        let userSuiteName = "EdmundCmp.user.\(UUID().uuidString)"
        let userSuite = defaultsSuite(named: userSuiteName, from: userPlist)
        let domain = userSuite.persistentDomain(forName: userSuiteName) ?? [:]

        // Mirrors AppSettings: spell/grammar default off, content width 12 cm
        // outside US locales, logging off.
        let defaults = Profile(name: "defaults",
                               theme: .load(from: defaultSuite),
                               spellCheck: false,
                               grammarCheck: false,
                               contentWidthCm: 12.0,
                               logging: false)

        func bool(_ key: String) -> Bool { (domain[key] as? Bool) ?? false }
        let user = Profile(name: "user",
                           theme: .load(from: userSuite),
                           spellCheck: bool("settings.edit.spellCheck"),
                           grammarCheck: bool("settings.edit.grammarCheck"),
                           contentWidthCm: (domain["settings.appearance.maxContentWidthCm"]
                                            as? Double) ?? 12.0,
                           logging: bool("settings.general.diagnosticLogging"))
        return (defaults, user, domain)
    }

    // MARK: - Workload

    @MainActor
    private func run(_ profile: Profile, source: String, viewport: NSSize) -> Sample {
        var out = Sample()

        // Diagnostic logging writes to a real file on a serial queue. Point it
        // at a scratch directory — never the user's ~/.edmund/logs.
        let logDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("edmund-cmp-logs-\(UUID().uuidString)")
        Log.configure(enabled: profile.logging, directory: logDir, retention: nil)
        Log.setVerbose(false)
        defer { Log.configure(enabled: false, directory: logDir, retention: nil) }

        let win = NSWindow(contentRect: NSRect(origin: .zero, size: viewport),
                           styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: viewport))
        let editor = EditorTextView.makeTextKit2(
            frame: NSRect(origin: .zero, size: viewport),
            containerSize: NSSize(width: viewport.width, height: CGFloat.greatestFiniteMagnitude))
        let themeSuite = UserDefaults(suiteName: "EdmundCmpTheme.\(UUID().uuidString)")!
        editor.themeDefaults = themeSuite
        editor.theme = profile.theme

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

        // The rest of what AppSettings.applyEditSettings pushes in.
        editor.isContinuousSpellCheckingEnabled = profile.spellCheck
        editor.isGrammarCheckingEnabled = profile.grammarCheck
        editor.maxContentWidthPoints = profile.contentWidthPoints
        out.spellFlagStuck = editor.isContinuousSpellCheckingEnabled == profile.spellCheck

        let clock = ContinuousClock()
        func ms(_ body: () -> Void) -> Double {
            let d = clock.measure(body)
            return Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        out.loadMS = ms { editor.loadContent(source) }
        out.drainMS = ms { drainAllStyling(editor, maxSlices: 100_000) }
        editor.layout()
        out.blocks = editor.blocks.count

        let docHeight = max(editor.frame.height, viewport.height)
        out.docHeight = Double(docHeight)
        let clip = scroll.contentView
        let visible = NSRect(origin: .zero, size: viewport)
        guard let rep = editor.bitmapImageRepForCachingDisplay(in: visible) else { return out }

        var frames: [Double] = []
        var y: CGFloat = 0
        let step: CGFloat = 40
        while y + viewport.height < docHeight {
            let f = ms {
                clip.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
                editor.layout()
                editor.cacheDisplay(in: NSRect(x: 0, y: y, width: viewport.width,
                                               height: viewport.height), to: rep)
            }
            frames.append(f)
            y += step
        }
        if !frames.isEmpty {
            let s = frames.sorted()
            out.scrollFrames = s.count
            out.scrollMedianMS = s[s.count / 2]
            out.scrollP95MS = s[min(s.count - 1, Int(0.95 * Double(s.count)))]
            out.scrollOver = frames.filter { $0 > Self.frameBudgetMS }.count
        }

        // Continuous spell/grammar checking is asynchronous: AppKit schedules it
        // off the display cycle and applies the result later. A harness that
        // never spins the run loop would never run it, making a null result
        // meaningless. Spin a fixed wall-clock window and measure the CPU burned
        // inside it — that is what discriminates "free" from "never ran".
        let cpuBefore = processCPUMS()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        out.settleCPUMS = processCPUMS() - cpuBefore

        // Steady-state typing at the end of the document — the first keystroke
        // after a load absorbs one-time layout, so it is discarded.
        let length = (editor.rawSource as NSString).length
        editor.setSelectedRange(NSRange(location: length, length: 0))
        editor.recomposeIncremental(cursorInRaw: length)
        _ = ms { type("x", into: editor) }
        var keys: [Double] = []
        for _ in 0..<9 { keys.append(ms { type("x", into: editor) }) }
        out.keystrokeMedianMS = keys.sorted()[keys.count / 2]

        return out
    }

    // MARK: - The comparison

    @Test("Default settings vs the user's exported profile")
    @MainActor func compareProfiles() throws {
        guard let path = Self.env["MD_PERF_FILE"] else {
            Issue.record("set MD_PERF_FILE to the document to measure")
            return
        }
        let url = URL(fileURLWithPath: path)
        var source = try String(contentsOf: url, encoding: .utf8)
        source = absolutizeImagesForComparison(source,
                                               relativeTo: url.deletingLastPathComponent())

        let (defaultsProfile, userProfile, domain) = makeProfiles()

        // A silent font fallback would measure the system font while claiming to
        // measure the user's — assert both faces actually resolve.
        let bodyResolved = NSFont(name: userProfile.theme.fontName,
                                  size: userProfile.theme.fontSize) != nil
        let monoResolved = userProfile.theme.monospaceFontName.isEmpty
            || NSFont(name: userProfile.theme.monospaceFontName,
                      size: userProfile.theme.monospaceFontSize) != nil

        print("""
        [MD_CMP] === profiles ===
        [MD_CMP] keys in user plist: \(domain.count)
        [MD_CMP] defaults: font \(defaultsProfile.theme.fontName) \
        \(defaultsProfile.theme.fontSize)pt, lineSpacing \(defaultsProfile.theme.lineSpacing), \
        ligatures \(defaultsProfile.theme.standardLigatures), \
        column \(Int(defaultsProfile.contentWidthPoints))pt, \
        spell \(defaultsProfile.spellCheck), grammar \(defaultsProfile.grammarCheck), \
        logging \(defaultsProfile.logging)
        [MD_CMP] user:     font \(userProfile.theme.fontName) \
        \(userProfile.theme.fontSize)pt, lineSpacing \(userProfile.theme.lineSpacing), \
        ligatures \(userProfile.theme.standardLigatures), \
        column \(Int(userProfile.contentWidthPoints))pt, \
        spell \(userProfile.spellCheck), grammar \(userProfile.grammarCheck), \
        logging \(userProfile.logging)
        [MD_CMP] user body font resolves: \(bodyResolved), mono resolves: \(monoResolved)
        """)

        // Ablation. Isolating spell/grammar in both directions is what separates
        // "costs nothing" from "never ran in this harness": if flipping it moves
        // neither profile, the pass is inert here and the honest place to
        // measure it is the live app.
        var userNoSpell = userProfile
        userNoSpell = Profile(name: "user −spell/grammar", theme: userProfile.theme,
                              spellCheck: false, grammarCheck: false,
                              contentWidthCm: userProfile.contentWidthCm,
                              logging: userProfile.logging)
        let userNoLog = Profile(name: "user −logging", theme: userProfile.theme,
                                spellCheck: userProfile.spellCheck,
                                grammarCheck: userProfile.grammarCheck,
                                contentWidthCm: userProfile.contentWidthCm,
                                logging: false)
        let defaultsPlusSpell = Profile(name: "defaults +spell/grammar",
                                        theme: defaultsProfile.theme,
                                        spellCheck: true, grammarCheck: true,
                                        contentWidthCm: defaultsProfile.contentWidthCm,
                                        logging: false)
        let profiles = [defaultsProfile, userProfile, userNoSpell, userNoLog, defaultsPlusSpell]

        let viewport = NSSize(width: 900, height: 800)
        let rounds = Self.env["MD_CMP_ROUNDS"].flatMap(Int.init) ?? 3

        var runs: [String: [Sample]] = [:]
        // Discard a cold round first — the very first load in a process pays
        // one-time font/CoreText warmup that would land entirely on whichever
        // profile happened to go first.
        mark("warmup")
        _ = run(defaultsProfile, source: source, viewport: viewport)
        for r in 0..<rounds {
            for p in profiles {
                mark("round \(r + 1)/\(rounds): \(p.name)")
                runs[p.name, default: []].append(run(p, source: source, viewport: viewport))
            }
        }

        func med(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }
        func value(_ name: String, _ pick: (Sample) -> Double) -> Double {
            med((runs[name] ?? []).map(pick))
        }
        func row(_ label: String, _ pick: (Sample) -> Double, _ unit: String = "ms") -> String {
            let base = value(defaultsProfile.name, pick)
            var line = String(format: "[MD_CMP] %-16@", label as NSString)
            for p in profiles {
                let v = value(p.name, pick)
                let d = base == 0 ? 0 : (v - base) / base * 100
                line += String(format: " %8.2f(%+5.1f%%)", v, d)
            }
            return line + "  \(unit)"
        }

        var header = String(format: "[MD_CMP] %-16@", "metric" as NSString)
        for p in profiles { header += String(format: " %16@", p.name as NSString) }

        print("""
        [MD_CMP] === results (median of \(rounds) alternating rounds) ===
        \(header)
        \(row("load", { $0.loadMS }))
        \(row("full drain", { $0.drainMS }))
        \(row("scroll median", { $0.scrollMedianMS }))
        \(row("scroll p95", { $0.scrollP95MS }))
        \(row("keystroke", { $0.keystrokeMedianMS }))
        \(row("settle CPU/0.5s", { $0.settleCPUMS }))
        \(row("doc height", { $0.docHeight }, "pt"))
        \(row("scroll frames", { Double($0.scrollFrames) }, "frames"))
        [MD_CMP] spell flag stuck: \(profiles.map { "\($0.name)=\(runs[$0.name]?.first?.spellFlagStuck ?? false)" }.joined(separator: ", "))
        """)

        // What one full synchronous spell pass over this document costs, so the
        // ablation above can be read against a real upper bound rather than an
        // assumption about whether AppKit scheduled one.
        let clock = ContinuousClock()
        let checker = NSSpellChecker.shared
        let tag = NSSpellChecker.uniqueSpellDocumentTag()
        let d = clock.measure {
            var start = 0
            let ns = source as NSString
            while start < ns.length {
                let r = checker.checkSpelling(of: source, startingAt: start,
                                              language: nil, wrap: false,
                                              inSpellDocumentWithTag: tag, wordCount: nil)
                if r.location == NSNotFound || r.length == 0 { break }
                start = r.location + r.length
            }
        }
        let spellPassMS = Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
        print("[MD_CMP] one full synchronous NSSpellChecker pass over the document: "
              + String(format: "%.1f ms", spellPassMS))

        #expect(bodyResolved, "user's body font did not resolve — measurement is not the user's config")
        #expect(!runs.isEmpty)
    }
}

/// Total CPU (user + system) this process has burned, in milliseconds.
private func processCPUMS() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    func ms(_ t: timeval) -> Double { Double(t.tv_sec) * 1000 + Double(t.tv_usec) / 1000 }
    return ms(u.ru_utime) + ms(u.ru_stime)
}

/// Same rewrite the scroll harness does: relative image paths resolve against a
/// document URL a test editor doesn't have.
private func absolutizeImagesForComparison(_ source: String, relativeTo dir: URL) -> String {
    var out = source
    let re = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#)
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
