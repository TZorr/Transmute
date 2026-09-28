//
//  PitchView.swift
//  Transmute
//
//  The sweep: every period the analysis measured, as a dot, and the curve
//  the synth plays through them.
//
//  The dots are the evidence and the curve is the claim. A curve that
//  runs through the dots is a pitch the synth really has; one that misses
//  them - usually right at the start, where the first cycle is short and
//  the click sits on top of it - shows where to put the Pitch start slider
//  by hand. Dots fade with the envelope, because the fit weighs them that
//  way: a period measured 40 dB down counts for little.
//
//  Log frequency, because pitch is heard in ratios: the drop from 140 to
//  70 Hz should look as large as the one from 70 to 35.
//

import SwiftUI

struct PitchView: View {
    let track: [PitchPoint]
    let params: DrumParams

    var body: some View {
        Canvas { context, size in
            // Six time constants: the sweep and where it settles. The track
            // runs to the end of the hit, and showing all of it left the
            // sweep a quarter of the width and the rest a flat line.
            let seconds = min(max(6 * params.pitchDecay, 0.06), params.renderLength)
            let frequencies = track.map(\.hz) + [params.pitchStart, params.fundamental]
            let low = max((frequencies.min() ?? 40) / 1.3, 15)
            let high = (frequencies.max() ?? 200) * 1.3
            func y(_ hz: Double) -> CGFloat {
                size.height * (1 - CGFloat(log(hz / low) / log(high / low)))
            }
            func x(_ t: Double) -> CGFloat { size.width * CGFloat(t / seconds) }

            // Gridlines at 1-2-5 steps.
            for decade in [10.0, 100, 1000] {
                for m in [1.0, 2, 5] {
                    let hz = decade * m
                    guard hz > low, hz < high else { continue }
                    let row = y(hz)
                    context.stroke(Path { $0.move(to: CGPoint(x: 0, y: row)); $0.addLine(to: CGPoint(x: size.width, y: row)) },
                                   with: .color(Color.primary.opacity(0.07)), lineWidth: 1)
                    context.draw(Text(hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz")
                                    .font(.caption2).foregroundStyle(.tertiary),
                                 at: CGPoint(x: 3, y: row < 14 ? row + 1 : row - 1),
                                 anchor: row < 14 ? .topLeading : .bottomLeading)
                }
            }

            for point in track where point.time <= seconds {
                let r = 1.5 + 2 * CGFloat(point.weight)
                let dot = Path(ellipseIn: CGRect(x: x(point.time) - r, y: y(point.hz) - r, width: 2 * r, height: 2 * r))
                context.fill(dot, with: .color(Color.secondary.opacity(0.25 + 0.55 * point.weight)))
            }

            var curve = Path()
            let steps = max(Int(size.width / 2), 2)
            for i in 0...steps {
                let t = seconds * Double(i) / Double(steps)
                let p = CGPoint(x: x(t), y: y(params.pitch(at: t)))
                if i == 0 { curve.move(to: p) } else { curve.addLine(to: p) }
            }
            context.stroke(curve, with: .color(Color.accentColor), lineWidth: 1.8)

            let label = String(format: "%.0f ms", seconds * 1000)
            context.draw(Text(label).font(.caption2).foregroundStyle(.tertiary),
                         at: CGPoint(x: size.width - 3, y: size.height - 3), anchor: .bottomTrailing)
        }
        .accessibilityLabel("Pitch: measured periods and the synth's sweep")
    }
}
