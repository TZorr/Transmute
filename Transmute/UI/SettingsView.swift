//
//  SettingsView.swift
//  Transmute
//
//  Settings › Level: the max level - the ceiling "Limit to" and the batch
//  window hold peaks to - typed or stepped in 0.5 dB.
//
//  Settings › MIDI: which controllers are listened to (Ultramix's section,
//  by name, so an unplugged controller reconnects when it comes back), and
//  the Control Changes learnt so far, each with a way to forget it.
//
//  Learning itself happens where the control is - right-click a slider or
//  a pad - so this is the overview, not the place to set things up.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    private var midi: MIDIControllerInput { model.midi }

    var body: some View {
        Form {
            Section("Level") {
                HStack {
                    Text("Max level")
                    Spacer()
                    TextField("Max level", value: $model.maxLevelDB, format: .number.precision(.fractionLength(1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("dBFS").foregroundStyle(.secondary)
                    Stepper("Max level", value: $model.maxLevelDB, in: LevelLimit.range, step: LevelLimit.step)
                        .labelsHidden()
                }
                Text("Limit to (bottom of the main window) lowers every pad whose peak is above it; Batch Convert can do the same to every file. \(String(format: "%.0f", LevelLimit.range.lowerBound)) to 0 dBFS, in 0.5 dB steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("MIDI Controllers") {
                if midi.sources.isEmpty {
                    Text("No MIDI inputs found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(midi.sources) { source in
                    Toggle(source.name, isOn: Binding(get: { midi.isChosen(source) },
                                                      set: { midi.setController(source, on: $0) }))
                }
                HStack {
                    if let error = midi.lastError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Rescan") { midi.refresh() }
                }
                Text("Notes play the pads (right-click a pad to learn its note); Control Changes move what they were learnt to on the selected pad (right-click a slider).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Learnt Controls") {
                let learnt = model.midiMap.controls.sorted { $0.key < $1.key }
                if learnt.isEmpty {
                    Text("None yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(learnt, id: \.key) { target, address in
                    HStack {
                        Text(Self.title(of: target))
                        Spacer()
                        Text(address.label)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Forget") { model.forget(target) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 320)
    }

    static func title(of target: String) -> String {
        if target == LearnTarget.pan { return "Pan" }
        return ParamSpec.find(target)?.title ?? target
    }
}
