import SwiftUI

/// The recent-activity strip, and the full list behind it.
///
/// **Where these live, and why not on the panel.** The panel is 412x276 and all
/// four zones are already placed: agents at 16-204 across the top, pad and command
/// cluster filling y 138-274, dial occupying the right band. The only unclaimed
/// rectangle is roughly 84x68 in the top-right gap, which is not a strip — and
/// `PanelLayout` has no activity zone to place one in. So this is not a fifth zone.
/// It is sized to the panel's own width so it can hang off an edge as a popover or
/// HUD, and `ActivityLogView` is the sheet or window behind it. Task 026's popover
/// already opens "the activity log filtered to this session", which is the same
/// surface.
///
/// Both views are pure functions of a snapshot: `ActivityLog` is a reference type
/// behind a lock, not observable, so the owner reads `log.entries(limit:)` and
/// passes the array down. Nothing here awaits, and nothing here mutates the log.
public struct ActivityStripView: View {

    /// Three rows. Enough to show a transition and what followed it, small enough
    /// to sit under a 276pt panel without competing with the keys.
    public static let defaultRowCount = 3

    private let entries: [ActivityEntry]
    private let layout: PanelLayout
    private let rowCount: Int
    private let onOpenFullLog: (() -> Void)?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `entries` must be newest-first, which is what `ActivityLog.entries(limit:)`
    /// returns. Extra entries beyond `rowCount` are ignored rather than scrolled.
    public init(
        entries: [ActivityEntry],
        layout: PanelLayout = .regular,
        rowCount: Int = ActivityStripView.defaultRowCount,
        onOpenFullLog: (() -> Void)? = nil
    ) {
        self.entries = entries
        self.layout = layout
        self.rowCount = max(1, rowCount)
        self.onOpenFullLog = onOpenFullLog
    }

    /// Height a container should reserve. Exposed so a popover can size itself
    /// without rendering first.
    public static func preferredHeight(
        layout: PanelLayout = .regular,
        rowCount: Int = ActivityStripView.defaultRowCount
    ) -> CGFloat {
        CGFloat(max(1, rowCount)) * ActivityRow.height(layout) + 2 * padding(layout)
    }

    static func padding(_ layout: PanelLayout) -> CGFloat { max(4, 8 * layout.scale) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if visible.isEmpty {
                // An empty strip would read as broken. Say it is empty.
                Text("no events yet")
                    .font(.system(size: layout.fontSize(9)))
                    .foregroundStyle(.secondary)
                    .frame(height: ActivityRow.height(layout), alignment: .leading)
            } else {
                ForEach(visible) { entry in
                    ActivityRow(entry: entry, layout: layout, showsSubject: true)
                }
            }
        }
        .padding(Self.padding(layout))
        .frame(width: layout.panelSize.width, alignment: .leading)
        .background(background)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: visible.first?.id)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Recent activity")
        .contentShape(Rectangle())
        .onTapGesture { onOpenFullLog?() }
        .help("Recent state changes and dispatched actions. Kept in memory on this Mac only.")
    }

    private var visible: [ActivityEntry] { Array(entries.prefix(rowCount)) }

    @ViewBuilder
    private var background: some View {
        if reduceTransparency {
            Color(nsColor: .windowBackgroundColor)
        } else {
            Rectangle().fill(.ultraThinMaterial)
        }
    }
}

/// The inspectable full log. Same rows, scrolling, plus the two facts the strip
/// cannot show: how much history exists and how much was evicted.
public struct ActivityLogView: View {
    private let entries: [ActivityEntry]
    private let dropped: Int
    private let capacity: Int
    private let sessionFilter: String?
    private let layout: PanelLayout

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        entries: [ActivityEntry],
        dropped: Int = 0,
        capacity: Int = ActivityLog.defaultCapacity,
        sessionFilter: String? = nil,
        layout: PanelLayout = .regular
    ) {
        self.entries = entries
        self.dropped = dropped
        self.capacity = capacity
        self.sessionFilter = sessionFilter
        self.layout = layout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(entries) { entry in
                        ActivityRow(entry: entry, layout: layout, showsSubject: sessionFilter == nil)
                    }
                }
            }
            footer
        }
        .padding(12)
        .frame(minWidth: layout.panelSize.width, minHeight: 220)
        .background(reduceTransparency ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                                       : AnyShapeStyle(.ultraThinMaterial))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(sessionFilter.map { "Activity · session \($0.prefix(8))" } ?? "Activity")
                .font(.system(size: layout.fontSize(11), weight: .semibold))
            Spacer(minLength: 0)
            Text("\(entries.count) shown")
                .font(.system(size: layout.fontSize(9)).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Truncation is stated, never silent — the same rule the overflow badge
    /// follows. And the privacy fact belongs where the content is visible.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dropped > 0 {
                Text("\(dropped) earlier entries evicted (buffer holds \(capacity))")
                    .font(.system(size: layout.fontSize(9)))
                    .foregroundStyle(.secondary)
            }
            Text("Kept in memory on this Mac only. Never sent anywhere, never written to disk.")
                .font(.system(size: layout.fontSize(9)))
                .foregroundStyle(.secondary)
        }
    }
}

/// One line, shared by both surfaces so they cannot tell different stories.
///
/// Three channels, none of them colour alone: the icon comes from the same
/// vocabulary as the keys, the text names the states in words, and the tint is the
/// third signal rather than the only one.
struct ActivityRow: View {
    let entry: ActivityEntry
    let layout: PanelLayout
    let showsSubject: Bool

    static func height(_ layout: PanelLayout) -> CGFloat {
        layout.fontSize(9) + max(5, 6 * layout.scale)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.clockText)
                .font(.system(size: layout.fontSize(9)).monospacedDigit())
                .foregroundStyle(.secondary)
            Image(systemName: AgentKeyView.iconName(for: entry.tintState))
                .font(.system(size: layout.fontSize(8), weight: .semibold))
                .foregroundStyle(StateColors.keyFill(entry.tintState))
            Text(text)
                .font(.system(size: layout.fontSize(9)))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(height: Self.height(layout))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.clockText), \(entry.description)")
        .help(entry.description)
    }

    /// The full line always carries the subject; a session-filtered list drops it,
    /// since repeating "slot 3" on forty rows says nothing.
    private var text: String {
        showsSubject ? entry.description : String(entry.description.drop(while: { $0 != ":" }).dropFirst(2))
    }
}
