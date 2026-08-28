#if DEBUG

/// Test-only instrumentation counters for the editor's hot paths — restyle,
/// recompose, undo-snapshot, layout-invalidation, and render-cache-miss
/// counts. `#if DEBUG` like `EditorTextStorage.debugCachedStringIsStale`:
/// release builds pay nothing, and `swift test` is a debug build, so CI still
/// sees these.
///
/// Counters, not timings: immune to thermal state, machine, and backing
/// scale, and they diff exactly (`blocksRestyled 2 → 847` names what broke; a
/// millisecond delta doesn't say which path regressed). See
/// `Tests/EdmundTests/PerfCountersTests.swift`, the CI gate built on these.
@MainActor
public final class DebugMetrics {
    /// Shared instance for the two process-wide render caches — `MathRenderer`
    /// and the editor's image cache — which aren't scoped to one editor.
    public static let global = DebugMetrics()

    public var blocksRestyled = 0
    public var fullRecomposes = 0
    public var rangedRecomposes = 0
    public var dirtyRecomposes = 0
    public var dirtyBlocksRequested = 0
    public var dirtyBlocksDeferred = 0
    public var drainSlices = 0
    public var layoutInvalidations = 0
    /// Edit-driven pushes only (`recordUndoIfNeeded` and the whole-document
    /// edit helpers). Does NOT count the bookkeeping push `performUndo`/
    /// `performRedo` make onto the *opposite* stack when they fire — counting
    /// those would make undoing/redoing during a scenario look like new edits.
    public var undoSnapshotsPushed = 0
    /// Process-global cache (`MathRenderer`'s `NSCache`), shared across the
    /// whole parallel test run — only `DebugMetrics.global` is meaningful for
    /// this one. Record it; don't assert an exact value in a scenario that
    /// isn't guaranteed to run with a cold cache.
    public var mathRenderMisses = 0
    /// Process-global cache (the editor's `imageCache`), same caveat as
    /// `mathRenderMisses`.
    public var imageDecodes = 0

    public init() {}

    public func reset() {
        blocksRestyled = 0
        fullRecomposes = 0
        rangedRecomposes = 0
        dirtyRecomposes = 0
        dirtyBlocksRequested = 0
        dirtyBlocksDeferred = 0
        drainSlices = 0
        layoutInvalidations = 0
        undoSnapshotsPushed = 0
        mathRenderMisses = 0
        imageDecodes = 0
    }
}

#endif
