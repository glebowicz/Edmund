import AppKit
import EdmundCore

// MARK: - Format groups (26+: the format bar, moved into the toolbar)
//
// On macOS 26 the format bar is not a bar. Its five control groups become
// toolbar items in the window's own toolbar row, and AppKit gives each one a
// Liquid Glass capsule, positions it, tracks the pointer over it and spills the
// row into the overflow menu when the window gets narrow — all things the
// hand-built strip had to do itself.
//
// Why the move, since the strip's capsules looked the same: in Mail, Notes,
// Pages, Photos and Calendar the capsule row *is* the toolbar row, the one
// holding the traffic lights and the title. None of them adds a second floating
// capsule row beneath it. Ours did, which put glass directly over body text
// (the document showed through the gaps *between* capsules, so both the icons
// and the paragraph behind them read badly) and cost 44pt of window height on
// top of the 52pt the toolbar row was already paying for. The HIG names the
// underlying rule: "Using too many Liquid Glass elements in a view can create
// visual clutter and reduce the impact of the material."
//
// Pre-26 nothing here runs — `FormatBarView` still builds the Aqua strip, which
// is correct on those versions and already looks right.

/// One segmented toolbar group: the SF Symbols it shows and the editor selector
/// each segment fires. These mirror `FormatBarView.buildUI`'s groups one for one.
///
/// The bar's two pull-downs (Heading, Alert/Callout) are deliberately absent:
/// `selectionMode` "only applies when using one of the constructors to create
/// the item with a system defined control representation"
/// (`NSToolbarItemGroup.h`), and that constructor takes a flat list of images
/// with a single shared action — there is no way to seat a menu inside it. They
/// become their own `FormatMenuToolbarItem`s, which is how Pages and Notes
/// present their paragraph-style pickers anyway.
struct FormatGroup {
    let id: NSToolbarItem.Identifier
    let label: String
    let segments: [(symbol: String, title: String, action: Selector)]
}

extension FormatToolbar {

    // The bar's own grouping, preserved: heading pull-down and thematic break
    // read as "block shape", the six inline styles as one run, highlight alone,
    // the three list kinds together, quote and callout as "block container".
    static let headingItem  = NSToolbarItem.Identifier("format.heading")
    static let inlineGroup  = NSToolbarItem.Identifier("format.inline")
    static let markGroup    = NSToolbarItem.Identifier("format.mark")
    static let listGroup    = NSToolbarItem.Identifier("format.lists")
    static let blockGroup   = NSToolbarItem.Identifier("format.blocks")
    static let calloutItem  = NSToolbarItem.Identifier("format.callout")

    /// Left to right, the order the format bar draws them in.
    static let formatGroups: [FormatGroup] = [
        FormatGroup(id: inlineGroup, label: "Style", segments: [
            ("bold", "Bold", #selector(EditorTextView.formatBold(_:))),
            ("italic", "Italic", #selector(EditorTextView.formatItalic(_:))),
            ("underline", "Underline", #selector(EditorTextView.formatUnderline(_:))),
            ("strikethrough", "Strikethrough", #selector(EditorTextView.formatStrikethrough(_:))),
            ("textformat.subscript", "Subscript", #selector(EditorTextView.formatSubscript(_:))),
            ("textformat.superscript", "Superscript", #selector(EditorTextView.formatSuperscript(_:))),
        ]),
        FormatGroup(id: markGroup, label: "Highlight", segments: [
            ("highlighter", "Highlight", #selector(EditorTextView.formatHighlight(_:))),
        ]),
        FormatGroup(id: listGroup, label: "List", segments: [
            ("list.bullet", "Bulleted List", #selector(EditorTextView.formatBulletedList(_:))),
            ("list.number", "Numbered List", #selector(EditorTextView.formatNumberedList(_:))),
            ("checklist", "Checklist", #selector(EditorTextView.formatChecklist(_:))),
        ]),
        FormatGroup(id: blockGroup, label: "Block", segments: [
            ("minus", "Thematic Break", #selector(EditorTextView.formatThematicBreak(_:))),
            ("quote.closing", "Block Quote", #selector(EditorTextView.formatBlockQuote(_:))),
        ]),
    ]

    /// Every format item, in toolbar order. The two pull-downs bracket the
    /// segmented groups the same way they bracket the bar's.
    static let formatGroupIdentifiers: [NSToolbarItem.Identifier] =
        [headingItem] + [inlineGroup, markGroup, listGroup] + [blockGroup, calloutItem]

    /// Whether the format controls live in the toolbar rather than in a bar of
    /// their own. Same gate as every other Liquid Glass path.
    static var usesToolbarFormatGroups: Bool { ChromeBarView.isGlass }

    /// Builds one of the format items, or nil if `id` isn't one.
    func makeFormatGroupItem(_ id: NSToolbarItem.Identifier) -> NSToolbarItem? {
        switch id {
        case Self.headingItem:
            return formatMenuItem(id, label: "Heading", symbol: "textformat.size",
                                  menu: FormatMenu.headingMenu())
        case Self.calloutItem:
            return formatMenuItem(id, label: "Alert / Callout", symbol: "quote.bubble",
                                  menu: FormatMenu.calloutMenu())
        default:
            guard let group = Self.formatGroups.first(where: { $0.id == id }) else { return nil }
            return segmentedItem(group)
        }
    }

    private func formatMenuItem(_ id: NSToolbarItem.Identifier, label: String,
                                symbol: String, menu: NSMenu) -> NSToolbarItem {
        let item = FormatMenuToolbarItem(itemIdentifier: id)
        item.label = label
        item.toolTip = label
        item.image = Self.symbol(symbol)
        item.showsIndicator = true
        item.menu = menu
        return item
    }

    private func segmentedItem(_ group: FormatGroup) -> NSToolbarItemGroup {
        // The convenience constructor, not `subitems`: it is the only one that
        // vends the "system defined control representation" `selectionMode`
        // needs, and that representation is what renders as a single fused
        // Liquid Glass capsule instead of a run of separate buttons. It is also
        // why the per-segment state lives in `segmentActions`/`segmentPushed`
        // rather than on a subclass — see the note there.
        let item = NSToolbarItemGroup(
            itemIdentifier: group.id,
            images: group.segments.map { Self.symbol($0.symbol) ?? NSImage() },
            selectionMode: .selectAny,
            labels: nil,
            target: self,
            action: #selector(formatSegmentClicked(_:)))
        item.label = group.label
        segmentActions[group.id] = group.segments.map(\.action)
        segmentPushed[group.id] = Array(repeating: false, count: group.segments.count)
        // Per-segment names for VoiceOver and the customization panel; the
        // toolbar is `.iconOnly`, so nothing draws them.
        for (subitem, segment) in zip(item.subitems, group.segments) {
            subitem.label = segment.title
            subitem.toolTip = segment.title
        }
        return item
    }

    /// A segment was clicked. Which one is worked out by diffing the control's
    /// selection against what `refreshFormatGroups` last pushed into it, rather
    /// than read off `selectedIndex`: in a `.selectAny` group that property is
    /// "the most recently *selected* item, or -1", so the click that turns Bold
    /// **off** — the single most common one — reports either -1 or some other
    /// still-lit segment. The diff is exact for both directions.
    @objc func formatSegmentClicked(_ sender: NSToolbarItemGroup) {
        guard let actions = segmentActions[sender.itemIdentifier],
              let pushed = segmentPushed[sender.itemIdentifier] else { return }
        let selected = actions.indices.map { sender.isSelected(at: $0) }
        guard let index = Self.changedSegment(selected: selected, pushed: pushed) else { return }
        segmentPushed[sender.itemIdentifier] = selected
        // `NSApp` is an implicitly-unwrapped optional and is genuinely nil in a
        // test process, so chain it rather than trusting the declaration.
        NSApp?.sendAction(actions[index], to: nil, from: sender)
    }

    /// The one segment whose selection differs from what was last pushed into
    /// the control — i.e. the one the user just clicked. Nil if nothing moved,
    /// which happens when a refresh and a click race.
    static func changedSegment(selected: [Bool], pushed: [Bool]) -> Int? {
        guard selected.count == pushed.count else { return nil }
        return selected.indices.first { selected[$0] != pushed[$0] }
    }

    /// Lights the segments whose formatting is in effect at the caret, and ticks
    /// the heading level and callout type the caret sits in — the toolbar's
    /// version of `FormatBarView.refreshActiveState`. Runs on every selection
    /// change and every edit, so it stays a lookup over the already-computed
    /// active set and nothing more.
    func refreshFormatGroups(toolbar: NSToolbar?, editor: EditorTextView) {
        guard let toolbar else { return }
        let active = editor.activeFormattingActions()
        for item in toolbar.items {
            guard let group = item as? NSToolbarItemGroup,
                  let actions = segmentActions[item.itemIdentifier] else { continue }
            let selected = actions.map(active.contains)
            for (index, on) in selected.enumerated() { group.setSelected(on, at: index) }
            segmentPushed[item.itemIdentifier] = selected
        }
        tick(menuOf: toolbar.items.first { $0.itemIdentifier == Self.headingItem }) {
            $0.tag == editor.activeHeadingLevel()
        }
        tick(menuOf: toolbar.items.first { $0.itemIdentifier == Self.calloutItem }) {
            ($0.representedObject as? String)?.lowercased() == editor.activeCalloutType()
        }
    }

    /// Ticks whichever of a pull-down menu's rows `isOn` picks. Rows with no
    /// action are skipped — the same rule the bar uses, since a separator or a
    /// header has no state to report.
    private func tick(menuOf item: NSToolbarItem?, isOn: (NSMenuItem) -> Bool) {
        guard let menu = (item as? NSMenuToolbarItem)?.menu else { return }
        for row in menu.items where row.action != nil {
            row.state = isOn(row) ? .on : .off
        }
    }

    /// Shows or hides the format items as one unit — `View ▸ Show Format Bar`.
    ///
    /// `NSToolbarItem.isHidden` rather than `insertItem`/`removeItem`: the
    /// toolbar has `autosavesConfiguration`, so inserting and removing would
    /// rewrite the user's saved arrangement on every toggle, and anything they
    /// had dragged in next to the format items would shuffle. Hiding leaves the
    /// arrangement alone and still collapses the items' width.
    @available(macOS 26.0, *)
    func setFormatGroupsHidden(_ hidden: Bool, toolbar: NSToolbar?) {
        guard let toolbar else { return }
        let ids = Set(Self.formatGroupIdentifiers)
        for item in toolbar.items where ids.contains(item.itemIdentifier) {
            item.isHidden = hidden
        }
    }
}

// MARK: - Validation

extension FormatToolbar: NSToolbarItemValidation {
    /// A segmented group's segments all share one action — ours — which the
    /// responder chain would always answer, so the per-segment gate has to be
    /// applied by hand. It is the Format menu's own gate, reached the way
    /// `FormatButtonItem` reaches it: Reading mode and the Markdown-feature
    /// toggles each rule out some of these commands but not others, so Bold can
    /// be live in the same group where Subscript is not.
    ///
    /// AppKit routes autovalidation for a targeted item here because the target
    /// implements `NSToolbarItemValidation`; items with a nil target keep
    /// validating against the focused editor, as they always did.
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let actions = segmentActions[item.itemIdentifier],
              let group = item as? NSToolbarItemGroup else { return true }
        // `NSApp` is an implicitly-unwrapped optional and is genuinely nil in a
        // test process, so chain it rather than trusting the declaration.
        let editor = NSApp?.target(forAction: #selector(EditorTextView.formatBold(_:)))
            as? EditorTextView
        for (subitem, action) in zip(group.subitems, actions) {
            subitem.isEnabled = editor?.isFormattingActionEnabled(action, representedObject: nil) ?? false
        }
        return editor != nil
    }
}
