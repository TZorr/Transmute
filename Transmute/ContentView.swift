//
//  ContentView.swift
//  Transmute
//
//  One window: at the top the selected pad - the original and the synth
//  over each other, the pitch, the parameters; at the bottom the sixteen pads
//  to drop samples on and play; under them listening, fitting and export
//  for the selected pad.
//
//  The Match figure sits over the waveform because it describes what the
//  waveform shows: the mean distance between the two, in dB, across
//  spectrum and envelope (see Comparison). It is a number to compare with
//  itself - before and after a slider move, the analysis against the fit -
//  not a grade: a recording with crackle keeps a few dB the clean synth
//  will rightly never close.
//

import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var zoom: WaveZoom
    @Environment(\.openWindow) private var openWindow

    init(model: AppModel, initialZoom: WaveZoom = .whole) {
        self.model = model
        _zoom = State(initialValue: initialZoom)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    waveHeader
                    WaveformView(original: model.pad.original, synth: model.pad.synth, player: model.player, zoom: zoom)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                        .frame(minHeight: 200, maxHeight: .infinity)
                    Text("PITCH")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .tracking(1.1)
                        .padding(.top, 4)
                    // Nothing before there is a synth: the default sweep drawn
                    // over an empty window looked like a result.
                    Group {
                        if model.pad.hasSynth && (model.pad.params.isHat || model.pad.params.isModal || model.pad.params.isClap) {
                            Text(model.pad.params.isHat ? "A hi-hat has no pitch sweep - its metal tone is under Metal."
                                 : model.pad.params.isModal ? "A modal drum has no pitch sweep - its partials are under Modes."
                                 : "A clap has no pitch - it is noise, in bursts and a tail.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if model.pad.hasSynth {
                            PitchView(track: model.pad.analysis?.pitchTrack ?? [], params: model.pad.params)
                        } else {
                            Color.clear
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
                    .frame(height: 150)
                }
                ParameterPanel(model: model)
                    .frame(width: 330)
            }
            .frame(maxHeight: .infinity)

            PadStrip(model: model)
                .frame(height: 136)

            Divider()

            bottomBar
        }
        .padding(20)
        .frame(minWidth: 1040, minHeight: 780)
        .background(WindowReader { model.installTabMonitor(for: $0) })
    }

    // MARK: - Pieces

    private var waveHeader: some View {
        HStack(spacing: 14) {
            legend
            Picker("Zoom", selection: $zoom) {
                ForEach(WaveZoom.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            match
        }
        .font(.callout)
        .frame(height: 22)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.45)).frame(width: 14, height: 8)
                Text("Original")
            }
            HStack(spacing: 4) {
                Capsule().fill(Color.accentColor).frame(width: 14, height: 2)
                Text("Synth")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var match: some View {
        if let score = model.pad.score {
            HStack(spacing: 6) {
                Text("Match").foregroundStyle(.secondary)
                Text(String(format: "%.2f dB", score.total)).monospacedDigit()
                if let fitted = model.pad.fitted {
                    Text(String(format: "(analysis alone %.2f)", fitted.initialScore.total))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
            .help(String(format: "Mean distance from the original, lower is closer: spectrum %.2f dB, envelope %.2f dB, pitch %.2f semitones. A recording's crackle and hiss stay in it - the synth leaves them out on purpose.",
                         score.spectralDB, score.envelopeDB, score.pitchSemitones))
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                model.player.play(.original)
            } label: {
                Label("Original", systemImage: "play.fill")
            }
            .disabled(model.pad.original == nil)
            .help("Play the original hit (⌘1)")

            Button {
                model.player.play(.synth)
            } label: {
                Label("Synth", systemImage: "play.fill")
            }
            .disabled(!model.pad.hasSynth)
            .help("Play the synth (⌘2); Space plays the last one again")

            Divider().frame(height: 18)

            Button("Fit Again") { model.pad.refit() }
                .disabled(!model.pad.canFit)
                .help("Fit from the parameters as they are now (⌘R)")
            Button("Reset") { model.pad.resetToFit() }
                .disabled(!model.pad.canReset)
                .help("Back to what the last fit found (⇧⌘R)")
            Button("Clear") { model.clearAllPads() }
                .disabled(!model.hasAnyDrum)
                .help("Empty all sixteen pads. Their pan, notes and model choice stay.")
            Button("Limit to \(model.maxLevelLabel)") { model.limitPeaks() }
                .disabled(!model.hasAnyDrum)
                .help("Every pad whose peak is above \(model.maxLevelLabel) gets its Level lowered until the peak is there; pads under it stay as they are. The max level is set in Settings (⌥⌘L).")

            Spacer()

            if let message = model.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            peak
            Button("Batch Convert…") { openWindow(id: BatchMenuItem.windowID) }
                .help("Open the Batch Convert window: many samples fitted and written as files in one go (⇧⌘B)")
            Button("Export Kit…") { model.exportKit() }
                .disabled(!model.canExportKit)
                .help("Every pad with a drum as \"<prefix> <pad number>\", in the format and depth beside it (⌥⌘E)")
            ExportBoxes(model: model)
        }
    }

    /// The synth's peak, orange above 0 dBFS: float files keep it, integer
    /// ones clip it.
    @ViewBuilder
    private var peak: some View {
        if let peak = model.pad.peakDB {
            let clips = peak > 0
            Text(String(format: "Peak %+.1f dBFS", peak))
                .font(.callout.monospacedDigit())
                .foregroundStyle(clips ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .help(clips ? "Above 0 dBFS: a 32-bit float export keeps it, 16- and 24-bit ones clip. Lower Level to fix it."
                            : "The synth's highest sample")
        }
    }
}

/// Hands the hosting NSWindow to `found` once the view is in it - the
/// window the Tab monitor listens to.
private struct WindowReader: NSViewRepresentable {
    let found: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            if let window = view?.window { found(window) }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
