import SwiftUI

/// Fringe ▸ Settings… (⌘,): the Sound pane. Puzzle sounds, their volume, the opt-in tone for
/// a finished Run Final, and whether a Check's result plays out case by case.
struct SettingsView: View {
    let model: AppState

    var body: some View {
        let settings = model.soundSettings
        Form {
            Section {
                Toggle("Play sounds in puzzles", isOn: Binding(get: { settings.puzzleSoundsOn },
                                                               set: { settings.puzzleSoundsOn = $0 }))
                VolumeRow(model: model)
                Toggle("Sound when a final solve finishes", isOn: Binding(get: { settings.finalSolveSoundOn },
                                                                         set: { settings.finalSolveSoundOn = $0 }))
                SystemSoundsRow(settings: settings)
            } footer: {
                Text("During a Check each case plays a tone: brighter cases ring louder and clearer, and the score tone rises to a chord when you pass. A final solve's tone plays only after solves of 5 s or more.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Animate puzzle results", isOn: Binding(get: { settings.animateResults },
                                                               set: { settings.animateResults = $0 }))
            } footer: {
                Text("When on, a Check shows each case in turn and then fills the score bar; click, Space or Esc skips to the end. When off, results appear at once. With Reduce Motion on, results fade in instead.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The volume slider between speaker symbols, and Play Sample: a short part of a real
/// three-star reveal at the level a reveal plays.
private struct VolumeRow: View {
    let model: AppState

    var body: some View {
        let settings = model.soundSettings
        LabeledContent("Volume") {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Slider(value: Binding(get: { settings.volume }, set: { settings.volume = $0 }), in: 0...1)
                    .accessibilityLabel("Volume")
                    .frame(minWidth: 140)
                Image(systemName: "speaker.wave.3.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Button("Play Sample") { model.sound.play(SoundPalette.sample()) }
                    .disabled(!settings.isSoundAllowed(for: .puzzle))
                    .help("Plays the end of a three-star XOR result at the level a Check plays")
            }
        }
        .disabled(!settings.puzzleSoundsOn)
    }
}

/// Shown only when the system's "Play user interface sound effects" could be read and is off.
private struct SystemSoundsRow: View {
    let settings: SoundSettings

    var body: some View {
        if settings.isBlockedBySystem {
            VStack(alignment: .leading, spacing: 6) {
                Text("System sound effects are off in System Settings ▸ Sound, so Fringe is silent too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Play anyway", isOn: Binding(get: { settings.ignoreSystemSetting },
                                                    set: { settings.ignoreSystemSetting = $0 }))
            }
        }
    }
}
