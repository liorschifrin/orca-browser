import SwiftUI

/// How long each YouTube countdown is (`YouTubeSpeedBumps`), with longer
/// ones for the night hours if you want them.
struct SpeedBumpSettingsView: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                TimesRows(times: $settings.speedBumps.day)
            } footer: {
                Text("Listen only plays a video with the picture covered, for music and podcasts. 0 seconds opens at once.")
            }
            Section {
                Toggle("Different times at night", isOn: $settings.speedBumps.hasNightTimes)
                if settings.speedBumps.hasNightTimes {
                    DatePicker("From", selection: time($settings.speedBumps.nightStart), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: time($settings.speedBumps.nightEnd), displayedComponents: .hourAndMinute)
                }
            } header: {
                Text("Night")
            }
            if settings.speedBumps.hasNightTimes {
                Section {
                    TimesRows(times: $settings.speedBumps.night)
                } header: {
                    Text("Times at night")
                }
            }
        }
        .navigationTitle("Countdowns")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Minutes after midnight, as a time of day for a date picker.
    private func time(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60,
                                  second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        }
    }

    private struct TimesRows: View {
        @Binding var times: YouTubeSpeedBumps.Times

        var body: some View {
            row("Home page", $times.home)
            row("Watch video", $times.video)
            row("Listen only", $times.audio)
            row("More videos", $times.moreVideos)
        }

        private func row(_ title: String, _ seconds: Binding<Int>) -> some View {
            Stepper(value: seconds, in: 0...600, step: 5) {
                HStack {
                    Text(title)
                    Spacer()
                    Text("\(seconds.wrappedValue) s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
