//
//  AttackNoise.swift
//  Transmute
//
//  The part of a recorded attack the three-layer voice cannot make: beater,
//  shell and head in the first 50 ms, which on an acoustic kick are not a
//  sine, not one click and not one band of noise. Measured, band by band
//  and millisecond by millisecond, as what the original has that the synth
//  lacks, and played back as noise shaped the same way.
//
//  This is the noise half of Spectral Modeling Synthesis (Serra): the tonal
//  part is modelled, the rest is described by its spectral envelope over
//  time and rebuilt from noise with that envelope. Rebuilt, not copied: no
//  sample of the recording is used, only 1/3-octave levels at 1 ms steps,
//  so crackle and hiss do not come along and the result is as clean and as
//  deterministic (seeded) as the rest of the synth.
//
//  Measured as a difference of *powers*, per band and frame: original power
//  minus synth power, floored at zero. Not as the power of the difference
//  signal: that would also hold the body's phase error - a synth body a
//  few degrees off leaves a large waveform difference with no audible
//  difference at all - and turn it into noise that is heard. Noise added
//  with the missing power makes the sum's expected power the original's.
//
//  Why this and not more synth layers: on three recorded kicks, a lopsided
//  drive, a second envelope stage, an overtone and a set of modal partials
//  each moved the match by at most 0.4 dB, while switching off the one
//  noise layer there was cost 8 dB (see project notes, 2026-09-25).
//
//  The filters for measuring run zero-phase, so the levels sit at the right
//  times; the filters for playing run forward on stationary noise, and the
//  levels are applied after them, so their delay does not move anything.
//

import Foundation
import Accelerate

nonisolated struct AttackTable: Codable, Equatable, Sendable {
    /// Centre frequencies of the bands, Hz.
    var bands: [Double]
    /// Seconds between frames; frame f describes time f·hop.
    var hop: Double
    /// levels[band][frame]: RMS of the missing noise, relative to the
    /// body's peak (so Level scales it along with everything else).
    var levels: [[Float]]

    var duration: Double { hop * Double(levels.first?.count ?? 0) }
}

nonisolated enum AttackNoise {
    /// 1/3-octave centres from 80 Hz to 16 kHz.
    static let bandCentres: [Double] = (0..<24).map { 80 * pow(2, Double($0) / 3) }
    /// Q of a 1/3-octave band-pass.
    static let bandQ = 4.32
    static let hop = 0.001
    static let window = 0.05

    // MARK: - Measuring

    /// Per band, the RMS in `hop` frames over the first `window` seconds.
    static func bandLevels(_ x: [Double], sampleRate sr: Double) -> [[Double]] {
        let frames = Int(window / hop)
        let step = max(Int(hop * sr), 1)
        // A margin after the window, so the zero-phase filters' backward
        // pass does not start inside it.
        let n = min(x.count, Int((window + 0.03) * sr))
        let segment = Array(x.prefix(n))
        return bandCentres.map { centre -> [Double] in
            guard centre < 0.45 * sr else { return [Double](repeating: 0, count: frames) }
            let band = Filters.zeroPhase(segment, [Biquad(.bandPass, frequency: centre, q: bandQ, sampleRate: sr),
                                                   Biquad(.bandPass, frequency: centre, q: bandQ, sampleRate: sr)])
            return (0..<frames).map { f in
                let centreSample = f * step
                let lo = max(centreSample - step, 0), hi = min(centreSample + step, band.count)
                guard hi > lo else { return 0 }
                var ms = 0.0
                band.withUnsafeBufferPointer { vDSP_measqvD($0.baseAddress! + lo, 1, &ms, vDSP_Length(hi - lo)) }
                return ms.squareRoot()
            }
        }
    }

    /// What the original has in its first 50 ms that `synth` lacks, band by
    /// band, relative to `gain` (the body's peak). `floorRatio` is the
    /// recording's noise floor under its peak: hiss is not missing.
    static func measure(original: [Double], synth: [Double], gain: Double, floorRatio: Double,
                        sampleRate sr: Double) -> AttackTable {
        let o = bandLevels(original, sampleRate: sr)
        let s = bandLevels(synth, sampleRate: sr)
        let peak = original.map(abs).max() ?? 0
        // The floor per band: the recording's floor, spread evenly over the
        // bands - rough, but hiss is broadband and this only has to keep it
        // from being counted as attack.
        let floorPower = pow(peak * floorRatio, 2) / Double(bandCentres.count)
        let levels = (0..<bandCentres.count).map { b -> [Float] in
            (0..<o[b].count).map { f in
                let missing = o[b][f] * o[b][f] - s[b][f] * s[b][f] - floorPower
                return missing > 0 ? Float(missing.squareRoot() / max(gain, 1e-9)) : 0
            }
        }
        return AttackTable(bands: bandCentres, hop: hop, levels: levels)
    }

    // MARK: - Playing

    /// The shaped noise, `frames` long, relative to the body's peak.
    static func render(_ table: AttackTable, sampleRate sr: Double, frames n: Int) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        let frames = table.levels.first?.count ?? 0
        guard frames > 0 else { return out }
        // One hop past the last frame, where the levels have fallen to 0.
        let m = min(n, Int(table.hop * Double(frames) * sr))
        let length = max(m, 2048)
        for (b, centre) in table.bands.enumerated() where centre < 0.45 * sr {
            let levels = table.levels[b]
            guard levels.contains(where: { $0 > 0 }) else { continue }
            var random = Xorshift(seed: 0xA77A_C000 &+ UInt64(b))
            var f1 = Biquad(.bandPass, frequency: centre, q: bandQ, sampleRate: sr)
            var f2 = Biquad(.bandPass, frequency: centre, q: bandQ, sampleRate: sr)
            // Let the filters settle before the part that is used.
            let settle = Int(4 * sr / centre) + 64
            for _ in 0..<settle { _ = f2.process(f1.process(random.next())) }
            var band = [Double](repeating: 0, count: length)
            for i in 0..<length { band[i] = f2.process(f1.process(random.next())) }
            var rms = 0.0
            vDSP_rmsqvD(band, 1, &rms, vDSP_Length(length))
            guard rms > 0 else { continue }
            for i in 0..<m {
                // Linear between frame times; the last frame falls to 0.
                let position = Double(i) / sr / table.hop
                let f = Int(position)
                let frac = position - Double(f)
                let a = f < frames ? Double(levels[f]) : 0
                let c = f + 1 < frames ? Double(levels[f + 1]) : 0
                out[i] += band[i] / rms * (a + (c - a) * frac)
            }
        }
        return out
    }
}
