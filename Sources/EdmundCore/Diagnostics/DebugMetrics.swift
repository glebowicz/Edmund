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
    public var undoSnapshotsPushed = 0
    public var mathRenderMisses = 0
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
