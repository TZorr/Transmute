//
//  ParameterPanel.swift
//  Transmute
//
//  The selected pad's model first - Automatic, Kick / Tom, Snare, Hi-Hat,
//  Modal or Clap, the analysis's suggestion marked - choosable on an empty pad too,
//  for the next sample dropped on it; then every parameter of that model
//  as a slider, in the synth's own groups - pitch, envelope, a snare's
//  second mode, a hat's metal, a modal drum's modes, a clap's bursts and
//  tail, click, noise, filter, master envelope -
//  then the pad's pan.
//
//  The scroller is AppKit's legacy one, always there with its track (see
//  LegacyScroller): with the system's overlay scrollers the panel showed
//  no bar until it was scrolled, and one was asked for.
//
//  The rows come from ParamSpec, the table the Fitter takes its ranges
//  from, so a slider can always show what the fit found. Frequencies and
//  times move in log steps, the way they are heard. The same table maps a
//  MIDI CC's 0…127 onto a slider (ParamSpec.position), so a learnt knob
//  and the slider agree at every point.
//
//  Right-click any row - slider or Pan - for Learn MIDI CC; the
//  row says "Learning…" until a Control Change arrives, and shows its CC in
//  the menu afterwards.
//
//  The boxes (model, filter type) are pull-down
//  Menus around an inline Picker, not bare Pickers: a bare one opens with
//  the selected item over the button and can unfold upwards off the panel.
//

import SwiftUI

struct ParameterPanel: View {
    let model: AppModel

    private static func groups(_ model: DrumModel) -> [(String, [String])] {
        if model == .clap {
            return [
                ("Envelope", ["delay", "gainDB", "length"]),
                ("Bursts", ["clapBursts", "clapSpacing", "clapBurstDecay", "noiseTone", "noiseWidth"]),
                ("Tail", ["noise", "noiseDecay", "noiseShape", "clapTailTone", "clapTailWidth"]),
                ("Click", ["transient", "clickTone", "clickDecay", "attackLevelDB"]),
            ]
        }
        if model == .modal {
            return [
                ("Envelope", ["delay", "ampAttack", "ampDecay", "ampShape", "gainDB", "length"]),
                ("Modes", ["modalTone"] + DrumParams.modalModes.flatMap { ["modalLevel\($0)", "modalRatio\($0)", "modalDecay\($0)"] }),
                ("Click", ["transient", "clickTone", "clickDecay"]),
                ("Noise", ["noise", "noiseTone", "noiseDecay", "attackLevelDB"]),
            ]
        }
        if model == .hat {
            return [
                ("Envelope", ["delay", "ampAttack", "gainDB", "length"]),
                ("Metal", ["metal", "metalTone"]),
                ("Click", ["transient", "clickTone", "clickDecay"]),
                ("Noise and band", ["noise", "noiseTone", "noiseWidth", "noiseDecay", "noiseShape", "attackLevelDB"]),
            ]
        }
        let snare = model == .snare
        return [
            ("Pitch", ["fundamental", "pitchStart", "pitchDecay", "startPhase"]),
            ("Envelope", ["delay", "ampAttack", "ampDecay", "ampShape", "drive", "gainDB", "length"]),
        ] + (snare ? [("Mode 2", ["mode2Level", "mode2Ratio", "mode2Decay"])] : []) + [
            ("Click", ["transient", "clickTone", "clickDecay"]),
            (snare ? "Noise (wires)" : "Noise",
             ["noise", "noiseTone"] + (snare ? ["noiseWidth"] : []) + ["noiseDecay"]
                + (snare ? ["noiseShape"] : []) + ["attackLevelDB"]),
        ]
    }

    var body: some View {
        let pad = model.pad
        let shown = pad.shownModel ?? .kick
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Model") {
                    HStack(spacing: 8) {
                        Text("Drum").frame(width: 84, alignment: .leading)
                        Menu {
                            Picker("Drum", selection: drumModel(pad)) {
                                Text("Automatic").tag(DrumModel?.none)
                                ForEach(DrumModel.allCases) { m in
                                    Text(pad.suggestedModel == m ? "\(m.title) (suggested)" : m.title).tag(Optional(m))
                                }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(modelLabel(pad))
                        }
                        .fixedSize()
                        Spacer()
                    }
                    .font(.callout)
                    .help("The voice a sample is rebuilt with - choosable before one is dropped: the pad then analyses whatever lands on it as that drum. Kick / Tom: one swept sine, a click, a band of shell noise. Snare: adds a second head mode and plays the noise as snare wires. Hi-Hat: no body - noise and metal (six square waves at the 808's ratios) through one steep band. Modal: up to six damped partials - cowbells, claves, rims, woodblocks. Clap: a train of noise bursts and a tail. Automatic lets the analysis choose; on a loaded pad, choosing another model analyses and fits the sample again.")
                }
                Group {
                    ForEach(Self.groups(shown), id: \.0) { group in
                        section(group.0) {
                            ForEach(group.1, id: \.self) { id in
                                row(ParamSpec.spec(id), pad: pad)
                            }
                            if group.0 == "Envelope" {
                                Toggle("Auto length", isOn: autoLength(pad))
                                    .font(.callout)
                                    .controlSize(.small)
                                    .padding(.leading, 92)
                                    .help("Length follows the decay: until every layer has fallen 60 dB under the peak, then a fade of three periods (at least 30 ms). Moving the Length slider switches it off.")
                            }
                        }
                    }
                section("Filter") {
                    HStack(spacing: 8) {
                        Text("Type").frame(width: 84, alignment: .leading)
                        Menu {
                            Picker("Type", selection: filterType(pad)) {
                                ForEach(FilterType.allCases) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        } label: {
                            Text(pad.params.filterType.title)
                        }
                        .fixedSize()
                        Spacer()
                    }
                    .font(.callout)
                    row(ParamSpec.spec("filterCutoff"), pad: pad).disabled(pad.params.filterType == .off)
                    row(ParamSpec.spec("filterQ"), pad: pad).disabled(pad.params.filterType == .off)
                }
                section("Master Envelope") {
                    Toggle("On", isOn: envelopeOn(pad))
                        .font(.callout)
                        .controlSize(.small)
                        .padding(.leading, 92)
                        .help("One envelope over the whole drum, after the filter: full level for Hold, then down to silence over Release. Ends every layer's decay at one point; the exported file ends there too. The fit leaves it alone.")
                    ForEach(["envHold", "envRelease", "envCurve"], id: \.self) { id in
                        row(ParamSpec.spec(id), pad: pad).disabled(!pad.params.envelopeOn)
                    }
                }
                section("Pad") {
                    panRow(pad)
                }
                }
                // Only the parameters wait for a drum: the model can be
                // chosen first, and the panel scrolls either way.
                .disabled(!pad.hasSynth)
            }
            .padding(14)
            .background(LegacyScroller())
        }
        // Visible: Filter, Master Envelope and Pad sit below the fold at the
        // window's default height, and a hidden indicator hides them.
        .scrollIndicators(.visible)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    /// Automatic shows what it chose once there is a drum.
    private func modelLabel(_ pad: PadModel) -> String {
        if let choice = pad.modelChoice { return choice.title }
        return pad.hasSynth ? "Automatic · \(pad.params.model.title)" : "Automatic"
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.1)
            content()
        }
    }

    // MARK: - Rows

    private func row(_ spec: ParamSpec, pad: PadModel) -> some View {
        // Length shows what is rendered - automatic or not - and a hand on
        // its slider makes it manual.
        let isLength = spec.id == "length"
        let value = isLength ? pad.params.renderLength : pad.params[keyPath: spec.keyPath]
        // The attack noise is a measured table; without one there is
        // nothing for its level to scale.
        let absent = spec.id == "attackLevelDB" && pad.params.attack == nil
        let clapTitles = ["noise": "Tail", "noiseDecay": "Tail decay", "noiseShape": "Tail shape",
                          "noiseTone": "Burst tone", "noiseWidth": "Burst width"]
        let title = pad.params.isHat && spec.id == "ampAttack" ? "Rise"
            : pad.params.isModal && spec.id == "ampDecay" ? "Mode 1 decay"
            : pad.params.isClap ? clapTitles[spec.id] ?? spec.title : spec.title
        return sliderRow(title, target: spec.id,
                         position: Binding(get: { spec.position(of: value) },
                                           set: {
                                               if isLength { pad.params.autoLength = false }
                                               pad.params[keyPath: spec.keyPath] = spec.value(at: $0)
                                           }),
                         text: absent ? "off" : spec.format(value))
            .disabled(absent)
            .help(Self.help[(pad.params.isHat ? "hat." : pad.params.isModal ? "modal." : pad.params.isClap ? "clap." : "") + spec.id]
                  ?? Self.help[spec.id] ?? "")
    }

    private func panRow(_ pad: PadModel) -> some View {
        let text = abs(pad.pan) < 0.5 ? "C" : String(format: "%@ %.0f", pad.pan < 0 ? "L" : "R", abs(pad.pan))
        return sliderRow("Pan", target: LearnTarget.pan,
                         position: Binding(get: { (pad.pan + 100) / 200 }, set: { pad.pan = $0 * 200 - 100 }),
                         text: text)
            .help("Where the pad sits when played - equal-power, the centre −3 dB each side. Exports stay mono.")
    }

    /// Title, slider, value - with Learn MIDI CC on right-click.
    private func sliderRow(_ title: String, target: String, position: Binding<Double>, text: String) -> some View {
        let isLearning = model.learning == .control(target)
        return HStack(spacing: 8) {
            Text(title)
                .frame(width: 84, alignment: .leading)
            Slider(value: position, in: 0...1)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(text)
            Text(isLearning ? "Learning…" : text)
                .monospacedDigit()
                .foregroundStyle(isLearning ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 70, alignment: .trailing)
        }
        .font(.callout)
        .contextMenu {
            Button(isLearning ? "Cancel Learn" : "Learn MIDI CC") { model.toggleLearn(.control(target)) }
            if let label = model.ccLabel(target) {
                Button("Forget \(label)") { model.forget(target) }
            }
        }
    }

    // MARK: - Bindings

    /// Switching Auto off keeps the length it showed, so nothing jumps.
    private func autoLength(_ pad: PadModel) -> Binding<Bool> {
        Binding(get: { pad.params.autoLength },
                set: { on in
                    if !on { pad.params.length = pad.params.renderLength }
                    pad.params.autoLength = on
                })
    }

    private func drumModel(_ pad: PadModel) -> Binding<DrumModel?> {
        Binding(get: { pad.modelChoice }, set: { pad.choose($0) })
    }

    private func envelopeOn(_ pad: PadModel) -> Binding<Bool> {
        Binding(get: { pad.params.envelopeOn }, set: { pad.params.envelopeOn = $0 })
    }

    private func filterType(_ pad: PadModel) -> Binding<FilterType> {
        Binding(get: { pad.params.filterType }, set: { pad.params.filterType = $0 })
    }

    private static let help: [String: String] = [
        "delay": "Silence before the body, click and noise start. Recorded kicks often begin with a quiet pre-swing of the head; the body follows a few milliseconds later.",
        "attackLevelDB": "Noise shaped like what the original's first 50 ms have that the voice lacks - measured band by band by the fit, never copied. Off when the fit found it did not help.",
        "filterCutoff": "Corner of the low- or high-pass, centre of the band-pass. Right-click to learn a MIDI CC.",
        "envHold": "Full level until here, from the file's start.",
        "envRelease": "Falls to silence over this time after Hold; the file ends there.",
        "envCurve": "How it falls: 1 is linear; higher drops fast and lingers, lower holds and then drops.",
        "filterQ": "Resonance: 0.707 is a plain 24 dB/oct Butterworth; higher peaks at the cutoff.",
        "mode2Level": "The snare head's second mode, relative to the body's peak.",
        "mode2Ratio": "Its pitch over the body's; it follows the body's sweep. 1.5-2.8 on the snares measured.",
        "mode2Decay": "Its time constant - usually much shorter than the body's.",
        "noiseWidth": "Octaves between the wires' high- and low-pass, centred on Noise tone.",
        "metal": "The metal's level in the mix, beside Noise: six square waves at the TR-808's ratios. The analysis splits the two by how peaked the spectrum is.",
        "metalTone": "The lowest of the six oscillators (the 808's is 205.3 Hz); the other five follow at its ratios. Measured from where the original's partials lie.",
        "hat.ampAttack": "How long the hat takes to reach its peak - a few tenths of a millisecond for a closed hat, longer for one that swells.",
        "hat.gainDB": "The hat's level at its start, as RMS: Noise and Metal are the mix relative to it.",
        "hat.noise": "The noise's level in the mix, beside Metal.",
        "hat.noiseTone": "Centre of the band noise and metal both pass through - 24 dB/oct on each side.",
        "hat.noiseWidth": "Octaves between the band's high- and low-pass.",
        "hat.noiseDecay": "Time constant of the whole hat after its rise: short for a closed hat, long for an open one.",
        "hat.noiseShape": "Bends that decay: 1 is a plain exponential; above 1 the hat holds and then falls.",
        "clapBursts": "How many hands: noise bursts one after another, each starting at once.",
        "clapSpacing": "Time between the bursts' starts - about 10 ms on an 808 or 909.",
        "clapBurstDecay": "How fast each burst dies away - a few milliseconds.",
        "clapTailTone": "Centre of the tail's own band - a 909's tail is darker than its bursts.",
        "clapTailWidth": "Octaves between the tail band's high- and low-pass.",
        "clap.gainDB": "A burst's level at its start, as RMS; the tail is relative to it.",
        "clap.noise": "The tail's level, from the last burst on, relative to a burst's.",
        "clap.noiseTone": "Centre of the bursts' band (12 dB/oct each side).",
        "clap.noiseWidth": "Octaves between the bursts' high- and low-pass.",
        "clap.noiseDecay": "Time constant of the tail.",
        "clap.noiseShape": "Bends the tail's decay: under 1 it drops fast and rings on like a room (the 808); above 1 it holds and then falls.",
        "modalTone": "The strongest partial's frequency; modes 2-6 are ratios of it, so this transposes all of them.",
        "modal.ampDecay": "Time constant of mode 1. Each other mode has its own.",
        "modal.ampShape": "Bends every mode's decay: 1 is a plain exponential; under 1 they drop fast and then ring on (an 808 cowbell), above 1 they hold and then fall.",
        "modal.gainDB": "Mode 1's peak level; the other modes' levels are relative to it.",
        "noiseShape": "Bends the wires' decay: 1 is a plain exponential; above 1 they hold first and then fall (a 909), below 1 they drop at once and linger.",
    ]
}

/// Puts the enclosing NSScrollView on AppKit's legacy scroller: always
/// visible, with a track, whatever System Settings say about scroll bars -
/// and back on it when that setting changes, which resets every scroll
/// view to the preferred style.
private struct LegacyScroller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        DispatchQueue.main.async { context.coordinator.apply() }
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            DispatchQueue.main.async { coordinator?.apply() }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { context.coordinator.apply() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var view: NSView?
        var observer: NSObjectProtocol?

        func apply() {
            guard let scrollView = view?.enclosingScrollView else { return }
            if scrollView.scrollerStyle != .legacy { scrollView.scrollerStyle = .legacy }
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = false
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }
}
