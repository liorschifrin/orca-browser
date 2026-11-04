import SwiftUI

/// Which build of the app this is: the install slot, the commit it was built
/// from, a few words on what the branch is about, and notes on what to test.
/// `scripts/ship-to-phone.sh` passes these in as build settings, which
/// `AppInfo.plist` copies into the app's Info. A build from Xcode has none of
/// them, so `BuildStamp.current` is nil and nothing shows.
/// In Debug builds the bottom bar shows the stamp only while the "Show FPS,
/// memory and build" setting is on.
struct BuildStamp {
    let slot: String
    let commit: String
    let label: String
    /// Different for every build, even from the same commit.
    let id: String
    let notes: BuildNotes?

    static let current: BuildStamp? = {
        func value(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        }
        let slot = value("OrcaBuildSlot")
        guard !slot.isEmpty else { return nil }
        return BuildStamp(
            slot: slot,
            commit: value("OrcaBuildCommit"),
            label: value("OrcaBuildLabel"),
            id: value("OrcaBuildID"),
            notes: BuildNotes.decode(base64: value("OrcaBuildNotes"))
        )
    }()

    /// The regular app, built from main. It has no visible stamp, but the spot
    /// where the stamp would be still opens its notes.
    var isMain: Bool { slot == "main" }

    private static let seenKey = "lastSeenBuildNotesID"

    /// True the first time a build with notes opens.
    var hasUnseenNotes: Bool {
        notes != nil && !id.isEmpty && UserDefaults.standard.string(forKey: Self.seenKey) != id
    }

    func markNotesSeen() {
        UserDefaults.standard.set(id, forKey: Self.seenKey)
    }
}

/// What the build changed and what to try, written by whoever shipped it, and
/// a link to the T3 Code thread that made it.
struct BuildNotes: Equatable {
    var changed: [String]
    var test: [String]
    /// Older entries kept behind a "more" button under `changed`.
    var more: [String] = []
    /// Title for the `changed` list.
    var heading = "Changed"
    var threadURL: URL?

    private struct Payload: Decodable {
        var changed: [String]?
        var test: [String]?
        var more: [String]?
        var heading: String?
        var thread: String?
    }

    /// The script sends the notes as base64-encoded JSON, so any text survives
    /// the trip through the build settings. Nil when there is nothing to show.
    static func decode(base64: String) -> BuildNotes? {
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let notes = BuildNotes(
            changed: payload.changed ?? [],
            test: payload.test ?? [],
            more: payload.more ?? [],
            heading: payload.heading ?? "Changed",
            threadURL: payload.thread.flatMap { URL(string: $0) }
        )
        return notes.changed.isEmpty && notes.test.isEmpty && notes.more.isEmpty && notes.threadURL == nil ? nil : notes
    }
}

/// The slot with a tiny commit stamp beside it, then up to two lines of words
/// saying what the branch is about. A "*" after the commit means the build had
/// uncommitted changes. Pressing and holding it opens the build's notes, after
/// a short delay and without waiting for the finger to lift. A plain tap, or a
/// swipe that starts on it (up to the tab switcher), does nothing. On the main
/// build the stamp is invisible, and holding where it would be does the same.
struct BuildStampLabel: View {
    let stamp: BuildStamp
    let onOpen: () -> Void

    /// How long to hold before the notes open.
    private static let holdDuration = 0.15
    /// Moving further than this while holding cancels it, so swiping up from
    /// the stamp opens the tab switcher and not the notes.
    private static let maximumMovement: CGFloat = 10

    var body: some View {
        Group {
            if stamp.isMain {
                // Invisible, but sized like the stamp so it is easy to hit.
                Color.clear
                    .frame(width: 76, height: 30)
                    .contentShape(.rect)
            } else {
                stampText
            }
        }
        .onLongPressGesture(minimumDuration: Self.holdDuration, maximumDistance: Self.maximumMovement) {
            guard stamp.notes != nil else { return }
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
            onOpen()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(stamp.isMain ? "What's new on main" : "Build \(stamp.slot), \(stamp.label), \(stamp.commit)")
        .accessibilityHint(stamp.notes == nil ? "" : "Shows what changed in this build")
        .accessibilityAddTraits(stamp.notes == nil ? [] : .isButton)
        .accessibilityAction { if stamp.notes != nil { onOpen() } }
    }

    private var stampText: some View {
        VStack(alignment: .trailing, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(stamp.slot)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                Text(stamp.commit)
                    .font(.system(size: 7, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .lineLimit(1)
            if !stamp.label.isEmpty {
                Text(stamp.label)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .foregroundStyle(.secondary)
        // Fits between the + button and Back on the narrowest iPhones.
        .frame(maxWidth: 76, alignment: .trailing)
        .contentShape(.rect)
    }
}

/// The build's notes in a panel that floats over the page the way a link peek
/// does: dimmed page behind it, the toolbar still tappable, and closed by
/// tapping outside or the X. It is as tall as its notes, up to the height of
/// the peek, and only scrolls when the notes don't fit.
struct BuildNotesPeek: View {
    let stamp: BuildStamp
    let notes: BuildNotes
    let bottomInset: CGFloat
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var isClosing = false
    @State private var contentHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var threadOpenFailed = false
    @State private var showsMore = false

    private static let headerHeight: CGFloat = 44
    /// The thread link, laid out like an action in the link peek.
    private static let threadRowHeight: CGFloat = PeekLayout.rowHeight

    private var threadRowHeight: CGFloat {
        notes.threadURL == nil ? 0 : Self.threadRowHeight + 1
    }

    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.height - bottomInset - 2 * PeekLayout.margin)
            let width = max(1, min(380, geometry.size.width - 2 * PeekLayout.margin))
            let maxBodyHeight = max(0, available - Self.headerHeight - threadRowHeight)
            let bodyHeight = min(contentHeight, maxBodyHeight)
            ZStack {
                Color.black.opacity(isVisible ? 0.35 : 0)
                    .ignoresSafeArea()
                    .padding(.bottom, bottomInset)
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .padding(.bottom, bottomInset)
                    .onTapGesture(perform: close)
                    .accessibilityLabel("Dismiss build notes")

                VStack(spacing: 0) {
                    header
                    ScrollView {
                        notesContent
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDisabled(contentHeight <= maxBodyHeight)
                    .frame(height: bodyHeight)
                    if let url = notes.threadURL {
                        Divider()
                        threadRow(url)
                    }
                }
                .frame(width: width)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 20)
                .position(x: geometry.size.width / 2, y: PeekLayout.margin + available / 2)
                .scaleEffect(reduceMotion || isVisible ? 1 : 0.92)
                .opacity(isVisible ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.82)) {
                isVisible = true
            }
        }
        .allowsHitTesting(!isClosing)
    }

    private var header: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(stamp.label.isEmpty ? stamp.slot : stamp.label)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(stamp.slot) · \(stamp.commit)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 4)
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .frame(width: 44, height: Self.headerHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close build notes")
        }
        .frame(height: Self.headerHeight)
    }

    private func threadRow(_ url: URL) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.5)
            UIApplication.shared.open(url) { opened in
                threadOpenFailed = !opened
            }
        } label: {
            HStack {
                Text(threadOpenFailed ? "T3 Code didn't open" : "Open Thread in T3 Code")
                Spacer()
                Image(systemName: "arrow.up.forward.app")
            }
            .padding(.horizontal, 16)
            .frame(height: Self.threadRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !notes.changed.isEmpty {
                section(notes.heading, icon: "pencil", items: notes.changed, more: notes.more)
            }
            if !notes.test.isEmpty {
                section("Test", icon: "checkmark.circle", items: notes.test)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, icon: String, items: [String], more: [String] = []) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                row(item, icon: icon)
            }
            if !more.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showsMore.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showsMore ? "Show fewer" : "Show \(more.count) more")
                        Image(systemName: showsMore ? "chevron.up" : "chevron.down")
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showsMore {
                    ForEach(Array(more.enumerated()), id: \.offset) { _, item in
                        row(item, icon: icon)
                    }
                }
            }
        }
    }

    private func row(_ text: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            // Inline Markdown (bold, code) works in the notes.
            Text(LocalizedStringKey(text))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .removed) {
            isVisible = false
        } completion: {
            onDismiss()
        }
    }
}
