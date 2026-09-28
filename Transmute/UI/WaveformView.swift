//
//  WaveformView.swift
//  Transmute
//
//  The original and the synth on one time axis, one over the other, and
//  a playhead while either sounds.
//
//  Overlaid rather than stacked, because the question the view answers is
//  "where do they differ", and two separate lanes make the eye do the
//  subtraction. The original is the grey body, the synth an accent outline
//  on top: where they agree the outline sits on the edge of the grey.
//
//  Two zooms. The whole hit shows the decay and the length; the first
//  50 ms show the attack, the click and the first cycles of the sweep,
//  which is where a kick is made or lost and which the whole view squeezes
//  into a few pixels.
//
//  Each column of pixels draws the min and max of its samples - not a
//  sample picked from each column, which aliases a 58 Hz wave into
//  patterns that are not there.
//

import SwiftUI

enum WaveZoom: String, CaseIterable, Identifiable {
    case whole = "Whole hit"
    case attack = "First 50 ms"
    var id: String { rawValue }
}

struct WaveformView: View {
    let original: MonoAudio?
    let synth: MonoAudio?
    let player: OneShotPlayer
    let zoom: WaveZoom

    var body: some View {
        let seconds = zoom == .attack ? 0.05 : max(original?.duration ?? 0, synth?.duration ?? 0, 0.05)
        // The playhead is read inside the timeline's closure: a child view
        // handed only the player would never redraw.
        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { _ in
            let playing = player.playing
            let position = player.positionSeconds
            Canvas { context, size in
                drawGrid(context, size: size, seconds: seconds)
                if let original {
                    draw(original, context, size: size, seconds: seconds, filled: true,
                         color: Color.secondary.opacity(0.45))
                }
                if let synth {
                    draw(synth, context, size: size, seconds: seconds, filled: false, color: Color.accentColor)
                }
                if playing != nil, position <= seconds {
                    let x = size.width * position / seconds
                    context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(playing == .synth ? Color.accentColor : Color.primary), lineWidth: 1)
                }
            }
        }
        .accessibilityLabel("Waveforms of the original and the synth")
    }

    private func draw(_ audio: MonoAudio, _ context: GraphicsContext, size: CGSize, seconds: Double,
                      filled: Bool, color: Color) {
        let columns = max(Int(size.width), 1)
        let mid = size.height / 2
        let scale = size.height / 2 * 0.95
        let framesPerColumn = seconds * audio.sampleRate / Double(columns)
        var upper: [CGPoint] = [], lower: [CGPoint] = []
        upper.reserveCapacity(columns)
        lower.reserveCapacity(columns)
        for c in 0..<columns {
            let start = Int(Double(c) * framesPerColumn)
            guard start < audio.frameCount else { break }
            let end = min(max(Int(Double(c + 1) * framesPerColumn), start + 1), audio.frameCount)
            var low = audio.samples[start], high = low
            for i in start..<end {
                let v = audio.samples[i]
                if v < low { low = v }
                if v > high { high = v }
            }
            let x = CGFloat(c) + 0.5
            upper.append(CGPoint(x: x, y: mid - CGFloat(high) * scale))
            lower.append(CGPoint(x: x, y: mid - CGFloat(low) * scale))
        }
        guard !upper.isEmpty else { return }
        if filled {
            // One subpath, out along the maxima and back along the minima.
            // Two `addLines` calls would be two subpaths, each closed by a
            // chord back to its own start - which filled a grey triangle
            // over the whole decay.
            var band = Path()
            band.move(to: upper[0])
            for point in upper.dropFirst() { band.addLine(to: point) }
            for point in lower.reversed() { band.addLine(to: point) }
            band.closeSubpath()
            context.fill(band, with: .color(color))
        } else {
            context.stroke(Path { $0.addLines(upper) }, with: .color(color), lineWidth: 1.2)
            if framesPerColumn > 2 {
                context.stroke(Path { $0.addLines(lower) }, with: .color(color), lineWidth: 1.2)
            }
        }
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize, seconds: Double) {
        let mid = size.height / 2
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                       with: .color(Color.primary.opacity(0.12)), lineWidth: 1)
        // A tick every 10 ms zoomed in, every 100 ms otherwise.
        let step = seconds <= 0.05 ? 0.01 : seconds <= 1 ? 0.1 : 0.25
        var t = step
        while t < seconds {
            let x = size.width * t / seconds
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                           with: .color(Color.primary.opacity(0.06)), lineWidth: 1)
            let label = step < 0.1 ? String(format: "%.0f ms", t * 1000) : String(format: "%.2g s", t)
            context.draw(Text(label).font(.caption2).foregroundStyle(.tertiary),
                         at: CGPoint(x: x + 3, y: size.height - 4), anchor: .bottomLeading)
            t += step
        }
    }
}
