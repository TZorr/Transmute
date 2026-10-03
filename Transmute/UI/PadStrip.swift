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
//  Dragging a pad onto another swaps them (AppModel.swapPads). The drag is
//  the app's own gesture, not the system's drag and drop: files dropped
//  from the Finder keep their path untouched, no pasteboard type is needed,
//  and a click without movement still plays the pad. Each pad reports its
//  frame in the strip's coordinate space; the strip finds the one under
//  the pointer, outlines it, dims the source and shows the drum's name at
//  the pointer.
//
//  The whole pad is the drop and click target, not a button inside it (the
//  drop zone's rule, from DropMaster: a drop a few pixels off is a drop the
//  app silently ignores).
//

import SwiftUI

struct PadStrip: View {
    let model: AppModel

    /// The pad being dragged and where the pointer is, in `space`.
    @State private var drag: (from: Int, location: CGPoint)?
    @State private var frames: [Int: CGRect] = [:]

    static let space = "padStrip"

    var body: some View {
        // The lights are read inside the timeline's closure, so the pads
        // redraw with them (see the TimelineView memory).
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let sounding = (0..<DrumKit.padCount).map { model.kit.isSounding($0) }
            let target = dropTarget
            VStack(spacing: 8) {
                ForEach(0..<2, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(model.pads[(row * 8)..<min(row * 8 + 8, model.pads.count)], id: \.index) { pad in
                            PadView(model: model, pad: pad, lit: sounding[pad.index],
                                    dragged: drag?.from == pad.index, swapTarget: target == pad.index,
                                    onDrag: { drag = (pad.index, $0) },
                                    onDrop: drop)
                        }
                    }
                }
            }
        }
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(PadFrames.self) { frames = $0 }
        .overlay(alignment: .topLeading) { ghost }
    }

    /// The pad under the pointer, other than the one being dragged.
    private var dropTarget: Int? {
        guard let drag else { return nil }
        return frames.first { $0.key != drag.from && $0.value.contains(drag.location) }?.key
    }

    private func drop() {
        if let from = drag?.from, let to = dropTarget { model.swapPads(from, to) }
        drag = nil
    }

    /// The dragged drum's name, at the pointer.
    @ViewBuilder
    private var ghost: some View {
        if let drag {
            let name = model.pads[drag.from].name
            Text(name.isEmpty ? "Pad \(drag.from + 1)" : name)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color.accentColor, lineWidth: 1))
                .fixedSize()
                .position(drag.location)
                .allowsHitTesting(false)
        }
    }
}

/// Every pad's frame in the strip's coordinate space, by index.
private struct PadFrames: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct PadView: View {
    let model: AppModel
    let pad: PadModel
    let lit: Bool
    /// Being dragged onto another pad.
    let dragged: Bool
    /// The pad a drag in progress would swap with.
    let swapTarget: Bool
    let onDrag: (CGPoint) -> Void
    let onDrop: () -> Void

    @State private var targeted = false

    private var isSelected: Bool { model.selected == pad.index }
    private var isLearning: Bool { model.learning == .note(pad: pad.index) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(fill)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(border, style: StrokeStyle(lineWidth: isSelected || targeted || swapTarget ? 2 : 1,
                                                            dash: pad.isEmpty && !targeted && !swapTarget ? [5, 4] : []))
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
        .opacity(dragged ? 0.4 : 1)
        .background(GeometryReader { geometry in
            Color.clear.preference(key: PadFrames.self,
                                   value: [pad.index: geometry.frame(in: .named(PadStrip.space))])
        })
        .gesture(DragGesture(minimumDistance: 8, coordinateSpace: .named(PadStrip.space))
            .onChanged { onDrag($0.location) }
            .onEnded { _ in onDrop() })
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
              ? "Click to select and play - higher on the pad is harder. Drop up to sixteen samples here: sorted by name, they replace pads 1-16 without asking; more than sixteen are left out. Drag onto another pad to swap them (the MIDI notes stay). Right-click to learn a MIDI note."
              : "Click to select and play - higher on the pad is harder. Drop a sample here (of several, the first by name). Drag onto another pad to swap them (the MIDI notes stay). Right-click to learn a MIDI note.")
    }

    private var fill: Color {
        if lit { return Color.accentColor.opacity(0.35) }
        if targeted || swapTarget { return Color.accentColor.opacity(0.15) }
        return Color.primary.opacity(isSelected ? 0.07 : 0.04)
    }

    private var border: Color {
        if isSelected || targeted || swapTarget { return Color.accentColor }
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
