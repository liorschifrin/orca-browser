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

    private static let seenKey = "lastSeenBuildNotesID"

    /// True the first time a build with notes opens.
    var hasUnseenNotes: Bool {
        notes != nil && !id.isEmpty && UserDefaults.standard.string(forKey: Self.seenKey) != id
    }

    func markNotesSeen() {
        UserDefaults.standard.set(id, forKey: Self.seenKey)
    }
}

/// What the build changed and what to try, written by whoever shipped it.
struct BuildNotes: Equatable {
    var changed: [String]
    var test: [String]

    private struct Payload: Decodable {
        var changed: [String]?
        var test: [String]?
    }

    /// The script sends the notes as base64-encoded JSON, so any text survives
    /// the trip through the build settings. Nil when there is nothing to show.
    static func decode(base64: String) -> BuildNotes? {
        guard let data = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        let notes = BuildNotes(changed: payload.changed ?? [], test: payload.test ?? [])
        return notes.changed.isEmpty && notes.test.isEmpty ? nil : notes
    }
}

/// The slot with a tiny commit stamp beside it, then up to two lines of words
/// saying what the branch is about. A "*" after the commit means the build had
/// uncommitted changes. Tapping it opens the build's notes.
struct BuildStampLabel: View {
    let stamp: BuildStamp
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
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
        .buttonStyle(.plain)
        .disabled(stamp.notes == nil)
        .accessibilityLabel("Build \(stamp.slot), \(stamp.label), \(stamp.commit)")
        .accessibilityHint("Shows what changed in this build")
    }
}

/// The build's notes in a panel that floats over the page the way a link peek
/// does: dimmed page behind it, the toolbar still tappable, and closed by
/// tapping outside, the X, or swiping down.
struct BuildNotesPeek: View {
    let stamp: BuildStamp
    let notes: BuildNotes
    let bottomInset: CGFloat
    let onDismiss: () -> Void

    @State private var isVisible = false
    @State private var isClosing = false
    @State private var contentHeight: CGFloat = 0
    @State private var isScrolledToTop = true
    @State private var isDragging = false
    @State private var dragStartedAtTop = false
    @State private var dragOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let headerHeight: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let available = max(1, geometry.size.height - bottomInset - 2 * PeekLayout.margin)
            let width = max(1, min(380, geometry.size.width - 2 * PeekLayout.margin))
            let bodyHeight = min(contentHeight, max(0, available - Self.headerHeight))
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
                    .onScrollGeometryChange(for: Bool.self) {
                        $0.contentOffset.y <= -$0.contentInsets.top + 1
                    } action: { _, atTop in
                        isScrolledToTop = atTop
                    }
                    .frame(height: bodyHeight)
                }
                .frame(width: width)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(radius: 20)
                .offset(y: dragOffset)
                .position(x: geometry.size.width / 2, y: PeekLayout.margin + available / 2)
                .scaleEffect(reduceMotion || isVisible ? 1 : 0.92)
                .opacity(isVisible ? 1 : 0)
                .simultaneousGesture(swipeDown)
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

    private var notesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !notes.changed.isEmpty {
                section("Changed", icon: "pencil", items: notes.changed)
            }
            if !notes.test.isEmpty {
                section("Test", icon: "checkmark.circle", items: notes.test)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // Inline Markdown (bold, code) works in the notes.
                    Text(LocalizedStringKey(item))
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Drag the panel down to close it. Starts counting only when the notes
    /// are scrolled to the top, so scrolling a long list up never closes it.
    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartedAtTop = isScrolledToTop
                }
                guard dragStartedAtTop, value.translation.height > 0 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                defer { isDragging = false }
                guard dragStartedAtTop,
                      value.translation.height > 90 || value.predictedEndTranslation.height > 220 else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dragOffset = 0 }
                    return
                }
                close()
            }
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        withAnimation(.easeOut(duration: 0.18), completionCriteria: .removed) {
            isVisible = false
            if dragOffset > 0 { dragOffset += 120 }
        } completion: {
            onDismiss()
        }
    }
}
