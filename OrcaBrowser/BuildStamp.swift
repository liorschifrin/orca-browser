import SwiftUI

/// Which build of the app this is: the install slot, the commit it was built
/// from, and a few words on what the branch is about. `scripts/ship-to-phone.sh` passes these in as build
/// settings, which `AppInfo.plist` copies into the app's Info. A build from
/// Xcode has none of them, so `BuildStamp.current` is nil and nothing shows.
/// In Debug builds the bottom bar shows it only while the "Show FPS, memory and
/// build" setting is on.
struct BuildStamp {
    let slot: String
    let commit: String
    let label: String

    static let current: BuildStamp? = {
        func value(_ key: String) -> String {
            (Bundle.main.object(forInfoDictionaryKey: key) as? String) ?? ""
        }
        let slot = value("OrcaBuildSlot")
        guard !slot.isEmpty else { return nil }
        return BuildStamp(slot: slot, commit: value("OrcaBuildCommit"), label: value("OrcaBuildLabel"))
    }()
}

/// The slot with a tiny commit stamp beside it, then up to two lines of words
/// saying what the branch is about. A "*" after the commit means the build had
/// uncommitted changes.
struct BuildStampLabel: View {
    let stamp: BuildStamp

    var body: some View {
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
        .allowsHitTesting(false)
        .accessibilityLabel("Build \(stamp.slot), \(stamp.label), \(stamp.commit)")
    }
}
