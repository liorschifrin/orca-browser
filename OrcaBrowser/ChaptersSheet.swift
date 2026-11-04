import SwiftUI

/// The video's chapters, each with its start time, from the chapters button
/// in YouTube's top bar. Tap one to jump there.
struct ChaptersSheet: View {
    let tab: Tab
    @Environment(\.dismiss) private var dismiss
    @State private var time: Double?

    var body: some View {
        let chapters = tab.playback.chapters
        let current = Self.currentIndex(in: chapters, at: time)
        NavigationStack {
            List(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                Button {
                    tab.send(.seekTo(chapter.start))
                    dismiss()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(Self.clock(chapter.start))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .leading)
                        Text(chapter.title)
                            .font(.body.weight(index == current ? .semibold : .regular))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if index == current {
                            Image(systemName: "play.fill").font(.caption).foregroundStyle(.tint)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task { time = await tab.currentTime() }
    }

    /// The chapter playing at `time`: the last one that has started.
    static func currentIndex(in chapters: [PlaybackControl.Chapter], at time: Double?) -> Int? {
        guard let time else { return nil }
        return chapters.lastIndex { $0.start <= time + 0.5 }
    }

    /// 83 seconds as "1:23", 3,725 as "1:02:05".
    static func clock(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let (hours, minutes, rest) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
