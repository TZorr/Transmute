//
//  PadStrip.swift
//  Transmute
//
//  The sixteen pads along the bottom of the window, in two rows of eight,
//  flatter than the eight were. Each is a drop target for samples - pad 1,
//  "1 Multi", for up to sixteen at once, which fill pads 1-16 by name; the
//  others for one (see DrumKit.dropTargets) - a button that
//  plays it, and the way to choose which pad the panel above edits.
//
//  A pad shows its drum's name, where its analysis and fit are, and the
//  MIDI note it answers to; it lights while it sounds. Right-click for
//  Load Sample…, Open Parameters…, Learn Note and Clear.
//
//  The whole pad is the drop and click target, not a button inside it (the
//  drop zone's rule, from DropMaster: a drop a few pixels off is a drop the
//  app silently ignores).
//

import SwiftUI

struct PadStrip: View {
    let model: AppModel

    var body: some View {
        // The lights are read inside the timeline's closure, so the pads
        // redraw with them (see the TimelineView memory).
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let sounding = (0..<DrumKit.padCount).map { model.kit.isSounding($0) }
            VStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(model.pads[(row * 8)..<min(row * 8 + 8, model.pads.count)], id: \.index) { pad in
                            PadView(model: model, pad: pad, lit: sounding[pad.index])
                        }
                    }
                }
            }
        }
    }
}

private struct PadView: View {
    let model: AppModel
    let pad: PadModel
    let lit: Bool

    @State private var targeted = false

    private var isSelected: Bool { model.selected == pad.index }
    private var isLearning: Bool { model.learning == .note(pad: pad.index) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(fill)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: isSelected || targeted ? 2 : 1,
                                                            dash: pad.isEmpty && !targeted ? [5, 4] : []))
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(pad.index == 0 ? "1 Multi" : "\(pad.index + 1)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(isLearning ? "Learning…" : NoteName.string(pad.note))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(isLearning ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    }
                    Spacer(minLength: 0)
                    Text(pad.name.isEmpty ? "Drop a sample" : pad.name)
                        .font(.callout)
                        .foregroundStyle(pad.name.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    status
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.tap(pad.index) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.drop(urls, on: pad.index)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Load Sample…") { model.chooseSample(for: pad.index) }
            Button("Open Parameters…") {
                model.selected = pad.index
                model.openParams()
            }
            Divider()
            Button(isLearning ? "Cancel Learn" : "Learn Note") { model.toggleLearn(.note(pad: pad.index)) }
            Divider()
            Button("Clear Pad") { pad.clear() }
                .disabled(pad.isEmpty)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Pad \(pad.index + 1): \(pad.name.isEmpty ? "empty" : pad.name)")
        .accessibilityAddTraits(.isButton)
        .help(pad.index == 0
              ? "Click to select and play - higher on the pad is harder. Drop up to sixteen samples here: sorted by name, they replace pads 1-16 without asking; more than sixteen are left out. Right-click to learn a MIDI note."
              : "Click to select and play - higher on the pad is harder. Drop a sample here (of several, the first by name). Right-click to learn a MIDI note.")
    }

    private var fill: Color {
        if lit { return Color.accentColor.opacity(0.35) }
        if targeted { return Color.accentColor.opacity(0.15) }
        return Color.primary.opacity(isSelected ? 0.07 : 0.04)
    }

    private var border: Color {
        if isSelected || targeted { return Color.accentColor }
        return Color.secondary.opacity(0.45)
    }

    @ViewBuilder
    private var status: some View {
        switch pad.stage {
        case .decoding, .analysing:
            Text("Analysing…").font(.caption2).foregroundStyle(.secondary)
        case .queued:
            Text("Waiting to fit").font(.caption2).foregroundStyle(.secondary)
        case .fitting(let fraction):
            ProgressView(value: fraction).controlSize(.mini)
        case .failed:
            Text("Could not read").font(.caption2).foregroundStyle(.orange)
        case .done:
            if let score = pad.score {
                Text(String(format: "Match %.1f dB", score.total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            } else {
                Text(" ").font(.caption2)
            }
        case .empty:
            Text(" ").font(.caption2)
        }
    }
}
