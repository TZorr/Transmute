//
//  DrumSynth.swift
//  Transmute
//
//  DrumParams in, samples out. A pure function: the same parameters at the
//  same rate give the same samples, bit for bit, every time.
//
//  That is not tidiness, it is what the fitter stands on. The fit renders
//  the drum a thousand times and compares each render with the original;
//  if two renders of one parameter set differed - a noise generator seeded
//  from the clock, a filter state carried over from the last call - the fit
//  would be chasing its own randomness. It is also why this is not an
//  AVAudioEngine graph or a SuperCollider server: a function in the same
//  process costs about a millisecond per render, a round trip to a server
//  far more, and neither would be bit-exact.
//
//  The body's phase is computed in closed form, not accumulated: with the
//  pitch f(t) = f₁ + (f₀ − f₁)·e^(−t/τ), the phase is its integral,
//  2π·(f₁·t + (f₀ − f₁)·τ·(1 − e^(−t/τ))). An accumulator adds a rounding
//  error per sample and drifts; the closed form is exact at every sample,
//  which also lets the analysis compare phases with the original.
//
//  The two noise layers use fixed seeds, and their level is normalised
//  after filtering, so `transient` and `noise` mean the same at any tone.
//
//  A snare (DrumParams.model) adds a second head mode to the body - its
//  phase is the body's times the ratio, so it follows the same sweep in
//  closed form too - and plays its noise layer as snare wires: a
//  high- and a low-pass instead of the one band-pass, and a decay with a
//  shape.
//
//  A modal drum's body is its modes (see `modal`): damped sines at fixed
//  frequencies, each starting at phase 0 as a struck resonator does.
//
//  A clap has no body either: its noise layer is its bursts and tail (see
//  `clap`).
//
//  A hi-hat has no body: its noise layer is noise and metal together (see
//  `hat`), the metal six band-limited square waves (polyBLEP, so the
//  export rate does not change what aliases) at the 808's ratios.
//  The render is as long as `renderLength`: by default until the synth
//  has decayed 60 dB, whatever the original's length, and then a fade of
//  three periods (see DrumParams.fadeSeconds) that ends on exactly 0. A
//  length set by hand can still cut a tail that is sounding; the fade then
//  makes that a decay, not a click.
//
//  The master envelope, when on, comes after the filter and before the
//  level: it holds, then brings everything down to exactly 0 on the
//  render's last frame, so no fade follows it - unless a Length set by
//  hand ends the render first.
//

import Foundation
import Accelerate

nonisolated enum DrumSynth {
    /// The drum at `sampleRate`, `renderLength` long - or, with `frames`,
    /// exactly that many frames of it: cut off if the drum is longer (no fade
    /// then - it is a window onto the same drum, the way the fit compares
    /// it with the original), padded with silence if shorter. Either way the
    /// fit judges the samples that get exported, and does not pay for
    /// rendering a tail beyond the original.
    static func render(_ params: DrumParams, sampleRate: Double, frames: Int? = nil) -> [Float] {
        let p = params
        let total = max(Int((p.renderLength * sampleRate).rounded()), 1)
        let n = min(frames ?? total, total)
        var out = body(p, sampleRate: sampleRate, frames: n)

        // Click and noise start with the body, after the delay; the attack
        // noise below does not - it was measured on the original's own
        // clock, pre-swing and all.
        let d = delayFrames(p, sampleRate: sampleRate, frames: n)
        if p.transient > 0, n > d {
            let burst = click(p, sampleRate: sampleRate, frames: n - d)
            for i in burst.indices { out[d + i] += p.transient * burst[i] }
        }
        if p.isHat {
            if p.noise + p.metal > 0, n > d {
                let layer = hat(p, sampleRate: sampleRate, frames: n - d)
                for i in layer.indices { out[d + i] += layer[i] }
            }
        } else if p.isClap {
            if n > d {
                let layer = clap(p, sampleRate: sampleRate, frames: n - d)
                for i in layer.indices { out[d + i] += layer[i] }
            }
        } else if p.noise > 0, n > d {
            let layer = noiseLayer(p, sampleRate: sampleRate, frames: n - d)
            for i in layer.indices { out[d + i] += p.noise * layer[i] }
        }

        if let table = p.attack {
            let layer = AttackNoise.render(table, sampleRate: sampleRate, frames: n)
            let level = pow(10, p.attackLevelDB / 20)
            for i in layer.indices { out[i] += level * layer[i] }
        }

        applyFilter(p, to: &out, sampleRate: sampleRate)
        let envelopeEnd = applyEnvelope(p, to: &out, sampleRate: sampleRate)

        var gain = pow(10, p.gainDB / 20)
        vDSP_vsmulD(out, 1, &gain, &out, 1, vDSP_Length(n))

        // The fade, where the drum really ends - inside the window, or not
        // at all; not after the master envelope, which is at 0 already. At
        // most 30 % of the drum, for a short one set by hand.
        if n == total && !(envelopeEnd.map { $0 <= n } ?? false) {
            let fade = min(Int(p.fadeSeconds * sampleRate), Int(0.3 * Double(n)))
            for i in 0..<fade {
                out[n - 1 - i] *= 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade))
            }
        }
        var result = [Float](repeating: 0, count: frames ?? n)
        vDSP_vdpsp(out, 1, &result, 1, vDSP_Length(n))
        return result
    }

    static func renderAudio(_ params: DrumParams, sampleRate: Double, frames: Int? = nil) -> MonoAudio {
        MonoAudio(render(params, sampleRate: sampleRate, frames: frames), sampleRate: sampleRate)
    }

    // MARK: - Filter

    /// The voice filter, forward like any synth's (it is heard, not
    /// measured). Low- and high-pass are two sections, 24 dB/oct: at Q
    /// 0.707 a Butterworth pair (Q 0.541 and 1.307), a higher Q raising the
    /// second section's resonance. Band-pass is two constant-peak sections
    /// at the Q, so the band keeps 0 dB at its centre. Off leaves the
    /// samples untouched - not filtered flat, untouched.
    static func applyFilter(_ p: DrumParams, to x: inout [Double], sampleRate: Double) {
        let sections: [Biquad]
        switch p.filterType {
        case .off:
            return
        case .lowPass:
            sections = [Biquad(.lowPass, frequency: p.filterCutoff, q: 0.5412, sampleRate: sampleRate),
                        Biquad(.lowPass, frequency: p.filterCutoff, q: p.filterQ * 1.3066 / 0.7071, sampleRate: sampleRate)]
        case .highPass:
            sections = [Biquad(.highPass, frequency: p.filterCutoff, q: 0.5412, sampleRate: sampleRate),
                        Biquad(.highPass, frequency: p.filterCutoff, q: p.filterQ * 1.3066 / 0.7071, sampleRate: sampleRate)]
        case .bandPass:
            sections = [Biquad(.bandPass, frequency: p.filterCutoff, q: p.filterQ, sampleRate: sampleRate),
                        Biquad(.bandPass, frequency: p.filterCutoff, q: p.filterQ, sampleRate: sampleRate)]
        }
        for var section in sections { section.run(&x) }
    }

    // MARK: - Master envelope

    /// The frame the master envelope is 0 from; nil when it is off.
    static func envelopeEndFrame(_ p: DrumParams, sampleRate: Double) -> Int? {
        guard p.envelopeOn else { return nil }
        return max(Int((p.envelopeEnd * sampleRate).rounded()), 1)
    }

    /// Full level up to `envHold`, then (1 − x)^curve with x running from
    /// 0 to exactly 1 on the frame before `envelopeEndFrame` - so a render
    /// that ends there ends on 0 - and silence after. Returns that end
    /// frame; nil and untouched samples when the envelope is off.
    @discardableResult
    static func applyEnvelope(_ p: DrumParams, to x: inout [Double], sampleRate: Double) -> Int? {
        guard let end = envelopeEndFrame(p, sampleRate: sampleRate) else { return nil }
        let hold = min(max(Int((p.envHold * sampleRate).rounded()), 0), end - 1)
        let span = Double(max(end - 1 - hold, 1))
        let n = x.count
        for i in min(hold, n)..<min(end, n) {
            x[i] *= pow(max(1 - Double(i - hold) / span, 0), p.envCurve)
        }
        if end < n {
            for i in end..<n { x[i] = 0 }
        }
        return end
    }

    // MARK: - Body

    /// Frames of silence before the voice starts (see DrumParams.delay).
    static func delayFrames(_ p: DrumParams, sampleRate: Double, frames n: Int) -> Int {
        min(max(Int((p.delay * sampleRate).rounded()), 0), n)
    }

    /// The swept sine under its envelope, with drive, after `delay` frames
    /// of silence. Peak 1 before drive, and 1 after it (the tanh is
    /// normalised).
    static func body(_ p: DrumParams, sampleRate: Double, frames: Int) -> [Double] {
        if p.isHat || p.isClap { return [Double](repeating: 0, count: frames) }
        let d = delayFrames(p, sampleRate: sampleRate, frames: frames)
        let make = p.isModal ? modal : voice
        guard d > 0 else { return make(p, sampleRate, frames) }
        return [Double](repeating: 0, count: d) + make(p, sampleRate, frames - d)
    }

    /// The body from its own start: time 0 is the end of the delay.
    private static func voice(_ p: DrumParams, sampleRate: Double, frames n: Int) -> [Double] {
        guard n > 0 else { return [] }
        let count = vDSP_Length(n)
        var t = [Double](repeating: 0, count: n)
        var start = 0.0, step = 1 / sampleRate
        vDSP_vrampD(&start, &step, &t, 1, count)
        var size = Int32(n)

        // Phase, closed form (see the file header).
        let tau = p.pitchDecay
        let delta = p.pitchStart - p.fundamental
        var decay = [Double](repeating: 0, count: n)
        var scale = -1 / tau
        vDSP_vsmulD(t, 1, &scale, &decay, 1, count)
        vvexp(&decay, decay, &size)                                 // e^(−t/τ)
        let phase0 = p.startPhase * .pi / 180
        var phase = [Double](repeating: 0, count: n)
        for i in 0..<n {
            phase[i] = 2 * .pi * (p.fundamental * t[i] + delta * tau * (1 - decay[i])) + phase0
        }
        var wave = [Double](repeating: 0, count: n)
        vvsin(&wave, phase, &size)

        // Envelope: a half-cosine rise over the attack, then
        // exp(−(u/τ)^k) with u the time since the attack ended.
        let attack = p.ampAttack
        var u = [Double](repeating: 0, count: n)
        var shift = -attack
        vDSP_vsaddD(t, 1, &shift, &u, 1, count)
        var zero = 0.0, inverse = 1 / p.ampDecay
        vDSP_vthrD(u, 1, &zero, &u, 1, count)                       // max(u, 0)
        vDSP_vsmulD(u, 1, &inverse, &u, 1, count)
        vvlog(&u, u, &size)                                         // ln(u/τ); −inf at 0
        var k = p.ampShape
        vDSP_vsmulD(u, 1, &k, &u, 1, count)
        vvexp(&u, u, &size)                                         // (u/τ)^k
        var minusOne = -1.0
        vDSP_vsmulD(u, 1, &minusOne, &u, 1, count)
        vvexp(&u, u, &size)                                         // exp(−(u/τ)^k)
        let attackFrames = min(n, Int(attack * sampleRate))
        for i in 0..<attackFrames {
            let x = sin(0.5 * .pi * t[i] / attack)
            u[i] = x * x
        }
        vDSP_vmulD(wave, 1, u, 1, &wave, 1, count)

        if p.drive > 1e-4 {
            let d = p.drive, norm = 1 / tanh(d)
            for i in 0..<n { wave[i] = tanh(d * wave[i]) * norm }
        }

        // A snare's second mode: the same rise, its own exponential, after
        // the drive - a separate membrane mode, not a harmonic of the first.
        if p.isSnare && p.mode2Level > 0 {
            let ratio = p.mode2Ratio, rate = -1 / p.mode2Decay
            var mode = [Double](repeating: 0, count: n)
            for i in 0..<n { mode[i] = ratio * (phase[i] - phase0) + phase0 }
            vvsin(&mode, mode, &size)
            for i in 0..<n {
                let rise: Double
                if i < attackFrames {
                    let x = sin(0.5 * .pi * t[i] / attack)
                    rise = x * x
                } else {
                    rise = exp(max(t[i] - attack, 0) * rate)
                }
                wave[i] += p.mode2Level * rise * mode[i]
            }
        }
        return wave
    }

    // MARK: - Click and noise

    /// The beater: white noise under a fast exponential, high-passed at
    /// `clickTone`, peak 1. Only as long as it is audible (12 time
    /// constants, −104 dB), so a long render does not pay for silence.
    static func click(_ p: DrumParams, sampleRate: Double, frames n: Int) -> [Double] {
        let m = min(n, max(Int(12 * p.clickDecay * sampleRate), 16))
        var random = Xorshift(seed: 0xC11C_0001)
        var filter = Biquad(.highPass, frequency: p.clickTone, q: 0.7071, sampleRate: sampleRate)
        var burst = [Double](repeating: 0, count: m)
        for i in 0..<m {
            let env = exp(-Double(i) / (p.clickDecay * sampleRate))
            burst[i] = filter.process(random.next() * env)
        }
        var peak = 0.0
        vDSP_maxmgvD(burst, 1, &peak, vDSP_Length(m))
        if peak > 0 {
            var s = 1 / peak
            vDSP_vsmulD(burst, 1, &s, &burst, 1, vDSP_Length(m))
        }
        return burst
    }

    /// The shell: white noise band-passed at `noiseTone`, scaled to RMS 1
    /// before its envelope, then decaying. Same 12-time-constant length.
    /// On a snare, the wires instead (see `wires`).
    static func noiseLayer(_ p: DrumParams, sampleRate: Double, frames n: Int) -> [Double] {
        if p.isSnare { return wires(p, sampleRate: sampleRate, frames: n) }
        let m = min(n, max(Int(12 * p.noiseDecay * sampleRate), 2048))
        var random = Xorshift(seed: 0x5E11_0002)
        var filter = Biquad(.bandPass, frequency: p.noiseTone, q: 0.8, sampleRate: sampleRate)
        var band = [Double](repeating: 0, count: m)
        for i in 0..<m { band[i] = filter.process(random.next()) }
        var rms = 0.0
        vDSP_rmsqvD(band, 1, &rms, vDSP_Length(m))
        let norm = rms > 0 ? 1 / rms : 0
        let rate = 1 / (p.noiseDecay * sampleRate)
        for i in 0..<m { band[i] *= norm * exp(-Double(i) * rate) }
        return band
    }

    /// Snare wires: white noise through a 12 dB/oct high-pass and low-pass
    /// `noiseWidth` octaves apart, centred (in log frequency) on
    /// `noiseTone`, RMS 1, under exp(−(t/τ)^k) - k above 1 holds, then
    /// falls. As long as that takes to reach e^(−12), like the shell.
    static func wires(_ p: DrumParams, sampleRate sr: Double, frames n: Int) -> [Double] {
        let k = p.noiseShape
        let m = min(n, max(Int(p.noiseDecay * pow(12, 1 / k) * sr), 2048))
        var random = Xorshift(seed: 0x5E11_0003)
        var band = (0..<m).map { _ in random.next() }
        band = bandPass(band, p, sampleRate: sr)
        let step = 1 / (p.noiseDecay * sr)
        for i in 0..<m { band[i] *= exp(-pow(Double(i) * step, k)) }
        return band
    }

    /// The wires' and the hat's band: a high- and a low-pass `noiseWidth`
    /// octaves apart around `noiseTone`, then RMS 1. 12 dB/oct for the
    /// wires; 24 for a hat (two Butterworth sections each side) - the 808
    /// hats fall about 35 dB in the octave under their peak, and at 12 the
    /// synth had 10-23 dB too much at 1-4 kHz, not least the metal's own
    /// fundamentals at 200-800 Hz.
    static func bandPass(_ x: [Double], _ p: DrumParams, sampleRate sr: Double) -> [Double] {
        let half = pow(2, 0.5 * p.noiseWidth)
        let low = min(max(p.noiseTone / half, 20), 0.45 * sr)
        let high = min(p.noiseTone * half, 0.45 * sr)
        var sections: [Biquad]
        if p.isHat {
            sections = [Biquad(.highPass, frequency: low, q: 0.5412, sampleRate: sr),
                        Biquad(.highPass, frequency: low, q: 1.3066, sampleRate: sr),
                        Biquad(.lowPass, frequency: high, q: 0.5412, sampleRate: sr),
                        Biquad(.lowPass, frequency: high, q: 1.3066, sampleRate: sr)]
        } else {
            sections = [Biquad(.highPass, frequency: low, q: 0.7071, sampleRate: sr),
                        Biquad(.lowPass, frequency: high, q: 0.7071, sampleRate: sr)]
        }
        var band = x.map { v -> Double in
            var y = v
            for j in sections.indices { y = sections[j].process(y) }
            return y
        }
        var rms = 0.0
        vDSP_rmsqvD(band, 1, &rms, vDSP_Length(band.count))
        if rms > 0 {
            var norm = 1 / rms
            vDSP_vsmulD(band, 1, &norm, &band, 1, vDSP_Length(band.count))
        }
        return band
    }

    // MARK: - Modal

    /// A modal drum's modes, from their own start: each a sine at its
    /// frequency from phase 0, under the shared half-cosine rise and then
    /// its own exp(−(u/τ)^k), mode 1 at peak 1. Only as long as a mode is
    /// audible (its envelope over e^(−12)), so a long render does not pay
    /// for silence.
    ///
    /// Whole arrays at a time (vDSP, vForce), not sample by sample: with
    /// exp and pow per sample and mode, the 808 cowbell's render took 2.2 ms
    /// of an evaluation's 3.1 (2026-09-26). vForce's exp, pow and sin are
    /// not Foundation's to the last bit, so a modal fit from before this
    /// can differ in its last digits.
    static func modal(_ p: DrumParams, sampleRate sr: Double, frames n: Int) -> [Double] {
        guard n > 0 else { return [] }
        var out = [Double](repeating: 0, count: n)
        let attackFrames = min(n, Int(p.ampAttack * sr))
        let k = p.ampShape
        for mode in p.modes where mode.level > 0 && mode.hz < 0.49 * sr {
            let m = min(n, attackFrames + Int(mode.decay * pow(12, 1 / k) * sr) + 1)
            var size = Int32(m)
            var zero = 0.0, radians = 2 * Double.pi * mode.hz / sr
            var wave = [Double](repeating: 0, count: m)
            vDSP_vrampD(&zero, &radians, &wave, 1, vDSP_Length(m))
            vvsin(&wave, wave, &size)

            var envelope = [Double](repeating: 0, count: m)
            for i in 0..<min(attackFrames, m) {
                let x = sin(0.5 * .pi * Double(i) / Double(attackFrames))
                envelope[i] = x * x
            }
            let rest = m - min(attackFrames, m)
            if rest > 0 {
                envelope.withUnsafeMutableBufferPointer { e in
                    let tail = e.baseAddress! + (m - rest)
                    var start = 0.0, step = 1 / (mode.decay * sr)
                    vDSP_vrampD(&start, &step, tail, 1, vDSP_Length(rest))       // u/τ
                    var count = Int32(rest)
                    if k != 1 {
                        var exponent = k
                        vvpows(tail, &exponent, tail, &count)                  // (u/τ)^k
                    }
                    var minusOne = -1.0
                    vDSP_vsmulD(tail, 1, &minusOne, tail, 1, vDSP_Length(rest))
                    vvexp(tail, tail, &count)                                  // exp(−(u/τ)^k)
                }
            }
            vDSP_vmulD(envelope, 1, wave, 1, &wave, 1, vDSP_Length(m))
            var level = mode.level
            out.withUnsafeMutableBufferPointer { o in
                vDSP_vsmaD(wave, 1, &level, o.baseAddress!, 1, o.baseAddress!, 1, vDSP_Length(m))
            }
        }
        return out
    }

    // MARK: - Clap

    /// A clap from its own start: one stream of band-passed noise (RMS 1)
    /// under the sum of its bursts - each starting at once and falling
    /// with exp(−u/τ_b) - one stream, so no two bursts are the same noise;
    /// and from the last burst a second stream, through the tail's band,
    /// at `noise` under exp(−(u/τ)^k).
    static func clap(_ p: DrumParams, sampleRate sr: Double, frames n: Int) -> [Double] {
        let k = p.noiseShape
        let tailLength = p.noise > 0 ? p.noiseDecay * pow(12, 1 / k) : 0
        let m = min(n, max(Int((p.tailStart + max(tailLength, 12 * p.clapBurstDecay)) * sr) + 1, 2048))
        guard m > 0 else { return [] }
        var random = Xorshift(seed: 0x5E11_0005)
        let bursts = bandPass((0..<m).map { _ in random.next() }, p, sampleRate: sr)
        let starts = (0..<p.burstCount).map { Int((Double($0) * p.clapSpacing * sr).rounded()) }
        let last = starts.last ?? 0
        var tail = [Double](repeating: 0, count: m)
        if p.noise > 0 && last < m {
            var band = p
            band.noiseTone = p.clapTailTone
            band.noiseWidth = p.clapTailWidth
            var other = Xorshift(seed: 0x5E11_0006)
            let stream = bandPass((0..<(m - last)).map { _ in other.next() }, band, sampleRate: sr)
            for i in stream.indices { tail[last + i] = stream[i] }
        }
        let burstStep = 1 / (p.clapBurstDecay * sr), tailStep = 1 / (p.noiseDecay * sr)
        var out = [Double](repeating: 0, count: m)
        for i in 0..<m {
            var envelope = 0.0
            for s in starts where i >= s { envelope += exp(-Double(i - s) * burstStep) }
            out[i] = envelope * bursts[i]
            if i >= last { out[i] += p.noise * exp(-pow(Double(i - last) * tailStep, k)) * tail[i] }
        }
        return out
    }

    // MARK: - Hi-hat

    /// The TR-808's six hi-hat oscillators over the lowest, 205.3 Hz.
    static let metalRatios: [Double] = [205.3, 304.4, 369.6, 522.7, 540.0, 800.0].map { $0 / 205.3 }
    /// Where each starts in its cycle - fixed, so a render is repeatable,
    /// and spread, so the six do not all switch at once at the start.
    private static let metalPhases: [Double] = [0, 0.37, 0.71, 0.13, 0.52, 0.89]

    /// The six square waves summed, `n` frames, before any band: naive
    /// squares with a polyBLEP at each edge, so what folds back above
    /// Nyquist is small and the same at 44.1 and 48 kHz.
    static func metalSource(tone: Double, sampleRate sr: Double, frames n: Int) -> [Double] {
        var out = [Double](repeating: 0, count: n)
        for (ratio, start) in zip(metalRatios, metalPhases) {
            let dt = min(tone * ratio / sr, 0.49)
            var phase = start
            for i in 0..<n {
                var v = phase < 0.5 ? 1.0 : -1.0
                v += blep(phase, dt)
                var other = phase + 0.5
                if other >= 1 { other -= 1 }
                v -= blep(other, dt)
                out[i] += v
                phase += dt
                if phase >= 1 { phase -= 1 }
            }
        }
        return out
    }

    private static func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt {
            let x = t / dt
            return x + x - x * x - 1
        }
        if t > 1 - dt {
            let x = (t - 1) / dt
            return x * x + x + x + 1
        }
        return 0
    }

    /// The hat's envelope: a half-cosine rise over `ampAttack`, then the
    /// wires' exp(−(u/τ)^k).
    static func hatEnvelope(_ p: DrumParams, sampleRate sr: Double, frames n: Int) -> [Double] {
        let attackFrames = min(n, Int(p.ampAttack * sr))
        let step = 1 / (p.noiseDecay * sr), k = p.noiseShape
        return (0..<n).map { i in
            if i < attackFrames {
                let x = sin(0.5 * .pi * Double(i) / Double(max(attackFrames, 1)))
                return x * x
            }
            return exp(-pow(Double(i - attackFrames) * step, k))
        }
    }

    /// A hi-hat's voice: `noise` × band-passed noise + `metal` × the
    /// band-passed metal, each RMS 1 before the envelope. Levels are
    /// relative to the reference `gainDB` applies, there being no body.
    static func hat(_ p: DrumParams, sampleRate sr: Double, frames n: Int) -> [Double] {
        let m = min(n, max(Int((p.ampAttack + p.noiseDecay * pow(12, 1 / p.noiseShape)) * sr), 2048))
        guard m > 0 else { return [] }
        var out = [Double](repeating: 0, count: m)
        if p.noise > 0 {
            var random = Xorshift(seed: 0x5E11_0004)
            let band = bandPass((0..<m).map { _ in random.next() }, p, sampleRate: sr)
            for i in 0..<m { out[i] += p.noise * band[i] }
        }
        if p.metal > 0 {
            let band = bandPass(metalSource(tone: p.metalTone, sampleRate: sr, frames: m), p, sampleRate: sr)
            for i in 0..<m { out[i] += p.metal * band[i] }
        }
        let envelope = hatEnvelope(p, sampleRate: sr, frames: m)
        for i in 0..<m { out[i] *= envelope[i] }
        return out
    }
}

/// White noise in [−1, 1), the same sequence for the same seed.
nonisolated struct Xorshift {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 52) - 1
    }
}
